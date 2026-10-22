defmodule Alnasl.FakeIngest do
  @moduledoc """
  A results server for the tests: the live-boards ingest of OpenResults as its
  contract (`docs/live-boards-api.md` there) describes it, in a few lines.

  It holds games by `(round, board)` and decides by the number of plies the
  way the contract says - fewer is ignored (`older_than_stored`), equal
  refreshes, more must extend, a disagreement is `409 moves_conflict`,
  `replace: true` wins - checks every move for legality with the same checker
  (`422 invalid_moves`), and takes one relay key for one slug.

  It can also misbehave on purpose: `mode/1` makes it unreachable, answer
  500, refuse for rate, or pause. Every request it sees is kept, in order, so
  a test can say exactly what the server was told and how often.

  It is a plug given to `Req` (`config :alnasl, :req_options, plug: ...`), so
  there is no socket: "unreachable" is a transport error raised by the plug.
  The real server is used in the end-to-end run (`mix alnasl.e2e`).
  """

  use Agent

  alias Alnasl.Chess

  @slug "test-open"
  @key "orrk_test_0123456789abcdef"

  def slug, do: @slug
  def key, do: @key

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          games: %{},
          mode: :ok,
          requests: [],
          answers: [],
          snapshot: snapshot(4),
          fail_next: 0
        }
      end,
      name: __MODULE__
    )
  end

  @doc "Points Alnasl at this server: settings, and Req's plug."
  def install do
    Application.put_env(:alnasl, :req_options, plug: &__MODULE__.call/1)

    # The box's own tournament sends there, and knows the pairings the way
    # it would from an arbiter or a pairing program: the box does not read
    # them from the results server.
    own =
      Alnasl.Tournaments.update!(Alnasl.Tournaments.default(), %{
        server_url: "http://results.test",
        slug: @slug,
        relay_key: @key
      })

    {:ok, _own} =
      Alnasl.Tournaments.import_snapshot(own, Agent.get(__MODULE__, & &1.snapshot))

    :ok
  end

  @doc """
  `:ok | :down | {:status, 500} | :rate_limited | :paused`, or `{:answer,
  status, body}`: every live board is answered with exactly that (a
  contract example, say) and nothing is stored.
  """
  def mode(mode), do: Agent.update(__MODULE__, &%{&1 | mode: mode})

  @doc "The next `n` requests fail as unreachable, then the server is back."
  def fail_next(n), do: Agent.update(__MODULE__, &%{&1 | fail_next: n})

  def game(round, board), do: Agent.get(__MODULE__, & &1.games[{round, board}])
  def games, do: Agent.get(__MODULE__, & &1.games)

  @doc "Every live-boards body received, oldest first, with the status answered."
  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  @doc "Every live-boards answer given, oldest first: `{status, body}`, the body as JSON has it."
  def answers, do: Agent.get(__MODULE__, &Enum.reverse(&1.answers))

  def reset,
    do:
      Agent.update(
        __MODULE__,
        &%{&1 | games: %{}, requests: [], answers: [], mode: :ok, fail_next: 0}
      )

  @doc "Puts a game on the server behind Alnasl's back."
  def plant(round, board, moves),
    do:
      Agent.update(
        __MODULE__,
        &put_in(&1.games[{round, board}], %{moves: moves, status: "live", result: nil, clock: %{}})
      )

  # --- the plug ----------------------------------------------------------------

  def call(conn) do
    {mode, failing?} =
      Agent.get_and_update(__MODULE__, fn s ->
        if s.fail_next > 0,
          do: {{s.mode, true}, %{s | fail_next: s.fail_next - 1}},
          else: {{s.mode, false}, s}
      end)

    cond do
      failing? or mode == :down -> Req.Test.transport_error(conn, :econnrefused)
      true -> route(conn, mode)
    end
  end

  # What OpenResults says about itself is the contract's own example.
  defp route(%{method: "GET", path_info: ["api", "server"]} = conn, _mode),
    do: json(conn, 200, Alnasl.Contract.example(:publish, "server.response"))

  defp route(%{method: "GET", path_info: ["api", "tournaments", slug]} = conn, _mode) do
    if slug == @slug,
      do: json(conn, 200, Agent.get(__MODULE__, & &1.snapshot)),
      else: json(conn, 404, error("tournament_not_published", "no such tournament"))
  end

  defp route(%{method: "POST", path_info: ["api", "tournaments", slug, "live"]} = conn, mode) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    body = if raw == "", do: %{}, else: Jason.decode!(raw)
    auth = Plug.Conn.get_req_header(conn, "authorization")

    {status, answer} =
      cond do
        auth != ["Bearer " <> @key] ->
          {401, error("unauthorized", "no such key")}

        slug != @slug ->
          {403, error("relay_key_wrong_tournament", "another tournament's")}

        mode == :paused ->
          {503, error("publishing_paused", "paused by the operator")}

        mode == :rate_limited ->
          {429, Map.put(error("rate_limited", "slow down"), :retry_after, 1)}

        match?({:status, _}, mode) ->
          {elem(mode, 1), %{error: "server_error"}}

        match?({:answer, _, _}, mode) ->
          {elem(mode, 1), elem(mode, 2)}

        true ->
          ingest(body)
      end

    Agent.update(
      __MODULE__,
      &%{
        &1
        | requests: [{status, body} | &1.requests],
          answers: [{status, answer |> Jason.encode!() |> Jason.decode!()} | &1.answers]
      }
    )

    wait = answer[:retry_after] || answer["retry_after"] || 1

    conn =
      if status == 429,
        do: Plug.Conn.put_resp_header(conn, "retry-after", to_string(wait)),
        else: conn

    json(conn, status, answer)
  end

  defp route(conn, _mode), do: json(conn, 404, error("not_found", "no such route"))

  defp error(code, detail), do: %{error: code, detail: detail}

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  # --- the contract ------------------------------------------------------------

  defp ingest(%{"round" => round, "board" => board, "moves" => moves} = body)
       when is_integer(round) and is_integer(board) and is_list(moves) do
    start = body["start_fen"] || Chess.start_fen()

    case Chess.replay(start, moves) do
      {:ok, plies} ->
        canonical = Enum.map(plies, & &1.san)
        Agent.get_and_update(__MODULE__, &decide(&1, {round, board}, canonical, body))

      {:error, {ply, message}} ->
        {422, %{error: "invalid_moves", ply: ply, detail: "ply #{ply}: #{message}"}}

      {:error, message} ->
        {422, %{error: "invalid_fen", detail: message}}
    end
  end

  defp ingest(_body),
    do: {422, error("invalid_request", "round, board and moves are required")}

  defp decide(state, key, moves, body) do
    held = state.games[key]
    replace? = body["replace"] == true
    count = length(moves)

    cond do
      held == nil or replace? ->
        store(state, key, moves, body, held, replace?)

      count < length(held.moves) ->
        {{200,
          %{status: "ok", applied: false, ply: length(held.moves), reason: "older_than_stored"}},
         state}

      Enum.take(moves, length(held.moves)) != held.moves ->
        {{409, %{error: "moves_conflict", detail: "the moves disagree with those held"}}, state}

      true ->
        store(state, key, moves, body, held, false)
    end
  end

  defp store(state, key, moves, body, held, replace?) do
    was_finished? = held != nil and held.status == "finished"
    reopened? = replace? or held == nil or length(moves) > length(held.moves)

    status =
      cond do
        body["status"] == "finished" -> "finished"
        was_finished? and not reopened? -> "finished"
        true -> "live"
      end

    clock = Map.merge((held && held.clock) || %{}, Map.take(body, ~w(white_ms black_ms running)))

    game = %{
      moves: moves,
      status: status,
      result: if(status == "finished", do: body["result"] || (held && held.result)),
      clock: clock,
      start_fen: body["start_fen"]
    }

    {{200, %{status: "ok", applied: true, ply: length(moves)}}, put_in(state.games[key], game)}
  end

  # --- a tournament to be told about -------------------------------------------

  @doc "A snapshot with one round of `boards` boards."
  def snapshot(boards) do
    %{
      "schema" => 1,
      "tournament" => %{"name" => "Test Open", "slug" => @slug, "city" => "Ghent"},
      "players" =>
        for n <- 1..(boards * 2) do
          %{
            "no" => n,
            "name" => "Player #{n}",
            "title" => if(n == 1, do: "GM"),
            "rating" => 2000 + n
          }
        end,
      "rounds" => [
        %{
          "number" => 1,
          "boards" =>
            for(
              b <- 1..boards,
              do: %{"board" => b, "white" => b * 2 - 1, "black" => b * 2, "result" => nil}
            )
        }
      ]
    }
  end
end
