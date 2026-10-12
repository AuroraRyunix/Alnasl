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

  ## One queue a tournament

  A row belongs to a tournament and goes to that tournament's results page,
  with that tournament's relay key. The order that matters is the order
  within a game, so each tournament's rows are sent oldest first and a
  tournament whose key is refused, or which has no results page (yet),
  holds up nobody else's.

  ## One destination among several

  The results server is one of the places games go (`Alnasl.Destination`);
  this queue is its place in line and nobody else's. Another destination
  being offline, refused or switched off changes nothing here, and the
  other way round.

  One economy: a pending row is skipped (`superseded`) when the next pending
  row of the same game has the same number of plies - a clock refresh that a
  newer clock refresh makes pointless. Rows that add a ply are never skipped,
  so the server hears every move with the clock that belonged to it.
  """

  import Ecto.Query

  alias Alnasl.{Games, Log, Repo, Tournaments}
  alias Alnasl.Tournaments.Tournament
  alias Alnasl.Games.Game
  alias Alnasl.Outbox.Entry

  @topic "outbox"

  # --- queueing (any process) --------------------------------------------------

  def subscribe, do: Phoenix.PubSub.subscribe(Alnasl.PubSub, @topic)

  @doc """
  Queues the current state of `game` for the server. `clock` is a reading or
  `nil`; `replace?` marks a correction. Nothing is queued while sending is
  paused for the game. Returns the game with its new sequence number.
  """
  def enqueue(game, clock \\ nil, replace? \\ false)

  def enqueue(%Game{paused: true} = game, _clock, _replace?), do: game

  # A second game on the same board of the same round, or a game set aside:
  # the server knows a game by round and board, and sending this one would
  # overwrite the other. It stays on the box.
  def enqueue(%Game{local: true} = game, _clock, _replace?), do: game

  def enqueue(%Game{} = game, clock, replace?) do
    body = Games.body(game, clock, replace?)
    row? = wanted?(game.tournament_id)

    {:ok, game} =
      Repo.transaction(fn ->
        game = game |> Ecto.Changeset.change(%{seq: game.seq + 1}) |> Repo.update!()

        if row?,
          do:
            Repo.insert!(%Entry{
              game_id: game.id,
              tournament_id: game.tournament_id,
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

  # A tournament of a pairing program that is not on a results site has
  # nowhere for a row to go, and may never have: the change is counted (the
  # other destinations go by the count) and no row is written. When its
  # results page arrives, `requeue/1` sends each game as it stands then. The
  # box's own tournament keeps its rows, as it always did: there the results
  # page is typed in by somebody who may be about to.
  defp wanted?(tournament_id) do
    case Tournaments.get(tournament_id) do
      %Tournament{kind: "linked"} = tournament -> Tournaments.openresults_configured?(tournament)
      _own -> true
    end
  end

  @doc """
  Queues every game of a tournament again, in full: its results page has
  just arrived, or is another one than it was.
  """
  def requeue(tournament_id) do
    for round <- Games.rounds(tournament_id),
        game <- Games.list(tournament_id, round),
        not game.local,
        Games.begun?(game) or game.status == "finished" do
      enqueue(game, game.clock && decode_clock(game.clock), true)
    end

    :ok
  end

  @doc "Forgets what waits for a game under its old place: it has a new place and says it in full there."
  def drop_pending(%Game{id: id}) do
    Repo.update_all(
      from(e in Entry, where: e.game_id == ^id and e.state == "pending"),
      set: [state: "superseded"]
    )

    Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, :outbox_changed)
    :ok
  end

  @doc "Wakes the senders that are running - every destination's, not only the results server's."
  def kick, do: Alnasl.Destination.kick()

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
      __MODULE__
      |> Alnasl.Destination.Sender.status()
      |> Map.put(:pending, pending_count())

    cond do
      not configured?() ->
        %{base | state: :unconfigured}

      not Alnasl.Destination.enabled?(Alnasl.Destination.OpenResults) ->
        %{base | state: :disabled}

      true ->
        base
    end
  end

  @doc "Removes sent and superseded rows older than `days`; all of them when `days` is 0."
  def prune(days \\ 7) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -days * 86_400 + 1)

    Entry
    |> where([e], e.state in ["sent", "superseded"] and e.inserted_at < ^cutoff)
    |> Repo.delete_all()
    |> elem(0)
  end

  @doc "Has any tournament a results page to send to?"
  def configured?, do: Enum.any?(Tournaments.list(), &Tournaments.openresults_configured?/1)

  @doc "How many rows wait for each tournament: `%{tournament_id => count}`."
  def pending_by_tournament do
    Entry
    |> where([e], e.state == "pending")
    |> group_by([e], e.tournament_id)
    |> select([e], {e.tournament_id, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  # --- one step of delivery (pure of process state; the tests call it) ---------

  @doc """
  Tries to deliver the oldest pending row of one tournament. Returns

  - `:empty` - nothing is waiting;
  - `{:sent, entry}`, `{:rejected, entry}`, `{:superseded, entry}` - that row
    is done with, call again;
  - `{:retry, reason, wait_ms | nil}` - the server could not take it now;
  - `{:blocked, reason}` - the key or the tournament is refused;
  - `:unconfigured` - the tournament has no results page to send to.
  """
  def step(%Tournament{} = tournament) do
    if Tournaments.openresults_configured?(tournament) do
      query =
        from e in Entry,
          where: e.state == "pending" and e.tournament_id == ^tournament.id,
          order_by: e.id,
          limit: 1

      case Repo.one(query) do
        nil ->
          :empty

        entry ->
          if superseded?(entry),
            do: {:superseded, mark(entry, "superseded")},
            else: post(entry, tournament)
      end
    else
      :unconfigured
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

  defp post(%Entry{} = entry, %Tournament{} = tournament) do
    url = tournament.server_url <> "/api/tournaments/" <> URI.encode(tournament.slug) <> "/live"

    request =
      [
        url: url,
        headers: [
          {"authorization", "Bearer " <> tournament.relay_key},
          {"content-type", "application/json"}
        ],
        body: entry.body,
        retry: false,
        # No `connect_options` here: with them Req starts a connection pool
        # of its own for every request, and a queue of a hundred moves takes
        # minutes instead of a second.
        receive_timeout: 10_000
      ]
      |> Keyword.merge(Alnasl.Http.req_options())
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

  @doc "One batch for the sender: `{last result, how many rows were sent}`."
  def deliver_batch(limit), do: drain_counting(limit)

  # Every tournament that has something waiting, each in its own order. What
  # comes back is the worst of how they went: one tournament's refused key
  # is said, and the others' rows have gone out all the same.
  defp drain_counting(limit) do
    waiting = pending_by_tournament()

    results =
      for tournament <- Tournaments.list(), is_map_key(waiting, tournament.id) do
        {tournament, drain_tournament(tournament, limit)}
      end

    sent = results |> Enum.map(fn {_t, {_result, sent}} -> sent end) |> Enum.sum()
    several? = length(results) > 1

    result =
      results
      |> Enum.map(fn {tournament, {result, _sent}} -> {rank(result), tournament, result} end)
      |> Enum.max_by(&elem(&1, 0), fn ->
        {0, nil, if(configured?(), do: :empty, else: :unconfigured)}
      end)
      |> then(fn {_rank, tournament, result} ->
        if several?, do: named(result, tournament), else: result
      end)

    {result, sent}
  end

  defp drain_tournament(tournament, limit) do
    Enum.reduce_while(1..limit, {:empty, 0}, fn _i, {_last, sent} ->
      case step(tournament) do
        {:sent, _entry} = done -> {:cont, {done, sent + 1}}
        {other, _entry} = done when other in [:rejected, :superseded] -> {:cont, {done, sent}}
        other -> {:halt, {other, sent}}
      end
    end)
  end

  defp rank({:blocked, _reason}), do: 5
  defp rank({:retry, _reason, _wait}), do: 4
  defp rank(:unconfigured), do: 1
  defp rank(:empty), do: 2
  # The batch limit was reached with rows still waiting.
  defp rank(_more), do: 3

  # With several tournaments, a refusal says whose it is.
  defp named({:blocked, reason}, tournament),
    do: {:blocked, {:tournament, Tournaments.title(tournament), reason}}

  defp named({:retry, reason, wait}, tournament),
    do: {:retry, {:tournament, Tournaments.title(tournament), reason}, wait}

  defp named(result, _tournament), do: result

  # --- the sender --------------------------------------------------------------

  # The sender is `Alnasl.Destination.Sender`, the same process every
  # destination has; the results server's is registered under this module's
  # name, as it always was.

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    Alnasl.Destination.Sender.start_link(
      destination: Alnasl.Destination.OpenResults,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @doc "\"Send now\": forget the pause and try at once."
  def send_now, do: Alnasl.Destination.send_now(Alnasl.Destination.OpenResults)
end
