defmodule Alnasl.BoardServerTest do
  @moduledoc """
  The whole chain on the box, with processes and timers as in life: a driver
  delivers positions, the board's process records them, tracks the game,
  saves it, writes the PGN and queues the updates - and the round model
  around it: linking, a board turned round, a board carried to another
  table, a game attached from a PGN, the arbiter's repairs.
  """

  use Alnasl.HallCase

  alias Alnasl.Pgn

  @opera ~w(e4 e5 Nf3 d6 d4 Bg4 dxe5 Bxf3 Qxf3 dxe5 Bc4 Nf6 Qb3 Qe7 Nc3 c6 Bg5 b5 Nxb5 cxb5
            Bxb5+ Nbd7 O-O-O Rd8 Rxd7 Rxd7 Rd1 Qe6 Bxd7+ Nxd7 Qb8+ Nxb8 Rd8#)

  describe "a simulated board, from the first move to the server" do
    test "the game arrives whole: database, PGN, capture and server agree" do
      {:ok, board} =
        Boards.create(%{
          name: "Sim 1",
          driver: "simulator",
          port: "sim-1",
          round: 1,
          board_no: 1,
          options: %{
            "moves" => @opera,
            "speed" => 600,
            "seed" => 3,
            "start_delay_ms" => 0,
            "faults" => %{"lift" => 0.15, "takeback" => 0.1, "hover" => 0.1, "slide" => 0.2}
          }
        })

      eventually(fn -> sans(board.id) == @opera end, 20_000)
      snapshot = Boards.snapshot(board.id)

      # The players come from the tournament the server published.
      assert snapshot.white == "GM Player 1" and snapshot.black == "Player 2"
      assert snapshot.suggestion == "1-0"
      assert snapshot.status == :live
      assert snapshot.clock != nil

      game = Games.get(1, 1)
      assert Games.sans(game) == @opera
      assert game.status == "live", "mate is a suggestion until the arbiter says so"

      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 1).moves == @opera
      assert FakeIngest.game(1, 1).status == "live"

      # The PGN on the box: headers from the tournament, a clock comment per move.
      pgn = File.read!(Games.pgn_path(game))
      assert pgn =~ ~s([Event "Test Open"]) and pgn =~ ~s([White "GM Player 1"]) and pgn =~ ~s([Board "1"])
      assert pgn =~ "[%clk "
      assert {[read], []} = Pgn.load(pgn)
      assert read.moves == @opera

      # The capture: replayed through a fresh tracker, it gives the same game.
      Recorder.flush()
      assert [capture | _] = Enum.filter(Recorder.list(), &(&1.board_id == board.id))
      assert {:ok, report} = Recorder.dry_run(capture.path, [])
      assert report.moves == @opera
      assert report.alarms == []

      # The arbiter confirms the result; the server hears it.
      assert :ok = Boards.set_result(board.id, "1-0")
      assert Outbox.drain() == :empty
      assert %{status: "finished", result: "1-0"} = FakeIngest.game(1, 1)
      assert Boards.snapshot(board.id).status == :finished
      final = File.read!(Games.pgn_path(game))
      assert final =~ ~s([Result "1-0"]) and String.ends_with?(final, " 1-0
")
    end

    test "a board that is not linked shows its position and tracks nothing" do
      {:ok, board} = Boards.create(%{name: "Sim", driver: "simulator", port: "sim-9", options: %{"moves" => ~w(e4 e5), "speed" => 600, "start_delay_ms" => 0}})
      snapshot = eventually(fn -> s = Boards.snapshot(board.id); s.raw && s.stats.positions > 3 && s end)
      assert snapshot.status == :unlinked
      refute snapshot.linked?
      assert snapshot.plies == []
      assert Outbox.pending_count() == 0
    end
  end

  describe "a DGT board on a serial port (the real driver, an emulated board)" do
    test "connects, says who it is, and tracks moves from field updates" do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 2})
      snapshot = eventually(fn -> s = Boards.snapshot(board.id); s.connected? && s.raw && s end)
      assert snapshot.status == :waiting_start
      assert snapshot.problems == []
      assert eventually(fn -> Boards.get!(board.id).serial end) == "12345"
      assert Boards.get!(board.id).firmware == "1.8"

      played = play_on("FAKE1", board.id, ~w(e4 e5 Nf3 Nc6))
      assert sans(board.id) == played
      assert Boards.snapshot(board.id).status == :live
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 2).moves == played
    end

    test "the start-position check says what is wrong, in pieces and squares" do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
      wrong = Position.start() |> put_elem(3, {:b, :k}) |> put_elem(4, {:b, :q}) |> put_elem(52, nil)
      set_pieces("FAKE1", wrong)
      snapshot = eventually(fn -> s = Boards.snapshot(board.id); s.problems != [] && s end)
      assert {:swapped, {:b, :q}, 3, {:b, :k}, 4} in snapshot.problems
      assert {:wrong, 52, {:w, :p}, nil} in snapshot.problems
      eventually(fn -> Boards.snapshot(board.id).status == :waiting_start end)
    end

    test "a board plugged in turned round is noticed and read the right way up" do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
      eventually(fn -> Boards.snapshot(board.id).raw end)
      refute Boards.snapshot(board.id).flipped

      set_pieces("FAKE1", Position.rotate(Position.start()))
      eventually(fn -> Boards.snapshot(board.id).flipped end)
      assert Boards.snapshot(board.id).raw == Position.to_text(Position.start())
      assert Boards.get!(board.id).flipped

      # Moves made on the turned board are the moves of the game.
      for position <- boards_after(~w(e4 e5)), do: (set_pieces("FAKE1", Position.rotate(position)); eventually(fn -> Boards.snapshot(board.id).raw == Position.to_text(position) end))
      eventually(fn -> sans(board.id) == ~w(e4 e5) end)

      # The arbiter can also turn it by hand.
      assert :ok = Boards.flip(board, false)
      refute Boards.snapshot(board.id).flipped
    end

    test "unplugged: no signal; plugged back in: it carries on, and finds the moves made meanwhile" do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      played = play_on("FAKE1", board.id, ~w(e4 e5))

      Alnasl.Transport.Fake.unplug("FAKE1")
      eventually(fn -> Boards.snapshot(board.id).status == :no_signal end)

      # Two moves are made while nobody listens.
      set_pieces("FAKE1", List.last(boards_after(played ++ ~w(Nf3 Nc6))))
      Alnasl.Transport.Fake.replug("FAKE1")
      eventually(fn -> sans(board.id) == played ++ ~w(Nf3 Nc6) end, 10_000)

      snapshot = Boards.snapshot(board.id)
      assert snapshot.status == :recovered
      assert Enum.take(snapshot.plies, -2) |> Enum.all?(&(:recovered in &1.flags))
      kinds = Enum.map(Alnasl.Log.list(), & &1.kind)
      assert "board.disconnected" in kinds and "move.recovered" in kinds
    end

    test "the clock is read, pressed moves are accepted at once, and a press without a move is flagged" do
      Settings.put("tracker", %{"settle_ms" => 60_000})
      board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      clock = fn white, black, running -> Alnasl.Transport.Fake.update("FAKE1", &Alnasl.Dgt.Emulator.set_clock(&1, %{white_ms: white, black_ms: black, running: running})) end

      clock.(5_400_000, 5_400_000, :white)
      eventually(fn -> Boards.snapshot(board.id).clock end)

      # With a minute of settle time, only the press can have accepted this.
      set_pieces("FAKE1", hd(boards_after(~w(e4))))
      clock.(5_390_000, 5_400_000, :black)
      eventually(fn -> sans(board.id) == ~w(e4) end)
      assert %{white_ms: 5_390_000, running: :black} = Boards.snapshot(board.id).clock
      assert [%{clock: %{white_ms: 5_390_000}}] = Games.plies(Games.get(1, 1))

      # Two more presses and no move: something was missed.
      clock.(5_390_000, 5_380_000, :white)
      clock.(5_370_000, 5_380_000, :black)
      eventually(fn -> Boards.snapshot(board.id).warning == :move_missing end)
      assert "clock.move_missing" in Enum.map(Alnasl.Log.list(), & &1.kind)
    end
  end

  describe "the arbiter's repair tools" do
    setup do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 3})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      played = play_on("FAKE1", board.id, ~w(e4 e5))
      assert Outbox.drain() == :empty
      {:ok, board: board, played: played}
    end

    test "out of sync: the raw board beside the certain one, resync, candidates, typed moves", %{board: board} do
      # A rook through its own pawn: nothing explains that.
      now = List.last(boards_after(~w(e4 e5)))
      illegal = now |> put_elem(40, {:w, :r}) |> put_elem(56, nil)
      set_pieces("FAKE1", illegal)
      snapshot = eventually(fn -> s = Boards.snapshot(board.id); s.status == :out_of_sync && s end)
      assert snapshot.raw == Position.to_text(illegal)
      assert snapshot.certain == Position.to_text(now)
      assert sans(board.id) == ~w(e4 e5)
      assert "board.out_of_sync" in Enum.map(Alnasl.Log.list(), & &1.kind)

      assert {:ok, :none} = Boards.resync(board.id, 6)

      # The players put it right and play on while nobody watches: six plies.
      later = List.last(boards_after(~w(e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6)))
      set_pieces("FAKE1", later)
      eventually(fn -> Boards.snapshot(board.id).raw == Position.to_text(later) end)
      assert {:ok, {:candidates, n}} = Boards.resync(board.id, 6)
      assert n > 1
      candidates = Boards.snapshot(board.id).candidates
      index = Enum.find_index(candidates, &(&1 == ~w(Nf3 Nc6 Bb5 a6 Ba4 Nf6)))
      assert index != nil
      assert :ok = Boards.choose(board.id, index)
      assert sans(board.id) == ~w(e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6)
      assert Boards.snapshot(board.id).status == :recovered

      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 3).moves == ~w(e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6)
      repairs = for e <- Alnasl.Log.list(), String.starts_with?(e.kind, "repair."), do: {e.kind, Alnasl.Log.data(e)["by"]}
      assert {"repair.choose", "arbiter"} in repairs and {"repair.resync", "arbiter"} in repairs
    end

    test "typed moves, undo and an edited move are corrections the server takes", %{board: board} do
      # Six moves ahead of the tracker, more than it searches by itself.
      rest = ~w(Nf3 Nc6 Bb5 a6 Ba4 Nf6)
      full = ~w(e4 e5) ++ rest
      later = List.last(boards_after(full))
      set_pieces("FAKE1", later)
      eventually(fn -> Boards.snapshot(board.id).raw == Position.to_text(later) end)
      assert sans(board.id) == ~w(e4 e5)

      assert {:error, {1, _message}} = Boards.append(board.id, ~w(Ke5))
      assert :ok = Boards.append(board.id, rest)
      assert sans(board.id) == full
      assert Boards.snapshot(board.id).status == :live
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 3).moves == full
      assert Enum.take(Games.plies(Games.get(1, 3)), -6) |> Enum.all?(&(&1.flags == [:arbiter]))

      # Undo takes the last move back - and the board, which still shows it,
      # gives it back: read from the pieces this time, not typed.
      assert :ok = Boards.undo(board.id)
      eventually(fn -> sans(board.id) == full and List.last(Games.plies(Games.get(1, 3))).flags == [] end)
      assert "repair.undo" in Enum.map(Alnasl.Log.list(), & &1.kind)

      # An edited move is a statement about the game; the moves after it are
      # replayed where they still fit.
      assert {:error, _} = Boards.edit(board.id, 2, "Qh4")
      assert {:ok, 0} = Boards.edit(board.id, 2, "c5")
      assert sans(board.id) == ["e4", "c5" | rest]
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 3).moves == ["e4", "c5" | rest]
      assert Enum.at(Games.plies(Games.get(1, 3)), 1).flags == [:arbiter]
      {200, last} = List.last(FakeIngest.requests())
      assert last["replace"] == true

      # ...and the board, which shows a pawn on e5, now disagrees: that is said.
      eventually(fn -> Boards.snapshot(board.id).status == :out_of_sync end)
    end

    test "a result, a reopened game, and sending paused and resumed", %{board: board} do
      assert :ok = Boards.set_result(board.id, "1/2-1/2")
      assert {:error, :bad_result} = Boards.set_result(board.id, "2-0")
      assert Outbox.drain() == :empty
      assert %{status: "finished", result: "1/2-1/2"} = FakeIngest.game(1, 3)

      # A finished game does not follow the pieces being cleared away.
      set_pieces("FAKE1", Position.empty())
      eventually(fn -> Boards.snapshot(board.id).raw == Position.to_text(Position.empty()) end)
      assert sans(board.id) == ~w(e4 e5)
      assert Boards.snapshot(board.id).status == :finished

      set_pieces("FAKE1", List.last(boards_after(~w(e4 e5))))
      assert :ok = Boards.reopen(board.id)
      assert Outbox.drain() == :empty
      assert %{status: "live"} = FakeIngest.game(1, 3)

      assert :ok = Boards.pause(board.id, true)
      play_on("FAKE1", board.id, ~w(Nf3), ~w(e4 e5))
      assert Outbox.pending_count() == 0
      assert FakeIngest.game(1, 3).moves == ~w(e4 e5)

      assert :ok = Boards.pause(board.id, false)
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 3).moves == ~w(e4 e5 Nf3)
    end

    test "a game that starts from a set position", %{board: board} do
      fen = "4k3/8/8/8/8/8/4P3/4K3 w - - 0 40"
      set_pieces("FAKE1", Position.from_fen(fen))
      assert :ok = Boards.set_fen(board.id, fen)
      assert {:error, _} = Boards.set_fen(board.id, "nonsense")
      eventually(fn -> Boards.snapshot(board.id).status == :waiting_start end)

      set_pieces("FAKE1", Position.from_fen("4k3/8/8/8/4P3/8/8/4K3 b - - 0 40"))
      eventually(fn -> sans(board.id) == ~w(e4) end)
      assert Outbox.drain() == :empty
      assert %{moves: ["e4"], start_fen: ^fen} = FakeIngest.game(1, 3)
      assert File.read!(Games.pgn_path(Games.get(1, 3))) =~ ~s([FEN "#{fen}"])
    end
  end

  describe "the round" do
    test "a board carried to another table: the spare takes over the game where it stands" do
      first = fake_dgt("FAKE1", %{round: 1, board_no: 4})
      eventually(fn -> Boards.snapshot(first.id).connected? end)
      played = play_on("FAKE1", first.id, ~w(d4 d5 c4))

      spare = fake_dgt("FAKE2")
      eventually(fn -> Boards.snapshot(spare.id).connected? end)
      set_pieces("FAKE2", List.last(boards_after(played)))
      {:ok, _} = Boards.link(spare, 1, 4)

      assert Boards.get!(first.id).board_no == nil
      assert sans(spare.id) == played
      eventually(fn -> Boards.snapshot(spare.id).status == :live end)

      play_on("FAKE2", spare.id, ~w(e6), played)
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 4).moves == played ++ ~w(e6)
      assert "board.moved" in Enum.map(Alnasl.Log.list(), & &1.kind)
    end

    test "a late board is caught up when it is a few moves in" do
      late = fake_dgt("FAKE1")
      eventually(fn -> Boards.snapshot(late.id).connected? end)
      set_pieces("FAKE1", List.last(boards_after(~w(e4 e5 Qh5))))
      {:ok, _} = Boards.link(late, 1, 2)
      eventually(fn -> sans(late.id) == ~w(e4 e5 Qh5) end)
      assert Enum.all?(Boards.snapshot(late.id).plies, &(:recovered in &1.flags))
    end

    test "boards are linked in order with one call, and move on to the next round together" do
      a = fake_dgt("FAKE1")
      b = fake_dgt("FAKE2")
      Boards.link_in_order(1, 3)
      assert {Boards.get!(a.id).board_no, Boards.get!(b.id).board_no} == {3, 4}
      Boards.move_to_round(2)
      assert {Boards.get!(a.id).round, Boards.get!(b.id).round} == {2, 2}
      assert Settings.get("round") == 2
    end

    test "a game that was not captured is attached from a PGN and replaces what the server holds" do
      FakeIngest.plant(1, 2, ~w(a3 a6))
      {[game], []} = Pgn.load(~s([White "A"]\n[Black "B"]\n[Result "0-1"]\n\n1. f3 e5 2. g4 Qh4# 0-1\n))
      assert {:ok, _} = Boards.attach_pgn(1, 2, game)
      assert Outbox.drain() == :empty
      assert %{moves: ~w(f3 e5 g4 Qh4#), status: "finished", result: "0-1"} = FakeIngest.game(1, 2)

      stored = Games.get(1, 2)
      assert stored.source == "pgn" and stored.white == "Player 3"
      assert Enum.all?(Games.plies(stored), &(&1.flags == [:imported]))

      assert :ok = Boards.set_game_result(1, 2, "1/2-1/2")
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 2).result == "1/2-1/2"
    end

    test "a game survives the box being restarted mid-game" do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      played = play_on("FAKE1", board.id, ~w(e4 e5 Nf3))

      Boards.stop(board)
      refute Boards.running?(board.id)
      assert Boards.snapshot(board.id).plies |> Enum.map(& &1.san) == played

      # A move is made while the box is down.
      set_pieces("FAKE1", List.last(boards_after(played ++ ~w(Nc6))))
      {:ok, _pid} = Boards.start(Boards.get!(board.id))
      eventually(fn -> sans(board.id) == played ++ ~w(Nc6) end)
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 1).moves == played ++ ~w(Nc6)
    end
  end
end
