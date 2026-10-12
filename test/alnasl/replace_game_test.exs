defmodule Alnasl.ReplaceGameTest do
  @moduledoc """
  The game on the board is the game that leaves the box.

  A new game on a board whose pairing's game has no result is the board's
  game of the round - sent to the results site, OpenPairings and Lichess,
  replacing what they hold - and the old one stays at home. A game with a
  result is never overwritten: the new game is an extra one that stays.
  A box from before the rule is put right once, at start-up.
  """

  use Alnasl.HallCase

  import Alnasl.LinkHelpers

  alias Alnasl.{FakeOpenPairings, Tables, Tournaments}
  alias Alnasl.Destination.OpenPairings
  alias Alnasl.Games.Game

  setup do
    pairing_program()
    open = linked(17, name: "Open", boards: 2)
    board = fake_dgt("FAKE1")
    {:ok, board} = Tables.set_table(board, 1)
    {:ok, _} = Tournaments.assign_tables(open, 1, 2)
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    eventually(fn -> Boards.snapshot(board.id).white == "IM Open Player 1" end)
    {:ok, open: open, board: board}
  end

  defp history(open), do: Games.history(open.id, 1, 1)
  defp held, do: FakeOpenPairings.game(17, "g17r1b1s0")

  # What the box queued for the results site for a game, oldest first.
  # (The linked tournament has a slug and key of its own, which the fake
  # results server does not know: what was queued is what is judged.)
  defp queued(game) do
    Repo.all(from e in Alnasl.Outbox.Entry, where: e.game_id == ^game.id, order_by: e.id)
  end

  defp deliver, do: OpenPairings.deliver()

  defp last_log(kind) do
    Alnasl.Log.list()
    |> Enum.filter(&(&1.kind == kind))
    |> List.first()
    |> Map.fetch!(:data)
    |> then(&if(is_binary(&1), do: Jason.decode!(&1), else: &1))
  end

  describe "a new game over a game with no result" do
    test "is the game of the pairing: sent in place of the old one, which stays at home", ctx do
      %{open: open, board: board} = ctx
      play_on("FAKE1", board.id, ~w(e4 e5 Nf3))
      deliver()
      assert held()["moves"] == ~w(e4 e5 Nf3)
      queued_before = length(queued(Games.current(open.id, 1, 1)))
      assert queued_before > 0

      assert :ok = Boards.new_game(board.id)

      assert [
               %Game{game_no: 1, local: true, result: "*", status: "finished"} = old,
               %Game{game_no: 2, local: false, plies: "[]"} = fresh
             ] = history(open)

      assert Games.sans(old) == ~w(e4 e5 Nf3)
      # The pairing's id and players follow the game that leaves.
      assert fresh.remote_game == old.remote_game
      assert {fresh.remote_white, fresh.remote_black} == {old.remote_white, old.remote_black}
      assert Games.sendable(open.id, 1, 1).id == fresh.id
      assert %{"kind" => "replace"} = last_log("game.new")

      # Both places take the empty game in place of the abandoned one: the
      # abandoned game is not announced as closed, its replacement says it all.
      assert length(queued(old)) == queued_before
      assert [%{replace: true, plies: 0}] = queued(fresh)
      deliver()
      assert held()["moves"] == []
      assert held()["seq"] > OpenPairings.seq(old)

      # ... and then the moves of the new one, as they come.
      set_pieces("FAKE1", Position.start())
      eventually(fn -> Boards.snapshot(board.id).game_no == 2 end)
      play_on("FAKE1", board.id, ~w(d4 d5))
      deliver()
      assert held()["moves"] == ~w(d4 d5)
      assert %{local: false} = current = Games.current(open.id, 1, 1)
      assert %{plies: 2} = List.last(queued(current))

      # The game before is kept, with its PGN.
      assert File.read!(Games.pgn_path(old)) =~ "1. e4 e5 2. Nf3"
    end

    test "again: the newest is the one that leaves, every older one stays", ctx do
      %{open: open, board: board} = ctx
      play_on("FAKE1", board.id, ~w(e4))
      assert :ok = Boards.new_game(board.id)
      assert :ok = Boards.new_game(board.id)

      assert [
               %{game_no: 1, local: true},
               %{game_no: 2, local: true},
               %{game_no: 3, local: false}
             ] = history(open)
    end

    test "outranks what the pairing program holds: a higher sequence, no 'stale'", ctx do
      %{open: open, board: board} = ctx
      play_on("FAKE1", board.id, ~w(e4 e5))
      deliver()
      held_before = held()["seq"]
      Boards.new_game(board.id)
      new = Games.current(open.id, 1, 1)
      assert OpenPairings.seq(new) > held_before
      deliver()
      assert OpenPairings.refused() == []
      assert held()["seq"] == OpenPairings.seq(Games.current(open.id, 1, 1))
    end

    test "a game switched in is sent with 'replace', whatever count is held", ctx do
      %{open: open, board: board} = ctx
      play_on("FAKE1", board.id, ~w(e4 e5))
      Boards.new_game(board.id, :extra)
      # The first game still leaves; the extra one is made to, while the
      # pairing program holds a count far above either.
      FakeOpenPairings.plant(17, "g17r1b1s0", 9_000_000_000_000_000)
      extra = Games.current(open.id, 1, 1)
      assert extra.local
      assert :ok = Boards.send_this(extra)
      deliver()
      assert %{"replace" => true, "moves" => []} = held()
      assert OpenPairings.refused() == []
    end
  end

  describe "a new game over a game with a result" do
    test "is an extra game, and stays on the box", ctx do
      %{open: open, board: board} = ctx
      play_on("FAKE1", board.id, ~w(f3 e5 g4 Qh4#))
      Boards.set_result(board.id, "0-1")
      deliver()

      assert Games.next_kind(Games.current(open.id, 1, 1)) == :extra
      assert :ok = Boards.new_game(board.id)

      assert [%{game_no: 1, local: false, result: "0-1"}, %{game_no: 2, local: true}] =
               history(open)

      assert %{"kind" => "extra"} = last_log("game.new")
      deliver()
      assert held()["moves"] == ~w(f3 e5 g4 Qh4#)
      assert held()["result"] == "0-1"
      # Nothing of the extra game is queued for the results site.
      assert queued(Games.current(open.id, 1, 1)) == []
    end

    test "can be made to replace the game of the pairing, on purpose", ctx do
      %{open: open, board: board} = ctx
      play_on("FAKE1", board.id, ~w(f3 e5 g4 Qh4#))
      Boards.set_result(board.id, "0-1")
      deliver()

      assert :ok = Boards.new_game(board.id, :replace)

      assert [%{game_no: 1, local: true, result: "0-1"}, %{game_no: 2, local: false}] =
               history(open)

      deliver()
      assert held()["moves"] == []
      assert [%{replace: true, plies: 0}] = queued(Games.current(open.id, 1, 1))
    end

    test "a won, drawn or lost game is a result; 'no result' and a live game are not" do
      refute Games.decided?(%Game{status: "finished", result: "*"})
      refute Games.decided?(%Game{status: "live", result: nil})
      refute Games.decided?(nil)

      for result <- ["1-0", "0-1", "1/2-1/2"],
          do: assert(Games.decided?(%Game{status: "finished", result: result}))
    end
  end

  describe "no pairing names the board" do
    test "a new game stays on the box as it always did, and can be chosen to leave" do
      own = Tournaments.default()
      plain = fake_dgt("FAKE2", %{tournament_id: own.id, round: 1, board_no: 7})
      eventually(fn -> Boards.snapshot(plain.id).connected? end)
      play_on("FAKE2", plain.id, ~w(e4 e5))

      assert Games.next_kind(Games.current(own.id, 1, 7)) == :extra
      assert :ok = Boards.new_game(plain.id)
      assert [%{local: false}, %{local: true}] = Games.history(own.id, 1, 7)

      Outbox.drain()
      assert FakeIngest.game(1, 7).moves == ~w(e4 e5)

      assert :ok = Boards.send_this(Games.current(own.id, 1, 7))
      assert [%{local: true}, %{local: false}] = Games.history(own.id, 1, 7)

      # The results server takes the new game in place of the old: 'replace'.
      Outbox.drain()
      assert FakeIngest.game(1, 7).moves == []
    end
  end

  describe "send this one instead" do
    test "makes the live game the one that leaves, replacing what is held", ctx do
      %{open: open, board: board} = ctx
      play_on("FAKE1", board.id, ~w(f3 e5 g4 Qh4#))
      Boards.set_result(board.id, "0-1")
      Boards.new_game(board.id)
      assert %{local: true, game_no: 2} = extra = Games.current(open.id, 1, 1)

      assert :ok = Boards.send_this(extra)
      assert [%{local: true, game_no: 1}, %{local: false, game_no: 2}] = history(open)
      assert Games.sendable(open.id, 1, 1).game_no == 2
      assert "game.switched" in log_kinds()
      deliver()
      assert held()["moves"] == []
    end
  end

  describe "a box from before the rule" do
    # The owner's evening: game 1 abandoned without a result, "a new game on
    # this board, game 2", moves played on it, and nothing leaving the box.
    defp legacy(open, board, first_result) do
      play_on("FAKE1", board.id, ~w(e4 e5))
      if first_result, do: Boards.set_result(board.id, first_result)
      Boards.new_game(board.id, :extra)
      set_pieces("FAKE1", Position.start())
      eventually(fn -> Boards.snapshot(board.id).game_no == 2 end)
      play_on("FAKE1", board.id, ~w(d4 d5))
      assert [%{local: false}, %{local: true, status: "live"}] = history(open)
    end

    test "is switched over once: the live game starts to flow, the earlier one is kept", ctx do
      %{open: open, board: board} = ctx
      legacy(open, board, nil)
      deliver()
      assert held()["moves"] == ~w(e4 e5)

      assert [%Game{game_no: 2}] = Boards.switch_over()

      assert [%{game_no: 1, local: true}, %{game_no: 2, local: false}] = history(open)
      assert "game.switched" in log_kinds()
      deliver()
      assert held()["moves"] == ~w(d4 d5)
      assert [%{replace: true, plies: 2}] = queued(Games.current(open.id, 1, 1))

      # Once: there is nothing left to do the second time.
      assert Boards.switch_over() == []
    end

    test "leaves a board alone whose earlier game has a result", ctx do
      %{open: open, board: board} = ctx
      legacy(open, board, "1-0")
      assert Boards.switch_over() == []
      assert [%{local: false, result: "1-0"}, %{local: true}] = history(open)
    end

    test "leaves a board alone that no pairing names" do
      own = Tournaments.default()
      plain = fake_dgt("FAKE3", %{tournament_id: own.id, round: 1, board_no: 7})
      eventually(fn -> Boards.snapshot(plain.id).connected? end)
      play_on("FAKE3", plain.id, ~w(e4 e5))
      Boards.new_game(plain.id)
      assert Boards.switch_over() == []
      assert [%{local: false}, %{local: true}] = Games.history(own.id, 1, 7)
    end
  end
end
