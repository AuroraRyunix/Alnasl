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

  describe "a real board is always recorded" do
    test "its bytes both ways and what was read from them, round or no round, with nothing to switch on" do
      # Not linked to any board of a round: plugged in, and that is all.
      board = fake_dgt("FAKE1")
      [after_e4] = boards_after(~w(e4))
      eventually(fn -> Boards.snapshot(board.id).raw == Position.to_text(Position.start()) end)
      set_pieces("FAKE1", after_e4)
      eventually(fn -> Boards.snapshot(board.id).raw == Position.to_text(after_e4) end)

      Recorder.flush()
      assert [capture | _] = Enum.filter(Recorder.list(), &(&1.board_id == board.id))
      # <data>/captures/board-<id>/<UTC start>.jsonl
      assert Path.dirname(capture.path) ==
               Path.join(Alnasl.Paths.captures(), "board-#{board.id}")

      assert Path.basename(capture.path) =~ ~r/^\d{8}-\d{6}(-\d+)?\.jsonl$/

      kinds =
        capture.path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!(&1)["k"])

      assert "rx" in kinds and "tx" in kinds
      assert Enum.count(kinds, &(&1 == "pos")) >= 2

      # And it replays: `mix alnasl.replay <that file>` is this.
      assert {:ok, report} = Recorder.dry_run(capture.path, [])
      assert report.moves == ["e4"]
    end

    test "a change of the tracker's settings reaches a game under way" do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 2})
      eventually(fn -> Boards.snapshot(board.id).status == :waiting_start end)
      # A move must stand for a minute: nothing is believed.
      Settings.put("tracker", %{"settle_ms" => 60_000})
      [after_e4] = boards_after(~w(e4))
      set_pieces("FAKE1", after_e4)
      eventually(fn -> Boards.snapshot(board.id).status == :settling end)
      assert sans(board.id) == []

      Settings.put("tracker", %{"settle_ms" => 20})
      eventually(fn -> sans(board.id) == ~w(e4) end)
    end
  end

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

      assert pgn =~ ~s([Event "Test Open"]) and pgn =~ ~s([White "GM Player 1"]) and
               pgn =~ ~s([Board "1"])

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
      {:ok, board} =
        Boards.create(%{
          name: "Sim",
          driver: "simulator",
          port: "sim-9",
          options: %{"moves" => ~w(e4 e5), "speed" => 600, "start_delay_ms" => 0}
        })

      snapshot =
        eventually(fn ->
          s = Boards.snapshot(board.id)
          s.raw && s.stats.positions > 3 && s
        end)

      assert snapshot.status == :unlinked
      refute snapshot.linked?
      assert snapshot.plies == []
      assert Outbox.pending_count() == 0
    end
  end

  describe "a DGT board on a serial port (the real driver, an emulated board)" do
    test "connects, says who it is, and tracks moves from field updates" do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 2})

      snapshot =
        eventually(fn ->
          s = Boards.snapshot(board.id)
          s.connected? && s.raw && s
        end)

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

      wrong =
        Position.start() |> put_elem(3, {:b, :k}) |> put_elem(4, {:b, :q}) |> put_elem(52, nil)

      set_pieces("FAKE1", wrong)

      snapshot =
        eventually(fn ->
          s = Boards.snapshot(board.id)
          s.problems != [] && s
        end)

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
      for position <- boards_after(~w(e4 e5)),
          do:
            (
              set_pieces("FAKE1", Position.rotate(position))
              eventually(fn -> Boards.snapshot(board.id).raw == Position.to_text(position) end)
            )

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

      clock = fn white, black, running ->
        Alnasl.Transport.Fake.update(
          "FAKE1",
          &Alnasl.Dgt.Emulator.set_clock(&1, %{white_ms: white, black_ms: black, running: running})
        )
      end

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

    test "out of sync: the raw board beside the certain one, resync, candidates, typed moves", %{
      board: board
    } do
      # A rook through its own pawn: nothing explains that.
      now = List.last(boards_after(~w(e4 e5)))
      illegal = now |> put_elem(40, {:w, :r}) |> put_elem(56, nil)
      set_pieces("FAKE1", illegal)

      snapshot =
        eventually(fn ->
          s = Boards.snapshot(board.id)
          s.status == :out_of_sync && s
        end)

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

      repairs =
        for e <- Alnasl.Log.list(),
            String.starts_with?(e.kind, "repair."),
            do: {e.kind, Alnasl.Log.data(e)["by"]}

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

      # Undo takes the last move back. The board still shows it, and is not
      # read again until it changes.
      assert :ok = Boards.undo(board.id)
      assert sans(board.id) == Enum.drop(full, -1)
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 3).moves == Enum.drop(full, -1)
      assert "repair.undo" in Enum.map(Alnasl.Log.list(), & &1.kind)
      assert :ok = Boards.append(board.id, ["Nf6"])

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

      # The board, which shows a pawn on e5, disagrees - and that is said as
      # soon as it next changes.
      set_pieces("FAKE1", put_elem(later, 48, nil))
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

    test "a late board is caught up when it is two moves in; further in, the arbiter asks" do
      late = fake_dgt("FAKE1")
      eventually(fn -> Boards.snapshot(late.id).connected? end)
      set_pieces("FAKE1", List.last(boards_after(~w(e4 e5))))
      {:ok, _} = Boards.link(late, 1, 2)
      eventually(fn -> sans(late.id) == ~w(e4 e5) end)
      assert Enum.all?(Boards.snapshot(late.id).plies, &(:recovered in &1.flags))

      # Three more went by unseen: more than the box works out by itself
      # (search depth 2). "Resync from the board" searches deeper.
      set_pieces("FAKE1", List.last(boards_after(~w(e4 e5 Nf3 Nc6 Nxe5))))
      eventually(fn -> Boards.snapshot(late.id).status == :out_of_sync end)
      assert sans(late.id) == ~w(e4 e5)
      Boards.resync(late.id)
      eventually(fn -> sans(late.id) == ~w(e4 e5 Nf3 Nc6 Nxe5) end)
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

      {[game], []} =
        Pgn.load(~s([White "A"]\n[Black "B"]\n[Result "0-1"]\n\n1. f3 e5 2. g4 Qh4# 0-1\n))

      assert {:ok, _} = Boards.attach_pgn(1, 2, game)
      assert Outbox.drain() == :empty

      assert %{moves: ~w(f3 e5 g4 Qh4#), status: "finished", result: "0-1"} =
               FakeIngest.game(1, 2)

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
      eventually(fn -> not Boards.running?(board.id) end)
      assert Boards.snapshot(board.id).plies |> Enum.map(& &1.san) == played

      # A move is made while the box is down.
      set_pieces("FAKE1", List.last(boards_after(played ++ ~w(Nc6))))
      {:ok, _pid} = Boards.start(Boards.get!(board.id))
      eventually(fn -> sans(board.id) == played ++ ~w(Nc6) end)
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 1).moves == played ++ ~w(Nc6)
    end
  end

  describe "the clock in the starting-position check" do
    setup do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
      eventually(fn -> Boards.snapshot(board.id).raw end)
      {:ok, board: board}
    end

    test "no clock, no clock check", %{board: board} do
      snapshot = Boards.snapshot(board.id)
      assert snapshot.problems == []
      assert snapshot.clock_check == nil and snapshot.clock_alarm == nil
      assert snapshot.status == :waiting_start
    end

    test "ready is the pieces AND a clock set so that White's side runs first", %{board: board} do
      set_clock("FAKE1", {:still, :white})
      eventually(fn -> Boards.snapshot(board.id).clock_check == :ok end)

      # The lever the wrong way, or the clock turned round: said in the
      # check, and nothing more - nobody has started anything yet.
      set_clock("FAKE1", {:still, :black})
      eventually(fn -> Boards.snapshot(board.id).clock_check == {:wrong, :black} end)
      snapshot = Boards.snapshot(board.id)
      assert snapshot.status == :waiting_start and snapshot.clock_alarm == nil
      assert snapshot.problems == []
      refute "clock.wrong_side" in log_kinds()

      set_clock("FAKE1", {:still, :white})
      eventually(fn -> Boards.snapshot(board.id).clock_check == :ok end)

      # Already running before move 1 is fine, on White's side.
      set_clock("FAKE1", :white)
      eventually(fn -> Boards.snapshot(board.id).clock.running == :white end)
      assert Boards.snapshot(board.id).clock_check == :ok
      refute "clock.wrong_side" in log_kinds()
    end

    test "Black's clock started from the starting position is an alarm of its own, and clears by itself",
         %{board: board} do
      set_clock("FAKE1", {:still, :black})
      set_clock("FAKE1", :black)
      eventually(fn -> Boards.snapshot(board.id).status == :clock_alarm end)

      snapshot = Boards.snapshot(board.id)
      assert snapshot.clock_alarm == :black and snapshot.clock_check == {:wrong, :black}
      # A clock alarm, not the pieces: they are where they belong.
      assert snapshot.problems == [] and snapshot.plies == []
      assert "clock.wrong_side" in log_kinds()
      refute "board.out_of_sync" in log_kinds()
      refute "clock.side_ok" in log_kinds()

      # Stopped, but still set the wrong way: still wrong.
      set_clock("FAKE1", {:still, :black})
      eventually(fn -> Boards.snapshot(board.id).clock.running == :none end)
      assert Boards.snapshot(board.id).status == :clock_alarm

      # Put right: gone, without anybody touching the box.
      set_clock("FAKE1", {:still, :white})
      eventually(fn -> Boards.snapshot(board.id).status == :waiting_start end)
      assert Boards.snapshot(board.id).clock_alarm == nil
      assert "clock.side_ok" in log_kinds()
      assert Enum.count(log_kinds(), &(&1 == "clock.wrong_side")) == 1
    end

    test "simply pressing the lever over puts it right too, and is not a move gone missing", %{
      board: board
    } do
      set_clock("FAKE1", :black)
      eventually(fn -> Boards.snapshot(board.id).status == :clock_alarm end)
      set_clock("FAKE1", :white)
      eventually(fn -> Boards.snapshot(board.id).status == :waiting_start end)

      play_on("FAKE1", board.id, ~w(e4))
      set_clock("FAKE1", :black)
      eventually(fn -> Boards.snapshot(board.id).clock.running == :black end)
      set_clock("FAKE1", :white)
      eventually(fn -> Boards.snapshot(board.id).clock.running == :white end)
      # Two presses for one move would be "Move missing?" had the first counted.
      assert Boards.snapshot(board.id).warning == nil
      assert Boards.snapshot(board.id).status == :live
    end

    test "the game played on with the clock turned round: the moves are followed, the alarm stays until a press leaves the right side running",
         %{board: board} do
      set_clock("FAKE1", :black)
      eventually(fn -> Boards.snapshot(board.id).status == :clock_alarm end)

      # White moves and presses; turned round, that starts what the box
      # knows as White's side - with Black to move.
      played = play_on("FAKE1", board.id, ~w(e4))
      set_clock("FAKE1", :white)
      played = play_on("FAKE1", board.id, ~w(e5), played)
      set_clock("FAKE1", :black)
      eventually(fn -> Boards.snapshot(board.id).clock.running == :black end)

      snapshot = Boards.snapshot(board.id)
      assert snapshot.status == :clock_alarm and snapshot.clock_alarm == :black
      assert Enum.map(snapshot.plies, & &1.san) == ~w(e4 e5)

      # The arbiter stops the clock, turns it round and starts it for White.
      set_clock("FAKE1", {:still, :white})
      set_clock("FAKE1", :white)
      play_on("FAKE1", board.id, ~w(Nf3), played)
      # White presses: Black's time runs with Black to move. Right at last.
      set_clock("FAKE1", :black)
      eventually(fn -> Boards.snapshot(board.id).status == :live end)
      assert Boards.snapshot(board.id).clock_alarm == nil
      assert "clock.side_ok" in log_kinds()
      refute "board.out_of_sync" in log_kinds()
    end

    test "a clock switched off is no clock: no check and no alarm, until it is back", %{
      board: board
    } do
      set_clock("FAKE1", :black)
      eventually(fn -> Boards.snapshot(board.id).status == :clock_alarm end)

      set_clock("FAKE1", :off)
      eventually(fn -> Boards.snapshot(board.id).status == :waiting_start end)
      snapshot = Boards.snapshot(board.id)
      assert snapshot.clock == nil and snapshot.clock_check == nil and snapshot.clock_alarm == nil
      assert snapshot.info[:clock] == false

      set_clock("FAKE1", {:still, :white})
      eventually(fn -> Boards.snapshot(board.id).clock_check == :ok end)
      assert Boards.snapshot(board.id).info[:clock] == true
    end

    test "a board that is not linked to a game has its clock checked all the same" do
      board = fake_dgt("FAKE2")
      eventually(fn -> Boards.snapshot(board.id).raw end)
      assert Boards.snapshot(board.id).clock_check == nil

      set_clock("FAKE2", {:still, :black})
      eventually(fn -> Boards.snapshot(board.id).clock_check == {:wrong, :black} end)
      set_clock("FAKE2", {:still, :white})
      eventually(fn -> Boards.snapshot(board.id).clock_check == :ok end)
    end

    test "there is no way to tell a board that its clock stands the other way round" do
      # The user's decision: the cable is too short for it to stand anywhere
      # else, so the box offers no such option - and ignores one if given.
      board = fake_dgt("FAKE3", %{round: 1, board_no: 2, options: %{"clock_white" => "right"}})
      eventually(fn -> Boards.snapshot(board.id).raw end)
      set_clock("FAKE3", {:still, :white}, 5_000_000, 4_000_000)
      eventually(fn -> Boards.snapshot(board.id).clock end)

      assert %{white_ms: 5_000_000, black_ms: 4_000_000, running: :none} =
               Boards.snapshot(board.id).clock

      for file <- Path.wildcard("lib/**/*.{ex,heex}") do
        refute File.read!(file) =~ "clock_white", "#{file} still knows clock_white"
      end
    end
  end

  describe "the recording of the real board, through the replay driver" do
    @session "test/fixtures/captures/real-06310-clock-session.jsonl"

    test "four minutes of a real clock and one knight: no moves, no alarm about the pieces, and the clock found turned round" do
      {:ok, board} =
        Boards.create(%{
          name: "Replay 06310",
          driver: "replay",
          port: "replay-06310",
          round: 1,
          board_no: 4,
          options: %{"path" => @session, "speed" => 300}
        })

      eventually(fn -> match?(%{finished?: true}, Boards.snapshot(board.id).player) end, 15_000)
      # Let the last readings through the board's own process.
      eventually(fn -> Boards.snapshot(board.id).clock_check == {:wrong, :black} end)
      snapshot = Boards.snapshot(board.id)

      # The pieces: a lone knight, last seen on d2. Never a starting
      # position, so never a game and never a move.
      assert snapshot.raw == String.duplicate(".", 51) <> "n" <> String.duplicate(".", 12)
      assert snapshot.plies == [] and snapshot.status == :waiting_start
      assert snapshot.detail == :not_start
      assert length(snapshot.problems) == 32

      # The clock: turned round and started on Black's side, running there
      # when the recording ends, White's time untouched at 1:30:30.
      assert snapshot.clock.running == :black
      assert snapshot.clock.white_ms == 5_430_000
      assert snapshot.clock.black_ms <= 5_287_000
      assert snapshot.info[:clock] == true
      assert snapshot.clock_alarm == nil

      kinds = log_kinds()
      refute "board.out_of_sync" in kinds
      refute "board.driver_failed" in kinds
      refute "clock.wrong_side" in kinds
      # The four presses were over untouched pieces - but not a starting
      # position, and no game: nothing claims a move is missing.
      assert Games.plies(Games.get(1, 4)) == []
    end
  end
end
