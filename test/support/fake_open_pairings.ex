defmodule Alnasl.FakeOpenPairings do
  @moduledoc """
  A pairing program for the tests: the board link of OpenPairings as its
  contract (`docs/board-link-api.md` there, API version 1) describes it,
  written from that document and not from OpenPairings' code.

  It holds tournaments, connect codes (for one tournament or for a group)
  and the games reported to it, and answers the four requests the way the
  contract says:

  - `GET /link` with an `ETag` that changes when the set of tournaments or
    any tournament's version does, and `304` for the `ETag` it gave;
  - `GET /tournaments/:id` with the version as `ETag`;
  - `POST /box`;
  - `POST /tournaments/:id/games`, one game or a batch: `seq` decides
    (higher is stored, equal is `duplicate`, lower is `stale`, `replace`
    wins), the game must be in the tournament now (`409 pairing_gone`),
    not a bye (`422 not_a_game`), between the two players named in those
    colours (`409 pairing_changed`), and shaped as the contract says (`422
    invalid_request`). Legality is not checked, as there.

  `current_round` is worked out as the contract defines it: of the rounds
  paired last together - the newest round of a Swiss, every round of a
  round robin (`system: :round_robin`) - the first with a game that has no
  result, else the last of them.

  It can misbehave on purpose (`mode/1`), and every request is kept, in
  order. It is a plug given to `Req` (`config :alnasl,
  :openpairings_req_options`), so there is no socket.

  No real OpenPairings is spoken to anywhere in the tests.
  """

  use Agent

  @root "http://pairings.test/api/boards/v1"
  @san ~r/^[A-Za-z0-9+#=\-]{2,10}$/
  @results ["1-0", "1/2-1/2", "0-1"]

  def root, do: @root

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %{tournaments: %{}, codes: %{}, games: %{}, mode: :ok, requests: [], boxes: [], n: 0}
      end,
      name: __MODULE__
    )
  end

  @doc "Puts this server behind every request of the board link."
  def install do
    Application.put_env(:alnasl, :openpairings_req_options, plug: &__MODULE__.call/1)
    :ok
  end

  def uninstall, do: Application.delete_env(:alnasl, :openpairings_req_options)

  @doc "`:ok | :down | {:status, 500} | :rate_limited | :not_the_api | {:api, 2}`."
  def mode(mode), do: Agent.update(__MODULE__, &%{&1 | mode: mode})

  # --- setting the scene -------------------------------------------------------

  @doc """
  A tournament with `boards` boards in round 1, players 1..2n (ids 500+n),
  published on a results site unless `openresults: nil`.
  """
  def add_tournament(id, opts \\ []) do
    name = Keyword.get(opts, :name, "Tournament #{id}")
    boards = Keyword.get(opts, :boards, 2)

    tournament = %{
      id: id,
      name: name,
      label: Keyword.get(opts, :label),
      state: "running",
      group: Keyword.get(opts, :group),
      system: Keyword.get(opts, :system, :swiss),
      players:
        for n <- 1..max(boards * 2, 2) do
          %{
            "id" => id * 1000 + n,
            "no" => n,
            "name" => "#{name} Player #{n}",
            "title" => if(n == 1, do: "IM"),
            "rating" => 2000 + n,
            "federation" => "BEL",
            "fide_id" => nil,
            "team" => nil
          }
        end,
      rounds: if(boards > 0, do: [round(id, 1, boards, 0)], else: []),
      openresults:
        Keyword.get(opts, :openresults, %{
          "server_url" => "http://results.test",
          "slug" => "slug-#{id}",
          "relay_key" => relay_key(id)
        }),
      time_control: Keyword.get(opts, :time_control, "90min+30sec/move")
    }

    Agent.update(__MODULE__, &put_in(&1.tournaments[id], tournament))
    tournament
  end

  @doc """
  A team event, as the contract's "Team events" describes it: `teams`
  teams of `per_match` players each (`team: "Team n"` on every player),
  round 1 paired as matches of team 1 against 2, 3 against 4, ... Boards
  are numbered through the round, `(match - 1) * per_match + place`, and
  each carries its `match`. Team A has White on odd boards of a match.
  """
  def add_team_tournament(id, opts \\ []) do
    name = Keyword.get(opts, :name, "Team event #{id}")
    per = Keyword.get(opts, :per_match, 4)
    teams = Keyword.get(opts, :teams, 4)

    players =
      for team <- 1..teams, place <- 1..per do
        n = (team - 1) * per + place

        %{
          "id" => id * 1000 + n,
          "no" => n,
          "name" => "#{name} T#{team} P#{place}",
          "title" => nil,
          "rating" => 2200 - n,
          "federation" => "BEL",
          "fide_id" => nil,
          "team" => "Team #{team}"
        }
      end

    tournament = %{
      id: id,
      name: name,
      label: Keyword.get(opts, :label),
      state: "running",
      group: Keyword.get(opts, :group),
      system: :swiss,
      team: per,
      players: players,
      rounds: [team_round(id, 1, teams, per)],
      openresults:
        Keyword.get(opts, :openresults, %{
          "server_url" => "http://results.test",
          "slug" => "slug-#{id}",
          "relay_key" => relay_key(id)
        }),
      time_control: Keyword.get(opts, :time_control, "90min+30sec/move")
    }

    Agent.update(__MODULE__, &put_in(&1.tournaments[id], tournament))
    tournament
  end

  defp team_round(id, number, teams, per) do
    boards =
      for match <- 1..div(teams, 2), place <- 1..per do
        {a, b} = {2 * match - 1, 2 * match}
        player = fn team -> id * 1000 + (team - 1) * per + place end
        {white, black} = if rem(place, 2) == 1, do: {a, b}, else: {b, a}

        %{
          "game" => "g#{id}r#{number}m#{match}b#{place}",
          "board" => (match - 1) * per + place,
          "label" => to_string((match - 1) * per + place),
          "kind" => "game",
          "white" => player.(white),
          "black" => player.(black),
          "result" => nil,
          "match" => %{
            "number" => match,
            "board" => place,
            "team_a" => "Team #{a}",
            "team_b" => "Team #{b}"
          }
        }
      end

    %{"number" => number, "date" => nil, "chess960_position" => nil, "boards" => boards}
  end

  @doc "Pairs round `number` of a team event the same way as round 1 (new game ids)."
  def pair_teams(id, number) do
    update(id, fn t ->
      teams = t.players |> Enum.map(& &1["team"]) |> Enum.uniq() |> length()
      round = team_round(id, number, teams, t.team)
      %{t | rounds: Enum.reject(t.rounds, &(&1["number"] == number)) ++ [round]}
    end)
  end

  @doc "A relay key for tournament `id`: not shaped like anybody's real one."
  def relay_key(id), do: "orrk" <> "_fake_" <> String.duplicate("k", 12) <> "#{id}"

  defp round(id, number, boards, shift) do
    %{
      "number" => number,
      "date" => nil,
      "chess960_position" => nil,
      "boards" =>
        for b <- 1..boards do
          %{
            "game" => "g#{id}r#{number}b#{b}s#{shift}",
            "board" => b,
            "label" => to_string(b),
            "kind" => "game",
            "white" => id * 1000 + b * 2 - 1,
            "black" => id * 1000 + b * 2,
            "result" => nil
          }
        end
    }
  end

  @doc "Changes a tournament: `update(17, fn t -> ... end)`."
  def update(id, fun), do: Agent.update(__MODULE__, &update_in(&1.tournaments[id], fun))

  @doc "Pairs round `number` with `boards` boards (new game ids every time it is called)."
  def pair(id, number, boards) do
    Agent.update(__MODULE__, fn s ->
      s = %{s | n: s.n + 1}

      update_in(s.tournaments[id].rounds, fn rounds ->
        [round(id, number, boards, s.n) | Enum.reject(rounds, &(&1["number"] == number))]
        |> Enum.sort_by(& &1["number"])
      end)
    end)
  end

  @doc "Changes the boards of a round: `boards(17, 1, fn boards -> ... end)`."
  def boards(id, number, fun) do
    update(id, fn t ->
      %{
        t
        | rounds:
            Enum.map(t.rounds, fn r ->
              if r["number"] == number, do: Map.update!(r, "boards", fun), else: r
            end)
      }
    end)
  end

  @doc "The arbiter enters a result on every board of a round."
  def finish_round(id, number, result \\ "1-0"),
    do: boards(id, number, fn boards -> Enum.map(boards, &Map.put(&1, "result", result)) end)

  def remove_tournament(id),
    do: Agent.update(__MODULE__, &%{&1 | tournaments: Map.delete(&1.tournaments, id)})

  @doc "A connect code for one tournament, as OpenPairings would show it."
  def code(id) when is_integer(id), do: make_code("oplt", {:tournament, id})

  @doc "A connect code for a group of tournaments (every tournament with `group: name`)."
  def group_code(name) when is_binary(name), do: make_code("oplg", {:group, name})

  defp make_code(prefix, target) do
    Agent.get_and_update(__MODULE__, fn s ->
      # Built from pieces: a string that looks like a secret has no business
      # in a repository, even a made-up one.
      secret =
        prefix <>
          "_" <> String.duplicate("x", 20) <> "-test-" <> "#{System.unique_integer([:positive])}"

      {@root <> "#" <> secret, put_in(s.codes[secret], target)}
    end)
  end

  @doc """
  The same code under another address of the same program: a desktop copy
  reached at `127.0.0.1` and at its address on the hall's network. The
  fake answers whatever the address.
  """
  def at(code, root), do: String.replace(code, @root, root)

  @doc "The secret part of a code."
  def secret(code), do: code |> String.split("#") |> List.last()

  @doc "Withdraws a code: every request with it is 401 from now on."
  def withdraw(code),
    do: Agent.update(__MODULE__, &%{&1 | codes: Map.delete(&1.codes, secret(code))})

  # --- what the tests ask afterwards -------------------------------------------

  def game(id, uid), do: Agent.get(__MODULE__, & &1.games[{id, uid}])
  def games, do: Agent.get(__MODULE__, & &1.games)

  @doc "Plants a stored game, as if another box had reported it."
  def plant(id, uid, seq),
    do: Agent.update(__MODULE__, &put_in(&1.games[{id, uid}], %{"seq" => seq, "moves" => []}))

  @doc "Every request seen, oldest first: `{method, path, status, body}`."
  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  def requests(method, path_part),
    do: Enum.filter(requests(), fn {m, path, _s, _b} -> m == method and path =~ path_part end)

  def reset_requests, do: Agent.update(__MODULE__, &%{&1 | requests: []})
  def boxes, do: Agent.get(__MODULE__, &Enum.reverse(&1.boxes))

  @doc "The document of a tournament as a box would be given it."
  def document(id), do: Agent.get(__MODULE__, &document_of(&1.tournaments[id]))

  # --- the plug ----------------------------------------------------------------

  def call(conn) do
    mode = Agent.get(__MODULE__, & &1.mode)
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    body = if raw == "", do: nil, else: Jason.decode!(raw)

    if mode == :down do
      note(conn, :down, body)
      Req.Test.transport_error(conn, :econnrefused)
    else
      {status, headers, answer} = respond(conn, body, mode)
      note(conn, status, body)

      conn =
        Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)

      case answer do
        nil ->
          Plug.Conn.send_resp(conn, status, "")

        {:html, text} ->
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(status, text)

        map ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(map))
      end
    end
  end

  defp note(conn, status, body) do
    entry = {conn.method, conn.request_path, status, body}
    Agent.update(__MODULE__, &%{&1 | requests: [entry | &1.requests]})
  end

  defp respond(_conn, _body, {:status, status}),
    do: {status, [], %{"error" => "server_error", "detail" => "on purpose"}}

  defp respond(_conn, _body, :not_the_api),
    do: {200, [], {:html, "<html><body>Sign in to the hall's network</body></html>"}}

  defp respond(conn, body, mode) do
    with {:ok, target} <- authenticate(conn) do
      if mode == :rate_limited,
        do: error(429, "rate_limited", "too many requests", [{"retry-after", "60"}]),
        else: route(conn, body, target, mode)
    end
  end

  defp authenticate(conn) do
    codes = Agent.get(__MODULE__, & &1.codes)

    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> secret] when is_map_key(codes, secret) -> {:ok, codes[secret]}
      _refused -> error(401, "unauthorized", "no code, or one that is wrong or withdrawn")
    end
  end

  defp error(status, code, detail, headers \\ []),
    do: {status, headers, %{"error" => code, "detail" => detail}}

  defp covered(target) do
    Agent.get(__MODULE__, fn s ->
      case target do
        {:tournament, id} -> List.wrap(s.tournaments[id])
        {:group, name} -> s.tournaments |> Map.values() |> Enum.filter(&(&1.group == name))
      end
      |> Enum.sort_by(& &1.id)
    end)
  end

  defp route(
         %{method: "GET", path_info: ["api", "boards", "v1", "link"]} = conn,
         _body,
         target,
         mode
       ) do
    listing = %{
      "api" =>
        case mode do
          {:api, n} -> n
          _ok -> 1
        end,
      "server" => %{"name" => "OpenPairings", "version" => "0.0.0-fake"},
      "poll_seconds" => 5,
      "kind" => if(match?({:group, _}, target), do: "group", else: "tournament"),
      "group" =>
        case target do
          {:group, name} -> %{"name" => name}
          _one -> nil
        end,
      "tournaments" =>
        for t <- covered(target) do
          %{
            "id" => t.id,
            "name" => t.name,
            "label" => t.label,
            "state" => t.state,
            "version" => version(t)
          }
        end
    }

    conditional(conn, hash(listing), listing)
  end

  defp route(%{method: "POST", path_info: ["api", "boards", "v1", "box"]}, body, target, _mode) do
    Agent.update(__MODULE__, &%{&1 | boxes: [{target, body} | &1.boxes]})
    {200, [], %{"status" => "ok"}}
  end

  defp route(
         %{method: "GET", path_info: ["api", "boards", "v1", "tournaments", id]} = conn,
         _body,
         target,
         _mode
       ) do
    with {:ok, t} <- reach(target, id), do: conditional(conn, version(t), document_of(t))
  end

  defp route(
         %{method: "POST", path_info: ["api", "boards", "v1", "tournaments", id, "games"]},
         body,
         target,
         _mode
       ) do
    with {:ok, t} <- reach(target, id) do
      case body do
        %{"games" => games} when is_list(games) and length(games) <= 64 ->
          results =
            for game <- games do
              case report(t, game) do
                {:ok, answer} ->
                  Map.merge(%{"status" => "ok", "game" => game["game"]}, answer)

                {:error, _status, code, detail} ->
                  %{
                    "status" => "error",
                    "game" => game["game"],
                    "error" => code,
                    "detail" => detail
                  }
              end
            end

          {200, [], %{"status" => "ok", "results" => results}}

        %{"games" => _other} ->
          error(422, "invalid_request", "games: a list of at most 64 games")

        %{} = game ->
          case report(t, game) do
            {:ok, answer} ->
              {200, [], Map.merge(%{"status" => "ok", "game" => game["game"]}, answer)}

            {:error, status, code, detail} ->
              error(status, code, detail)
          end

        _other ->
          error(422, "invalid_request", "a game is a JSON object")
      end
    end
  end

  defp route(_conn, _body, _target, _mode), do: {404, [], %{"error" => "not_found"}}

  defp reach(target, id) do
    case Integer.parse(id) do
      {id, ""} ->
        case Enum.find(covered(target), &(&1.id == id)) do
          nil -> error(404, "tournament_not_found", "this code does not reach that tournament")
          t -> {:ok, t}
        end

      _bad ->
        error(404, "tournament_not_found", "this code does not reach that tournament")
    end
  end

  defp conditional(conn, etag, body) do
    asked =
      conn
      |> Plug.Conn.get_req_header("if-none-match")
      |> Enum.map(&(&1 |> String.trim_leading("W/") |> String.trim("\"")))

    headers = [{"etag", ~s("#{etag}")}, {"cache-control", "no-cache"}]
    if etag in asked, do: {304, headers, nil}, else: {200, headers, body}
  end

  # --- the document ------------------------------------------------------------

  defp version(t), do: hash(Map.delete(document_of(t, nil), "version"))

  defp hash(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 20)
  end

  defp document_of(t), do: document_of(t, version(t))

  defp document_of(t, version) do
    current = current_round(t.rounds, Map.get(t, :system, :swiss))

    %{
      "version" => version,
      "tournament" => %{
        "id" => t.id,
        "name" => t.name,
        "site" => "Town Hall",
        "city" => "Ghent",
        "federation" => "BEL",
        "start_date" => "2026-07-04",
        "end_date" => "2026-07-06",
        "rounds" => 5,
        "state" => t.state,
        "team_event" => Map.get(t, :team) != nil,
        "boards_per_match" => Map.get(t, :team),
        "chess960" => false,
        "live_boards" => true,
        "display" =>
          Map.get(t, :display, %{"rating" => true, "title" => true, "federation" => true}),
        "time_control" => %{
          "text" => t.time_control,
          "kind" => "standard",
          "pgn" => "5400+30",
          "periods" => [%{"moves" => nil, "seconds" => 5400}],
          "increment_seconds" => 30,
          "increment_from_move" => 1
        }
      },
      "current_round" => current,
      "players" => t.players,
      "rounds" =>
        Enum.map(t.rounds, fn r ->
          Map.put(
            r,
            "state",
            cond do
              r["number"] == current -> "current"
              r["number"] < current -> "finished"
              true -> "upcoming"
            end
          )
        end),
      "openresults" => t.openresults
    }
  end

  defp current_round([], _system), do: nil

  # A Swiss pairs one round at a time: the one paired last is on.
  defp current_round(rounds, :swiss), do: List.last(rounds)["number"]

  # A round robin pairs them all at once: the first with a game still open.
  defp current_round(rounds, :round_robin) do
    open =
      Enum.find(rounds, fn r ->
        Enum.any?(r["boards"], &(&1["kind"] == "game" and &1["result"] == nil))
      end)

    (open || List.last(rounds))["number"]
  end

  # --- a report ----------------------------------------------------------------

  defp report(t, game) when is_map(game) do
    with :ok <- shape(game),
         {:ok, board} <- pairing(t, game["game"]),
         :ok <- players(board, game) do
      Agent.get_and_update(__MODULE__, fn s ->
        key = {t.id, game["game"]}
        held = s.games[key]
        seq = game["seq"]

        cond do
          held != nil and game["replace"] != true and seq < held["seq"] ->
            {{:ok, %{"applied" => false, "seq" => held["seq"], "reason" => "stale"}}, s}

          held != nil and game["replace"] != true and seq == held["seq"] ->
            {{:ok, %{"applied" => false, "seq" => held["seq"], "reason" => "duplicate"}}, s}

          true ->
            stored =
              game
              |> Map.put_new("status", "live")
              |> Map.put_new("moves", [])
              |> Map.put_new("reconstructed", 0)
              |> Map.put_new("guessed", 0)

            {{:ok, %{"applied" => true, "seq" => seq}}, put_in(s.games[key], stored)}
        end
      end)
    end
  end

  defp report(_t, _other), do: {:error, 422, "invalid_request", "a game is a JSON object"}

  defp invalid(detail), do: {:error, 422, "invalid_request", detail}

  defp shape(g) do
    moves = Map.get(g, "moves", [])
    clocks = g["move_clocks"]

    cond do
      not (is_binary(g["game"]) and byte_size(g["game"]) in 1..64) ->
        invalid("game")

      not (is_integer(g["white"]) and is_integer(g["black"])) ->
        invalid("white, black: the players' ids")

      not (is_integer(g["seq"]) and g["seq"] >= 0 and g["seq"] <= 9_007_199_254_740_991) ->
        invalid("seq")

      not (is_list(moves) and length(moves) <= 1000) ->
        invalid("moves")

      Enum.any?(moves, &(not (is_binary(&1) and &1 =~ @san))) ->
        invalid("moves: not a move in SAN")

      clocks != nil and not (is_list(clocks) and length(clocks) == length(moves)) ->
        invalid("move_clocks: as many entries as there are moves")

      clocks != nil and Enum.any?(clocks, &(not (is_nil(&1) or (is_integer(&1) and &1 >= 0)))) ->
        invalid("move_clocks: milliseconds or null")

      g["status"] not in [nil, "waiting", "live", "finished"] ->
        invalid("status")

      g["result"] not in [nil, "*" | @results] ->
        invalid("result")

      g["running"] not in [nil, "white", "black", "none"] ->
        invalid("running")

      Enum.any?(~w(white_ms black_ms reconstructed guessed rewritten), fn key ->
        g[key] != nil and not (is_integer(g[key]) and g[key] >= 0)
      end) ->
        invalid("a number")

      g["pgn"] != nil and not (is_binary(g["pgn"]) and byte_size(g["pgn"]) <= 100_000) ->
        invalid("pgn")

      true ->
        :ok
    end
  end

  defp pairing(t, uid) do
    board = Enum.find_value(t.rounds, fn r -> Enum.find(r["boards"], &(&1["game"] == uid)) end)

    cond do
      board == nil -> {:error, 409, "pairing_gone", "no game #{uid} in this tournament"}
      board["kind"] == "bye" or board["black"] == nil -> {:error, 422, "not_a_game", "a bye"}
      true -> {:ok, board}
    end
  end

  defp players(board, game) do
    if board["white"] == game["white"] and board["black"] == game["black"],
      do: :ok,
      else: {:error, 409, "pairing_changed", "not between these two players, in these colours"}
  end
end
