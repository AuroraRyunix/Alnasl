defmodule Alnasl.Outbox do
  @moduledoc """
  What must reach the results server, and the proof that it did.

  ## The guarantee

  Every change to a game - a move, a clock reading, a result, a correction -
  is written to the `outbox` table **first**, numbered per game, and only
  then sent. A row leaves `pending` when the server has answered for it and
  not before. So a pulled plug, a crashed process or a hall without a network
  for three hours lose nothing: when the box and the server can talk again,
  the queue drains in the order things happened.

  ## Why a retry can never do harm

  Each message is the **whole game so far** (the server's own rule,
  docs/live-boards-api.md in OpenResults). The server decides by the number
  of plies: fewer than it holds is ignored, equal refreshes the clocks, more
  must extend what it holds. So a message sent twice is harmless, and since
  the queue is strictly in order, a message is never sent before an older
  one for the same game.

  A correction (a takeback, an edited move) is sent with `replace: true`:
  the statement "this is the game now", which the server takes whatever it
  holds.

  ## What the answers mean

  | answer | what the outbox does |
  |---|---|
  | 200 | `sent` (also `applied: false, older_than_stored`: the server already knew) |
  | 409 `moves_conflict` | the server holds other moves: the row is `rejected` and the game is queued again in full with `replace: true` - the board is the authority |
  | 422 | this message is wrong and stays wrong: `rejected`, shown to the arbiter, the queue moves on |
  | 401, 403, 404 | the key or the tournament is wrong - nothing a retry of this row fixes, and nothing to throw moves away for: the queue **waits**, says why, and tries again every 30 s and when the settings change |
  | 429, 5xx, no answer | the same row again, after a pause that doubles up to a minute (`Retry-After` is obeyed) |

  One economy: a pending row is skipped (`superseded`) when the next pending
  row of the same game has the same number of plies - a clock refresh that a
  newer clock refresh makes pointless. Rows that add a ply are never skipped,
  so the server hears every move with the clock that belonged to it.
  """

  use GenServer

  import Ecto.Query

  alias Alnasl.{Games, Log, Repo, Settings, Tournament}
  alias Alnasl.Games.Game
  alias Alnasl.Outbox.Entry

  @topic "outbox"
  @max_backoff 60_000
  @blocked_retry 30_000

  # --- queueing (any process) --------------------------------------------------

  def subscribe, do: Phoenix.PubSub.subscribe(Alnasl.PubSub, @topic)

  @doc """
  Queues the current state of `game` for the server. `clock` is a reading or
  `nil`; `replace?` marks a correction. Nothing is queued while sending is
  paused for the game. Returns the game with its new sequence number.
  """
  def enqueue(game, clock \\ nil, replace? \\ false)

  def enqueue(%Game{paused: true} = game, _clock, _replace?), do: game

  def enqueue(%Game{} = game, clock, replace?) do
    body = Games.body(game, clock, replace?)

    {:ok, game} =
      Repo.transaction(fn ->
        game = game |> Ecto.Changeset.change(%{seq: game.seq + 1}) |> Repo.update!()

        Repo.insert!(%Entry{
          game_id: game.id,
          round: game.round,
          board_no: game.board_no,
          seq: game.seq,
          plies: length(body["moves"]),
          replace: replace?,
          body: Jason.encode!(body)
        })

        game
      end)

    Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, :outbox_changed)
    kick()
    game
  end

  @doc "Wakes the sender, if one is running."
  def kick do
    if pid = Process.whereis(__MODULE__), do: send(pid, :deliver)
    :ok
  end

  # --- reading -----------------------------------------------------------------

  def pending_count, do: Repo.aggregate(where(Entry, [e], e.state == "pending"), :count)

  def counts do
    Entry
    |> group_by([e], e.state)
    |> select([e], {e.state, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  def list(state, limit \\ 100) do
    order = if state == "pending", do: [asc: :id], else: [desc: :id]
    Entry |> where([e], e.state == ^state) |> order_by(^order) |> limit(^limit) |> Repo.all()
  end

  @doc """
  The connection as the arbiter should see it: `%{state, pending, last_ok,
  last_error, next_try_ms}` with `state` one of `:unconfigured | :idle |
  :connected | :offline | :blocked`.
  """
  def status do
    base =
      case Process.whereis(__MODULE__) do
        nil -> %{state: :idle, last_ok: nil, last_error: nil, next_try_at: nil}
        pid -> GenServer.call(pid, :status)
      end

    base = Map.put(base, :pending, pending_count())
    if Settings.connection_configured?(), do: base, else: %{base | state: :unconfigured}
  catch
    :exit, _reason -> %{state: :idle, last_ok: nil, last_error: nil, next_try_at: nil, pending: 0}
  end

  @doc "Removes sent and superseded rows older than `days`."
  def prune(days \\ 7) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -days * 86_400)

    Entry
    |> where([e], e.state in ["sent", "superseded"] and e.inserted_at < ^cutoff)
    |> Repo.delete_all()
    |> elem(0)
  end

  # --- one step of delivery (pure of process state; the tests call it) ---------

  @doc """
  Tries to deliver the oldest pending row. Returns

  - `:empty` - nothing is waiting;
  - `{:sent, entry}`, `{:rejected, entry}`, `{:superseded, entry}` - that row
    is done with, call again;
  - `{:retry, reason, wait_ms | nil}` - the server could not take it now;
  - `{:blocked, reason}` - the key or the tournament is refused;
  - `:unconfigured`.
  """
  def step do
    settings = Settings.get_many(~w(server_url slug relay_key))

    cond do
      settings["server_url"] == "" or settings["slug"] == "" or settings["relay_key"] == "" ->
        :unconfigured

      true ->
        case Repo.one(from e in Entry, where: e.state == "pending", order_by: e.id, limit: 1) do
          nil ->
            :empty

          entry ->
            if superseded?(entry),
              do: {:superseded, mark(entry, "superseded")},
              else: post(entry, settings)
        end
    end
  end

  defp superseded?(%Entry{} = entry) do
    next =
      Repo.one(
        from e in Entry,
          where: e.game_id == ^entry.game_id and e.state == "pending" and e.id > ^entry.id,
          order_by: e.id,
          limit: 1
      )

    # The newer row must say at least as much: same plies, and if this one
    # was a correction, the newer one must be too.
    next != nil and next.plies == entry.plies and (next.replace or not entry.replace) and
      finished?(next) >= finished?(entry)
  end

  defp finished?(%Entry{body: body}), do: String.contains?(body, ~s("status":"finished"))

  defp post(%Entry{} = entry, settings) do
    url = settings["server_url"] <> "/api/tournaments/" <> URI.encode(settings["slug"]) <> "/live"

    request =
      [
        url: url,
        headers: [
          {"authorization", "Bearer " <> settings["relay_key"]},
          {"content-type", "application/json"}
        ],
        body: entry.body,
        retry: false,
        receive_timeout: 10_000,
        connect_options: [timeout: 5_000]
      ]
      |> Keyword.merge(Tournament.req_options())
      |> Req.new()

    entry = entry |> Ecto.Changeset.change(%{attempts: entry.attempts + 1}) |> Repo.update!()

    case Req.post(request) do
      {:ok, %{status: 200, body: body}} ->
        note = if is_map(body) and body["applied"] == false, do: body["reason"]
        entry = mark(entry, "sent", note)
        if note == "older_than_stored", do: server_ahead(entry)
        {:sent, entry}

      {:ok, %{status: 409, body: body}} ->
        entry = mark(entry, "rejected", "moves_conflict", detail(body))
        resend_in_full(entry)
        {:rejected, entry}

      {:ok, %{status: 422, body: body}} ->
        {:rejected, mark(entry, "rejected", error_code(body), detail(body))}

      {:ok, %{status: 429} = response} ->
        {:retry, :rate_limited, retry_after(response)}

      {:ok, %{status: status, body: body}} when status in [401, 403, 404] ->
        {:blocked, {status, error_code(body)}}

      {:ok, %{status: 503, body: body}} ->
        {:retry, {:http, 503, error_code(body)}, nil}

      {:ok, %{status: status}} when status >= 500 ->
        {:retry, {:http, status, nil}, nil}

      {:ok, %{status: status, body: body}} ->
        {:rejected, mark(entry, "rejected", error_code(body) || "http_#{status}", detail(body))}

      {:error, %{reason: reason}} ->
        {:retry, {:unreachable, reason}, nil}

      {:error, _exception} ->
        {:retry, {:unreachable, :unknown}, nil}
    end
  end

  defp mark(entry, state, error \\ nil, detail \\ nil) do
    entry =
      entry
      |> Ecto.Changeset.change(%{
        state: state,
        error: error,
        detail: detail,
        sent_at: if(state == "sent", do: DateTime.utc_now(:second))
      })
      |> Repo.update!()

    Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, :outbox_changed)
    entry
  end

  # The server holds different moves for this game. What is on the board
  # wins: queue the game as it is now, as a replacement.
  defp resend_in_full(%Entry{replace: true}), do: :ok

  defp resend_in_full(%Entry{} = entry) do
    game = Games.get!(entry.game_id)
    clock = game.clock && decode_clock(game.clock)
    enqueue(game, clock, true)

    Log.add(:warn, "outbox.conflict", %{}, %{round: entry.round, board_no: entry.board_no})
    :ok
  end

  # The server holds MORE moves for this game than the newest thing the box
  # has to say about it. Not an error the server reports - it just ignores
  # us - so the box says it: the arbiter should look at that board.
  defp server_ahead(%Entry{} = entry) do
    newer? =
      Repo.exists?(from e in Entry, where: e.game_id == ^entry.game_id and e.id > ^entry.id)

    unless newer? do
      Log.add(:warn, "outbox.server_ahead", %{plies: entry.plies}, %{
        round: entry.round,
        board_no: entry.board_no
      })
    end
  end

  defp decode_clock(json) do
    case Jason.decode(json) do
      {:ok, %{} = c} ->
        %{white_ms: c["white_ms"], black_ms: c["black_ms"], running: running(c["running"])}

      _other ->
        nil
    end
  end

  defp running("white"), do: :white
  defp running("black"), do: :black
  defp running(_other), do: :none

  defp error_code(%{"error" => code}) when is_binary(code), do: code
  defp error_code(_other), do: nil

  defp detail(%{"detail" => detail}) when is_binary(detail), do: String.slice(detail, 0, 500)
  defp detail(_other), do: nil

  defp retry_after(response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, _} <- Integer.parse(value) do
      seconds * 1000
    else
      _none -> nil
    end
  end

  @doc "Delivers until the queue is empty or the server stops taking. For tests and `Send now`."
  def drain(limit \\ 10_000), do: limit |> drain_counting() |> elem(0)

  # `{last result, how many rows were sent}`.
  defp drain_counting(limit) do
    Enum.reduce_while(1..limit, {:empty, 0}, fn _i, {_last, sent} ->
      case step() do
        {:sent, _entry} = done -> {:cont, {done, sent + 1}}
        {other, _entry} = done when other in [:rejected, :superseded] -> {:cont, {done, sent}}
        other -> {:halt, {other, sent}}
      end
    end)
  end

  # --- the sender --------------------------------------------------------------

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "\"Send now\": forget the pause and try at once."
  def send_now do
    if pid = Process.whereis(__MODULE__), do: send(pid, :send_now)
    :ok
  end

  @impl true
  def init(_opts) do
    Settings.subscribe()
    send(self(), :deliver)

    {:ok,
     %{state: :idle, last_ok: nil, last_error: nil, backoff: 1_000, timer: nil, next_try_at: nil}}
  end

  @impl true
  def handle_call(:status, _from, s) do
    {:reply, Map.take(s, [:state, :last_ok, :last_error, :next_try_at]), s}
  end

  @impl true
  def handle_info(:send_now, s), do: handle_info(:deliver, cancel(s))

  def handle_info({:setting, key}, s) when key in ~w(server_url slug relay_key),
    do: handle_info(:deliver, cancel(s))

  def handle_info({:setting, _other}, s), do: {:noreply, s}

  # A wake-up while a retry is scheduled changes nothing: the pause stands.
  def handle_info(:deliver, %{timer: timer} = s) when timer != nil, do: {:noreply, s}

  def handle_info(:deliver, s), do: {:noreply, run(s)}

  def handle_info(:retry, s), do: {:noreply, run(%{s | timer: nil, next_try_at: nil})}

  def handle_info(_other, s), do: {:noreply, s}

  defp cancel(%{timer: nil} = s), do: s

  defp cancel(%{timer: timer} = s) do
    Process.cancel_timer(timer)
    %{s | timer: nil, next_try_at: nil}
  end

  # Sends a batch, then yields: a long queue must not make the status call wait.
  defp run(s) do
    {result, sent} =
      try do
        drain_counting(50)
      rescue
        error -> {{:retry, {:crash, Exception.message(error)}, nil}, 0}
      end

    s = if sent > 0, do: online(%{s | last_ok: DateTime.utc_now(:second)}), else: s

    case result do
      :empty ->
        s

      :unconfigured ->
        change(s, :idle, nil)

      {:retry, reason, wait} ->
        wait = wait || s.backoff
        s = change(s, :offline, reason)
        schedule(%{s | backoff: min(s.backoff * 2, @max_backoff)}, wait)

      {:blocked, reason} ->
        s |> change(:blocked, reason) |> schedule(@blocked_retry)

      {_done, _entry} ->
        # The batch limit was reached mid-queue: go on after a breath.
        send(self(), :deliver)
        s
    end
  end

  defp online(s) do
    s = %{s | backoff: 1_000}

    if s.state == :connected do
      s
    else
      if s.state in [:offline, :blocked], do: Log.add(:info, "outbox.online", %{})
      broadcast(%{s | state: :connected, last_error: nil})
    end
  end

  defp change(s, state, reason) do
    if s.state != state do
      case state do
        :offline -> Log.add(:warn, "outbox.offline", %{reason: inspect(reason)})
        :blocked -> Log.add(:error, "outbox.blocked", %{reason: inspect(reason)})
        _other -> :ok
      end
    end

    broadcast(%{s | state: state, last_error: reason})
  end

  defp schedule(s, wait) do
    timer = Process.send_after(self(), :retry, wait)

    broadcast(%{
      s
      | timer: timer,
        next_try_at: DateTime.add(DateTime.utc_now(), wait, :millisecond)
    })
  end

  defp broadcast(s) do
    Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, :outbox_changed)
    s
  end
end
