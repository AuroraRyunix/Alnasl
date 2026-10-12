defmodule Alnasl.FakeLichess do
  @moduledoc """
  Lichess for the tests: the four requests `Alnasl.Destination.LichessApi`
  makes, answered the way that module's table says Lichess answers them.

  It proves that Alnasl and that table agree. It proves nothing about
  lichess.org: both were written from the same reading of the same
  documentation.

  A round holds games by their players (`{White, Black}`), which is how a
  broadcast tells games apart; a game pushed again replaces what was held.
  Every push is kept, in order, with the status answered. `mode/1` makes it
  misbehave: `:down` (no connection), `:rate_limited` (429), `{:status, n}`,
  `{:refuse_board, n}` (that game gets a per-game error).

  Like `Alnasl.FakeIngest` it is a plug given to `Req`, under its own key
  (`config :alnasl, :lichess_req_options`), so the two servers can be up and
  down independently in one test.
  """

  use Agent

  @token "lip_test0123456789abcdef"
  @round "AbCd1234"
  @base "http://lichess.test"

  def token, do: @token
  def round_id, do: @round
  def base, do: @base

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{games: %{}, pushes: [], mode: :ok, scopes: "study:write"} end,
      name: __MODULE__
    )
  end

  @doc "Points Alnasl at this server and switches the destination on."
  def install do
    Application.put_env(:alnasl, :lichess_req_options, plug: &__MODULE__.call/1)

    Alnasl.Settings.put("lichess_url", @base)

    Alnasl.Tournaments.update!(Alnasl.Tournaments.default(), %{
      lichess_round_id: @round,
      lichess_token: @token,
      lichess_round: 1
    })

    Alnasl.Settings.put("dest_lichess_enabled", true)
    :ok
  end

  def uninstall, do: Application.delete_env(:alnasl, :lichess_req_options)

  def mode(mode), do: Agent.update(__MODULE__, &%{&1 | mode: mode})
  def scopes(scopes), do: Agent.update(__MODULE__, &%{&1 | scopes: scopes})

  @doc "Every push received, oldest first: `{status, [game]}` with each game as `Alnasl.PgnReader` reads it."
  def pushes, do: Agent.get(__MODULE__, &Enum.reverse(&1.pushes))

  @doc "The games the round holds, by board number (the `Board` tag)."
  def games do
    Agent.get(__MODULE__, fn s ->
      Map.new(s.games, fn {_players, game} -> {String.to_integer(game.headers["Board"]), game} end)
    end)
  end

  def game(board), do: games()[board]

  # --- the plug ----------------------------------------------------------------

  def call(conn) do
    mode = Agent.get(__MODULE__, & &1.mode)

    if mode == :down,
      do: Req.Test.transport_error(conn, :econnrefused),
      else: route(conn, mode)
  end

  defp authorized?(conn),
    do: Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]

  defp route(%{method: "GET", path_info: ["api", "account"]} = conn, _mode) do
    if authorized?(conn),
      do: json(conn, 200, %{id: "arbiter", username: "Arbiter"}),
      else: json(conn, 401, %{error: "No such token"})
  end

  defp route(%{method: "POST", path_info: ["api", "token", "test"]} = conn, _mode) do
    {:ok, token, conn} = Plug.Conn.read_body(conn)
    scopes = Agent.get(__MODULE__, & &1.scopes)

    answer =
      cond do
        scopes == :garbled -> %{"unexpected" => true}
        token == @token -> %{token => %{"scopes" => scopes, "userId" => "arbiter"}}
        true -> %{token => nil}
      end

    json(conn, 200, answer)
  end

  defp route(%{method: "GET", path_info: ["api", "broadcast", _, _, id]} = conn, _mode) do
    if id == @round,
      do: json(conn, 200, %{round: %{id: id, name: "Round 1"}, tour: %{name: "Test Open"}}),
      else: json(conn, 404, %{error: "Not found"})
  end

  defp route(%{method: "POST", path_info: ["api", "broadcast", "round", id, "push"]} = conn, mode) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    games = Alnasl.PgnReader.parse(body)

    {status, answer} =
      cond do
        not authorized?(conn) -> {401, %{error: "No such token"}}
        id != @round -> {404, %{error: "Not found"}}
        mode == :rate_limited -> {429, %{error: "Too many requests. Try again later."}}
        mode == :not_yours -> {403, %{error: "Forbidden"}}
        match?({:status, _}, mode) -> {elem(mode, 1), %{error: "server error"}}
        true -> {200, %{games: Enum.map(games, &take(&1, mode))}}
      end

    Agent.update(__MODULE__, &%{&1 | pushes: [{status, games} | &1.pushes]})
    json(conn, status, answer)
  end

  defp route(conn, _mode), do: json(conn, 404, %{error: "Not found"})

  defp take(game, mode) do
    tags = Map.take(game.headers, ~w(White Black Board Result))

    if mode == {:refuse_board, String.to_integer(game.headers["Board"] || "0")} do
      %{tags: tags, error: "Cannot parse moves"}
    else
      key = {game.headers["White"], game.headers["Black"]}
      Agent.update(__MODULE__, &put_in(&1.games[key], game))
      %{tags: tags, moves: length(game.moves)}
    end
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
