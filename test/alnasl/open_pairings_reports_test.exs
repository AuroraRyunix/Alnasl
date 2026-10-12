defmodule Alnasl.OpenPairingsReportsTest do
  @moduledoc """
  What goes back to the pairing program, and where each tournament's games
  go: the report of a game, `seq` and its three answers, the queue through
  an outage, a pairing that changed - and every game to its own results
  page and its own Lichess round.
  """

  use Alnasl.DataCase, async: false

  import Alnasl.LinkHelpers

  alias Alnasl.{Destination, FakeLichess, FakeOpenPairings, Games, Outbox, Repo, Tournaments}
  alias Alnasl.Destination.{Cursor, LichessBroadcast, OpenPairings}
  alias Alnasl.Tournaments.Link

  setup do
    pairing_program()
    {:ok, open: linked(17, name: "Open", boards: 2)}
  end

  # The game of a board as a board's process makes it: from the pairing.
  defp game(tournament, board, round \\ 1) do
    pairing = Tournaments.board(tournament.id, round, board)
    Games.ensure(tournament.id, round, board, Games.pairing_attrs(pairing))
  end

  # Plays `sans` onto `game`, queueing an update after each move, as a board does.
  defp play(game, sans, clock \\ nil, flags \\ []) do
    Enum.reduce(sans, game, fn san, game ->
      ply = %{san: san, flags: flags, clock: clock && Map.take(clock, [:white_ms, :black_ms])}
      {game, _replace?} = Games.apply_event(game, {:moves, [ply]}, 1_791_700_000_000)
      game |> Games.remember_clock(clock) |> Outbox.enqueue(clock, false)
    end)
  end

  defp reports, do: FakeOpenPairings.requests("POST", "/games")
  defp held(uid), do: FakeOpenPairings.game(17, uid)

  describe "a report" do
    test "is the whole game: moves, clocks, the PGN, the state, who plays, and what was reconstructed",
         %{open: open} do
      clock = %{white_ms: 5_398_000, black_ms: 5_391_000, running: :black}
      game = open |> game(1) |> play(~w(e4 e5), clock) |> play(~w(Nf3), clock, [:recovered])
      game = play(game, ~w(Nc6), clock, [:guessed, :rewritten])

      assert OpenPairings.pending_count() == 1
      assert {:empty, 1} = OpenPairings.deliver()
      assert OpenPairings.pending_count() == 0

      assert [{"POST", "/api/boards/v1/tournaments/17/games", 200, %{"games" => [sent]}}] =
               reports()

      assert sent == held("g17r1b1s0")

      assert %{
               "game" => "g17r1b1s0",
               "white" => 17_001,
               "black" => 17_002,
               "status" => "live",
               "moves" => ["e4", "e5", "Nf3", "Nc6"],
               "move_clocks" => [5_398_000, 5_391_000, 5_398_000, 5_391_000],
               "white_ms" => 5_398_000,
               "black_ms" => 5_391_000,
               "running" => "black",
               "result" => nil,
               "reconstructed" => 1,
               "guessed" => 1,
               "rewritten" => 1
             } = sent

      assert sent["seq"] == OpenPairings.seq(game)
      assert sent["pgn"] =~ ~s([White "IM Open Player 1"]) and sent["pgn"] =~ "1. e4"
      assert sent["pgn"] =~ ~s([TimeControl "5400+30"])
      refute is_map_key(sent, "replace")
    end

    test "carries the result the board saw: the arbiter's on the box, or what the position shows",
         %{open: open} do
      game = open |> game(1) |> play(~w(f3 e5 g4 Qh4#))

      # Mate on the board, nobody has confirmed it: live, and seen.
      game |> Games.suggest("0-1") |> Outbox.enqueue(nil, false)
      assert {:empty, 1} = OpenPairings.deliver()
      assert %{"status" => "live", "result" => "0-1"} = held("g17r1b1s0")

      Games.current(open.id, 1, 1) |> Games.finish("0-1") |> Outbox.enqueue(nil, false)
      assert {:empty, 1} = OpenPairings.deliver()
      assert %{"status" => "finished", "result" => "0-1"} = held("g17r1b1s0")

      # Closed without a result: finished, and the board saw none.
      other = open |> game(2) |> play(~w(d4))
      other |> Games.finish("*") |> Outbox.enqueue(nil, false)
      assert {:empty, 1} = OpenPairings.deliver()
      assert %{"status" => "finished", "result" => nil} = held("g17r1b2s0")
    end

    test "goes out once per change, not on the clock: a refresh of the time alone is not sent",
         %{open: open} do
      game = open |> game(1) |> play(~w(e4))
      assert {:empty, 1} = OpenPairings.deliver()

      # The twenty-second heartbeat the results site gets.
      Outbox.enqueue(game, %{white_ms: 5_000_000, black_ms: 5_400_000, running: :black}, false)
      assert OpenPairings.pending_count() == 1
      assert {:empty, 0} = OpenPairings.deliver()
      assert OpenPairings.pending_count() == 0
      assert length(reports()) == 1
    end

    test "seq only grows; a report that had arrived is a duplicate and counts as taken",
         %{open: open} do
      game = open |> game(1) |> play(~w(e4))
      {:empty, 1} = OpenPairings.deliver()
      first = held("g17r1b1s0")["seq"]

      game = play(game, ~w(e5))
      {:empty, 1} = OpenPairings.deliver()
      assert held("g17r1b1s0")["seq"] > first

      # The box died between the answer and the note of it: the same report again.
      Repo.delete_all(Cursor)
      assert {:empty, 1} = OpenPairings.deliver()
      assert held("g17r1b1s0")["moves"] == ~w(e4 e5)
      assert OpenPairings.refused() == []
      assert %{acked_seq: acked} = Repo.one!(Cursor)
      assert acked == game.seq
    end

    test "a game begun again for the same pairing outranks the one it replaces", %{open: open} do
      old = open |> game(1) |> play(~w(e4 e5))
      {:empty, 1} = OpenPairings.deliver()

      {_aside, fresh} = Games.set_aside(old, Tournaments.board(open.id, 1, 1))
      fresh |> play(~w(d4)) |> then(&assert(OpenPairings.seq(&1) > OpenPairings.seq(old)))
      assert {:empty, 1} = OpenPairings.deliver()
      assert held("g17r1b1s0")["moves"] == ~w(d4)
    end
  end

  describe "stale" do
    test "is said, listed, and overruled only on the arbiter's say-so", %{open: open} do
      # Another box reported this game, or this box was wiped and set up again.
      FakeOpenPairings.plant(17, "g17r1b1s0", 9_000_000_000_000_000)
      open |> game(1) |> play(~w(e4 e5))

      assert {:empty, 0} = OpenPairings.deliver()
      assert held("g17r1b1s0")["moves"] == []
      assert [{%{board_no: 1}, "stale"}] = OpenPairings.refused()
      assert OpenPairings.pending_count() == 0

      assert OpenPairings.force() == 1
      assert OpenPairings.pending_count() == 1
      assert {:empty, 1} = OpenPairings.deliver()

      assert %{"moves" => ["e4", "e5"], "replace" => true} = held("g17r1b1s0")
      assert OpenPairings.refused() == []
      # Forced once, not for ever.
      assert %{force: false} = Repo.one!(Cursor)
    end
  end

  describe "offline" do
    test "nothing is lost: the games wait, and go out as they stand when the line is back",
         %{open: open} do
      FakeOpenPairings.mode(:down)
      one = open |> game(1) |> play(~w(e4 e5))
      two = open |> game(2) |> play(~w(d4))

      assert {{:retry, {:unreachable, :econnrefused}, nil}, 0} = OpenPairings.deliver()
      assert OpenPairings.pending_count() == 2
      assert OpenPairings.pending_by_tournament() == %{open.id => 2}

      play(one, ~w(Nf3))
      play(two, ~w(d5 c4))
      FakeOpenPairings.mode(:ok)
      FakeOpenPairings.reset_requests()

      assert {:empty, 2} = OpenPairings.deliver()
      # One request, both games, lowest board first.
      assert [{"POST", _path, 200, %{"games" => [first, second]}}] = reports()
      assert first["moves"] == ~w(e4 e5 Nf3) and second["moves"] == ~w(d4 d5 c4)
      assert OpenPairings.pending_count() == 0
    end

    test "a server error and a rate limit are waited out, the latter for as long as asked",
         %{open: open} do
      open |> game(1) |> play(~w(e4))

      FakeOpenPairings.mode({:status, 502})
      assert {{:retry, {:http, 502, nil}, nil}, 0} = OpenPairings.deliver()

      FakeOpenPairings.mode(:rate_limited)
      assert {{:retry, :rate_limited, 60_000}, 0} = OpenPairings.deliver()
      assert OpenPairings.pending_count() == 1
    end

    test "a withdrawn code blocks the sender and says so on the link", %{open: open} do
      open |> game(1) |> play(~w(e4))
      FakeOpenPairings.withdraw(FakeOpenPairings.root() <> "#" <> Repo.one!(Link).secret)

      assert {{:blocked, :unauthorized}, 0} = OpenPairings.deliver()
      assert Repo.one!(Link).state == "unauthorized"
      assert OpenPairings.pending_count() == 1

      # And it does not ask again while the link stands refused.
      FakeOpenPairings.reset_requests()
      assert {{:blocked, :unauthorized}, 0} = OpenPairings.deliver()
      assert FakeOpenPairings.requests() == []
    end
  end

  describe "which games" do
    test "a second game on a board stays on the box, for every destination", %{open: open} do
      first = open |> game(1) |> play(~w(e4 e5))
      {:empty, 1} = OpenPairings.deliver()
      first = Games.finish(first, "1-0") |> Outbox.enqueue(nil, false)
      {:empty, 1} = OpenPairings.deliver()

      second = Games.next(first)
      assert second.local and second.game_no == 2
      before = Outbox.pending_count()
      play(second, ~w(d4 d5))

      assert Outbox.pending_count() == before
      assert OpenPairings.pending_count() == 0
      assert held("g17r1b1s0")["moves"] == ~w(e4 e5)
    end

    test "the box's own tournament has no pairing program to report to" do
      Games.ensure(1, 1, %{white: "A", black: "B"}) |> play(~w(e4))
      assert OpenPairings.pending_count() == 0
      assert {:empty, 0} = OpenPairings.deliver()
      assert reports() == []
    end

    test "a tournament the pairing program no longer lists is not reported to", %{open: open} do
      open |> game(1) |> play(~w(e4))
      FakeOpenPairings.remove_tournament(17)

      # The report finds out before the poll does.
      assert {:empty, 0} = OpenPairings.deliver()
      assert again(open).gone
      assert OpenPairings.pending_count() == 0
    end
  end

  describe "a pairing that changed" do
    test "is learned from the answer too: the game is flagged, not sent again, and the tournament is owed",
         %{open: open} do
      game = open |> game(1) |> play(~w(e4 e5))
      {:empty, 1} = OpenPairings.deliver()

      # Colours turned in OpenPairings; the box has not polled since.
      FakeOpenPairings.boards(17, 1, fn [one | rest] ->
        [%{one | "white" => one["black"], "black" => one["white"]} | rest]
      end)

      play(game, ~w(Nf3))
      assert {:empty, 0} = OpenPairings.deliver()
      assert %{pairing_flag: "changed"} = Games.current(open.id, 1, 1)
      assert [{%{board_no: 1}, "pairing_changed" <> _}] = OpenPairings.refused()
      assert OpenPairings.pending_count() == 0
      assert again(open).version == nil

      # More moves change nothing: it waits for the arbiter.
      Games.current(open.id, 1, 1) |> play(~w(Nc6))
      assert OpenPairings.pending_count() == 0
      assert held("g17r1b1s0")["moves"] == ~w(e4 e5)

      # "These moves are that game": reported again, under the new pairing.
      poll()
      {:ok, _game} = Alnasl.Boards.adopt_pairing(Games.current(open.id, 1, 1))
      assert {:empty, 1} = OpenPairings.deliver()

      assert %{"white" => 17_002, "black" => 17_001, "moves" => ["e4", "e5", "Nf3", "Nc6"]} =
               held("g17r1b1s0")
    end

    test "a game the pairing program moved to another board number goes there, with its moves",
         %{open: open} do
      game = open |> game(1) |> play(~w(e4 e5))
      _unbegun = game(open, 2)

      # Boards 1 and 2 change numbers.
      FakeOpenPairings.boards(17, 1, fn [one, two] ->
        [%{two | "board" => 1, "label" => "1"}, %{one | "board" => 2, "label" => "2"}]
      end)

      poll()
      moved = Repo.get!(Games.Game, game.id)
      assert moved.board_no == 2 and moved.pairing_flag == nil
      assert Games.sans(moved) == ~w(e4 e5)
      assert moved.remote_game == "g17r1b1s0"
      # Its results-site target moved with it: round 1, board 2 from now on.
      assert Games.body(moved)["board"] == 2
      assert Games.current(open.id, 1, 1) == nil or not Games.begun?(Games.current(open.id, 1, 1))
    end

    test "the flag goes by itself when the pairing is put back as it was", %{open: open} do
      open |> game(1) |> play(~w(e4))
      original = FakeOpenPairings.document(17)["rounds"] |> hd() |> Map.fetch!("boards")

      FakeOpenPairings.pair(17, 1, 2)
      poll()
      assert %{pairing_flag: "gone"} = Games.current(open.id, 1, 1)

      FakeOpenPairings.boards(17, 1, fn _boards -> original end)
      poll()
      assert %{pairing_flag: nil, remote_game: "g17r1b1s0"} = Games.current(open.id, 1, 1)
    end
  end

  describe "every tournament to its own" do
    setup %{open: open} do
      # A results site that takes any page, and says which it was asked for.
      test = self()

      Application.put_env(:alnasl, :req_options,
        plug: fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          [_api, _tournaments, slug, _live] = conn.path_info
          key = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
          send(test, {:results_site, slug, key, Jason.decode!(raw)})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, ~s({"status":"ok","applied":true}))
        end
      )

      on_exit(fn -> Application.delete_env(:alnasl, :req_options) end)
      {:ok, u12: linked(18, name: "U12", boards: 2), open: again(open)}
    end

    test "results page: each game with its own tournament's address and key", ctx do
      %{open: open, u12: u12} = ctx
      open |> game(1) |> play(~w(e4))
      u12 |> game(1) |> play(~w(d4))

      assert Outbox.pending_by_tournament() == %{open.id => 1, u12.id => 1}
      assert Outbox.drain() == :empty

      open_key = "Bearer " <> FakeOpenPairings.relay_key(17)
      u12_key = "Bearer " <> FakeOpenPairings.relay_key(18)
      assert_received {:results_site, "slug-17", ^open_key, %{"board" => 1, "moves" => ["e4"]}}
      assert_received {:results_site, "slug-18", ^u12_key, %{"board" => 1, "moves" => ["d4"]}}
      refute_received {:results_site, _slug, _key, _body}
    end

    test "a tournament that is not published holds up nobody else", ctx do
      %{open: open, u12: u12} = ctx
      FakeOpenPairings.update(18, &%{&1 | openresults: nil})
      poll()

      u12 |> game(1) |> play(~w(d4))
      open |> game(1) |> play(~w(e4))

      Outbox.drain()
      assert_received {:results_site, "slug-17", _key, %{"moves" => ["e4"]}}
      refute_received {:results_site, _slug, _key, _body}
      # Nothing piles up for a results page that may never be.
      assert Outbox.pending_by_tournament() == %{}

      # Still reported to the pairing program, which is where the contract sends it.
      assert {:empty, 2} = OpenPairings.deliver()

      # Published after all: the game goes there as it stands, in full.
      Games.current(u12.id, 1, 1) |> play(~w(d5))

      FakeOpenPairings.update(18, fn t ->
        %{
          t
          | openresults: %{
              "server_url" => "http://results.test",
              "slug" => "slug-18",
              "relay_key" => FakeOpenPairings.relay_key(18)
            }
        }
      end)

      poll()
      assert Outbox.pending_by_tournament() == %{u12.id => 1}
      Outbox.drain()

      assert_received {:results_site, "slug-18", _key,
                       %{"moves" => ["d4", "d5"], "replace" => true}}
    end

    test "Lichess: each tournament's round gets that tournament's games, and no more than the arbiter shows",
         ctx do
      %{open: open, u12: u12} = ctx
      start_supervised!(FakeLichess)
      FakeLichess.install()
      on_exit(fn -> FakeLichess.uninstall() end)
      # The fake's round is the Open's; the box's own tournament has none.
      own_put(lichess_round_id: "", lichess_token: "")

      Tournaments.update!(open, %{
        lichess_round_id: FakeLichess.round_id(),
        lichess_token: FakeLichess.token(),
        lichess_round: 1
      })

      open |> game(1) |> play(~w(e4 e5))
      u12 |> game(1) |> play(~w(d4))

      assert LichessBroadcast.pending_by_tournament()[open.id] == 1
      assert {:empty, 1} = LichessBroadcast.deliver()

      assert [{200, [pushed]}] = FakeLichess.pushes()
      assert pushed.headers["White"] == "Open Player 1"
      assert pushed.headers["WhiteTitle"] == "IM" and pushed.headers["WhiteElo"] == "2001"
      assert pushed.headers["Event"] == "Open"
      assert pushed.moves == ~w(e4 e5)

      # The arbiter hides ratings on the public pages: they stay home.
      FakeOpenPairings.update(17, &Map.put(&1, :display, %{"rating" => false, "title" => true}))
      poll()
      Games.current(open.id, 1, 1) |> play(~w(Nf3))
      assert {:empty, 1} = LichessBroadcast.deliver()
      [{200, [again]} | _] = FakeLichess.pushes() |> Enum.reverse()
      assert again.headers["WhiteTitle"] == "IM"
      refute is_map_key(again.headers, "WhiteElo")

      assert Destination.enabled?(LichessBroadcast)
    end
  end
end
