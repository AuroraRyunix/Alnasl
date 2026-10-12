defmodule Alnasl.OpenPairingsRoundsTest do
  @moduledoc """
  Several tournaments on one box, with boards: which table plays in which,
  a round that starts by itself when the pairing program pairs it - for
  that tournament's boards and no others - and a pairing that changes under
  a game that has begun.
  """

  use Alnasl.HallCase

  import Alnasl.LinkHelpers

  alias Alnasl.{FakeOpenPairings, Tables, Tournaments}

  setup do
    pairing_program()
    open = linked(17, name: "Open", boards: 2)
    u12 = linked(18, name: "U12", boards: 2)
    {:ok, open: open, u12: u12}
  end

  # Four boards on tables 1-4: 1 and 2 play the Open, 3 and 4 the U12.
  defp hall(%{open: open, u12: u12}) do
    boards =
      for n <- 1..4 do
        board = fake_dgt("FAKE#{n}")
        {:ok, board} = Tables.set_table(board, n)
        board
      end

    {:ok, _} = Tournaments.assign_tables(open, 1, 2)
    {:ok, _} = Tournaments.assign_tables(u12, 3, 4)
    # A board is asked who is on its line before it is read: a moment.
    for board <- boards, do: eventually(fn -> Boards.snapshot(board.id).connected? end)
    Enum.map(boards, &Boards.get!(&1.id))
  end

  defp where(board) do
    board = Boards.get!(board.id)
    {board.tournament_id, board.round, board.board_no}
  end

  describe "tables and tournaments" do
    test "a range of tables plays in a tournament, and its board numbers begin again at 1", ctx do
      %{open: open, u12: u12} = ctx
      [a, b, c, d] = hall(ctx)

      assert where(a) == {open.id, 1, 1}
      assert where(b) == {open.id, 1, 2}
      # Table 3 is board 1 of the second tournament.
      assert where(c) == {u12.id, 1, 1}
      assert where(d) == {u12.id, 1, 2}
      assert Tables.home_board(c) == 1
      refute Tables.remapped?(Boards.get!(c.id))

      # Each board carries the names of its own tournament's pairing.
      eventually(fn -> Boards.snapshot(a.id).white == "IM Open Player 1" end)
      eventually(fn -> Boards.snapshot(c.id).white == "IM U12 Player 1" end)
      assert Boards.snapshot(d.id).black == "U12 Player 4"

      # The same round and board twice, once per tournament.
      assert %{remote_game: "g17r1b1s0"} = Games.current(open.id, 1, 1)
      assert %{remote_game: "g18r1b1s0"} = Games.current(u12.id, 1, 1)

      # "Ready for round 1?" is asked per tournament: table 3 being the U12's
      # board 1 is how it should be, not a board that was remapped or a gap.
      kinds = for check <- Tables.checks(u12.id, 1), do: elem(check.what, 0)
      # (The emulated boards all report one serial, which is said of each.)
      assert Enum.uniq(kinds) -- [:start_wrong, :clock_wrong, :same_serial] == []
      assert Enum.all?(Tables.checks(open.id, 1), &(&1.board_id in [a.id, b.id, nil]))
    end

    test "a board given a table of a tournament's range joins it; one board can be moved by hand",
         ctx do
      %{open: open, u12: u12} = ctx
      [_a, _b, _c, d] = hall(ctx)

      spare = fake_dgt("FAKE5")
      assert Boards.get!(spare.id).tournament_id == own().id

      # The spare takes the sticker of table 4: it is the U12's board 2 now.
      {:ok, _} = Tables.set_table(spare, 4)
      assert where(spare) == {u12.id, 1, 2}
      assert Boards.get!(d.id).table_no == nil

      # And by hand, whatever its table: into the Open.
      {:ok, _} = Tables.assign(Boards.get!(d.id), open)
      assert {open_id, nil, nil} = where(d)
      assert open_id == open.id
    end

    test "the two tournaments' ranges cannot overlap: the later word wins", ctx do
      %{open: open, u12: u12} = ctx
      hall(ctx)
      {:ok, _} = Tournaments.assign_tables(u12, 2, 4)
      assert %{table_from: nil, table_to: nil} = again(open)
      assert %{table_from: 2, table_to: 4} = again(u12)
      assert {:error, :range} = Tournaments.assign_tables(u12, 4, 2)
    end
  end

  describe "a round paired in OpenPairings" do
    test "starts by itself for that tournament's boards, and touches no other", ctx do
      %{open: open, u12: u12} = ctx
      [a, b, c, d] = hall(ctx)

      FakeOpenPairings.finish_round(17, 1)
      FakeOpenPairings.pair(17, 2, 2)
      poll()

      assert again(open).round == 2 and again(open).remote_round == 2
      assert where(a) == {open.id, 2, 1}
      assert where(b) == {open.id, 2, 2}

      # The U12 is where it was: its round, its boards, its games.
      assert again(u12).round == 1
      assert where(c) == {u12.id, 1, 1}
      assert where(d) == {u12.id, 1, 2}

      # The new round's game is the pairing program's, with its names.
      game = eventually(fn -> Games.current(open.id, 2, 1) end)
      assert game.remote_game =~ "g17r2b1"
      assert game.white == "IM Open Player 1"
      assert {game.remote_white, game.remote_black} == {17_001, 17_002}
      eventually(fn -> Boards.snapshot(a.id).round == 2 end)
      assert "round.started" in log_kinds()

      # Round 1's games stay as they are.
      assert %{remote_game: "g17r1b1s0"} = Games.current(open.id, 1, 1)
    end

    test "is not started by the box when the tournament is told not to; the button still works",
         ctx do
      %{u12: u12} = ctx
      [_a, _b, c, _d] = hall(ctx)
      Tournaments.update!(u12, %{auto_start: false})

      FakeOpenPairings.finish_round(18, 1)
      FakeOpenPairings.pair(18, 2, 2)
      poll()

      assert %{round: 1, remote_round: 2} = again(u12)
      assert where(c) == {u12.id, 1, 1}

      # "Start round 2", by hand.
      assert :ok = Boards.start_round(u12.id, 2)
      assert where(c) == {u12.id, 2, 1}
      assert again(u12).round == 2
    end

    test "the arbiter may look at another round; the box follows again when the next is paired",
         ctx do
      %{open: open} = ctx
      [a | _] = hall(ctx)

      FakeOpenPairings.finish_round(17, 1)
      FakeOpenPairings.pair(17, 2, 2)
      poll()
      assert where(a) == {open.id, 2, 1}

      # Back to round 1 by hand: a game that was played on and not finished.
      Boards.start_round(open.id, 1)
      FakeOpenPairings.boards(17, 2, fn boards -> boards end)
      poll()
      assert where(a) == {open.id, 1, 1}

      FakeOpenPairings.finish_round(17, 2)
      FakeOpenPairings.pair(17, 3, 2)
      poll()
      assert where(a) == {open.id, 3, 1}
    end

    test "the boards are not walked back to an earlier round while a game is being played",
         ctx do
      %{open: open} = ctx
      [a | _] = hall(ctx)

      # A round robin: every round is paired at once, and the round that is
      # on is the first with a game still open. (In a Swiss the pairing
      # program no longer goes back at all; the box does not rely on it.)
      FakeOpenPairings.update(17, &Map.put(&1, :system, :round_robin))
      FakeOpenPairings.pair(17, 2, 2)
      poll()
      assert where(a) == {open.id, 1, 1}

      FakeOpenPairings.finish_round(17, 1)
      poll()
      assert where(a) == {open.id, 2, 1}
      eventually(fn -> Boards.snapshot(a.id).status == :waiting_start end)
      play_on("FAKE1", a.id, ~w(e4 e5))

      # The arbiter clears a result of round 1 to correct it: for a minute the
      # pairing program says round 1 is the one that is on.
      FakeOpenPairings.boards(17, 1, fn [one | rest] -> [%{one | "result" => nil} | rest] end)
      poll()

      assert %{round: 2, remote_round: 1} = again(open)
      assert where(a) == {open.id, 2, 1}
      assert sans(a.id) == ~w(e4 e5)

      # Entered again: nothing to do, the box never left.
      FakeOpenPairings.finish_round(17, 1)
      poll()
      assert %{round: 2, remote_round: 2} = again(open)
      assert where(a) == {open.id, 2, 1}
    end

    test "offline, a round is started by hand and takes the pairings when they arrive", ctx do
      %{open: open} = ctx
      [a | _] = hall(ctx)
      FakeOpenPairings.mode(:down)
      poll()

      Boards.start_round(open.id, 2)
      assert where(a) == {open.id, 2, 1}
      game = eventually(fn -> Games.current(open.id, 2, 1) end)
      assert game.remote_game == nil and game.white == nil

      FakeOpenPairings.mode(:ok)
      FakeOpenPairings.finish_round(17, 1)
      FakeOpenPairings.pair(17, 2, 2)
      poll()

      assert %{white: "IM Open Player 1"} = game = Games.current(open.id, 2, 1)
      assert game.remote_game =~ "g17r2b1"
      eventually(fn -> Boards.snapshot(a.id).white == "IM Open Player 1" end)
    end
  end

  describe "a pairing changed after the round began" do
    test "on a board where nothing was played, the board simply takes the new pairing", ctx do
      %{open: open} = ctx
      [a | _] = hall(ctx)
      eventually(fn -> Boards.snapshot(a.id).white == "IM Open Player 1" end)

      # The arbiter turned the colours of board 1.
      FakeOpenPairings.boards(17, 1, fn [one | rest] ->
        [%{one | "white" => one["black"], "black" => one["white"]} | rest]
      end)

      poll()
      game = Games.current(open.id, 1, 1)
      assert {game.white, game.black} == {"Open Player 2", "IM Open Player 1"}
      assert {game.remote_white, game.remote_black} == {17_002, 17_001}
      assert game.pairing_flag == nil
      eventually(fn -> Boards.snapshot(a.id).white == "Open Player 2" end)
    end

    test "under a game with moves, the game is kept and flagged; 'these moves are that game' renames it",
         ctx do
      %{open: open} = ctx
      [a | _] = hall(ctx)
      eventually(fn -> Boards.snapshot(a.id).status == :waiting_start end)
      play_on("FAKE1", a.id, ~w(e4 e5 Nf3))

      FakeOpenPairings.boards(17, 1, fn [one | rest] ->
        [%{one | "white" => one["black"], "black" => one["white"]} | rest]
      end)

      poll()
      game = Games.current(open.id, 1, 1)
      assert game.pairing_flag == "changed"
      # Nothing was renamed or thrown away behind the arbiter's back.
      assert {game.white, game.black} == {"IM Open Player 1", "Open Player 2"}
      assert Games.sans(game) == ~w(e4 e5 Nf3)
      eventually(fn -> Boards.snapshot(a.id).pairing_flag == "changed" end)
      assert "pairing.changed" in log_kinds()

      # The board goes on being followed meanwhile.
      play_on("FAKE1", a.id, ~w(Nc6), ~w(e4 e5 Nf3))

      assert {:ok, adopted} = Boards.adopt_pairing(Games.current(open.id, 1, 1))
      assert adopted.pairing_flag == nil
      assert {adopted.white, adopted.black} == {"Open Player 2", "IM Open Player 1"}
      assert Games.sans(adopted) == ~w(e4 e5 Nf3 Nc6)
      eventually(fn -> Boards.snapshot(a.id).pairing_flag == nil end)
      assert Boards.snapshot(a.id).white == "Open Player 2"
    end

    test "'set it aside' keeps the game on the box and begins a new one for the new pairing",
         ctx do
      %{open: open} = ctx
      [a | _] = hall(ctx)
      eventually(fn -> Boards.snapshot(a.id).status == :waiting_start end)
      play_on("FAKE1", a.id, ~w(d4 d5))

      # The round was paired again: other game ids altogether.
      FakeOpenPairings.pair(17, 1, 2)
      poll()
      assert %{pairing_flag: "gone"} = old = Games.current(open.id, 1, 1)

      assert :ok = Boards.set_aside(old)

      assert [%{game_no: 1, local: true, status: "finished", result: "*"} = aside, fresh] =
               Games.history(open.id, 1, 1)

      assert Games.sans(aside) == ~w(d4 d5)
      assert aside.pairing_flag == nil
      assert %{game_no: 2, local: false, plies: "[]"} = fresh
      assert fresh.remote_game =~ "g17r1b1s" and fresh.remote_game != old.remote_game

      # The board reads nothing into the new game until the pieces are set up again.
      set_pieces("FAKE1", Position.start())
      eventually(fn -> Boards.snapshot(a.id).game_no == 2 end)
      play_on("FAKE1", a.id, ~w(c4))
      assert Games.sans(Games.current(open.id, 1, 1)) == ~w(c4)
    end
  end
end
