defmodule AlnaslWeb.NewGameTest do
  @moduledoc """
  Ending a game on a board and beginning the next: "Finish game" where it
  can be found, "New game on this board", the pieces set up again, and the
  games a board has seen in a round.

  The tournament of these tests pairs boards 1-4 of round 1; board 7 is a
  board nobody is paired on - friends playing game after game.
  """

  use AlnaslWeb.SiteCase

  defp board_on(number) do
    board = fake_dgt("FAKE1", %{round: 1, board_no: number})
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    board
  end

  defp set_up_again(board, game_no) do
    set_pieces("FAKE1", Position.start())
    eventually(fn -> Boards.snapshot(board.id).game_no == game_no end)
  end

  describe "the pieces set up again" do
    test "after a finished game on a board no pairing names: the next game, by itself" do
      board = board_on(7)
      play_on("FAKE1", board.id, ~w(f3 e5 g4 Qh4#))
      assert :ok = Boards.set_result(board.id, "0-1")
      first = Games.get(1, 7)
      assert first.game_no == 1 and first.status == "finished"

      set_up_again(board, 2)
      snapshot = Boards.snapshot(board.id)
      assert snapshot.status == :waiting_start and snapshot.plies == []
      assert snapshot.game_id != first.id

      play_on("FAKE1", board.id, ~w(e4 e5 Nf3))
      second = Games.get(1, 7)
      assert second.game_no == 2 and Games.sans(second) == ~w(e4 e5 Nf3)

      # The first game is as it was, and both are there to be had.
      assert [%{game_no: 1, result: "0-1"} = kept, %{game_no: 2, status: "live"}] =
               Games.history(1, 7)

      assert Games.sans(kept) == ~w(f3 e5 g4 Qh4#)
      assert File.read!(Games.pgn_path(kept)) =~ "Qh4# 0-1"
      assert Games.pgn_path(second) =~ "board-7-game-2.pgn"
      assert File.read!(Games.pgn_path(second)) =~ "1. e4 e5 2. Nf3"
      assert "game.new" in log_kinds()
    end

    test "the second game stays on the box: the server knows one game a board" do
      board = board_on(7)
      play_on("FAKE1", board.id, ~w(f3 e5 g4 Qh4#))
      Boards.set_result(board.id, "0-1")
      set_up_again(board, 2)
      play_on("FAKE1", board.id, ~w(d4 d5))

      assert Outbox.drain() == :empty

      assert %{moves: ~w(f3 e5 g4 Qh4#), status: "finished", result: "0-1"} =
               FakeIngest.game(1, 7)

      assert Games.get(1, 7).seq == 0
      # Every game of the round is in the round's PGN all the same.
      assert Games.round_pgn(1) =~ "Qh4#"
      assert Games.round_pgn(1) =~ "1. d4 d5"
    end

    test "the recording says where one game ends and the next begins" do
      board = board_on(7)
      play_on("FAKE1", board.id, ~w(e4 e5 Nf3 Nc6))
      Boards.set_result(board.id, "1/2-1/2")
      set_up_again(board, 2)
      Recorder.flush()

      lines =
        for file <- Recorder.list(),
            file.board_id == board.id,
            line <- file.path |> File.read!() |> String.split("\n", trim: true),
            decoded = Jason.decode!(line),
            decoded["k"] == "cfg",
            do: decoded["game"]

      assert 1 in lines and List.last(lines) == 2
    end

    test "an unfinished game well under way is closed without a result" do
      board = board_on(7)
      play_on("FAKE1", board.id, ~w(e4 e5 Nf3 Nc6))
      set_up_again(board, 2)
      assert [%{status: "finished", result: "*"}, %{status: "live"}] = Games.history(1, 7)
    end

    test "two moves in, the starting position is a takeback, not a new game" do
      board = board_on(7)
      play_on("FAKE1", board.id, ~w(e4 e5))
      set_pieces("FAKE1", Position.start())
      eventually(fn -> sans(board.id) == [] end)
      assert Boards.snapshot(board.id).game_no == 1
      assert length(Games.history(1, 7)) == 1
    end

    test "on a paired board it is left to the arbiter - unless Setup says always" do
      board = board_on(3)
      play_on("FAKE1", board.id, ~w(f3 e5 g4 Qh4#))
      Boards.set_result(board.id, "0-1")
      set_pieces("FAKE1", Position.start())
      eventually(fn -> Boards.snapshot(board.id).raw == Position.to_text(Position.start()) end)
      assert Boards.snapshot(board.id).status == :finished
      assert length(Games.history(1, 3)) == 1

      Settings.put("new_game_on_setup", "always")
      set_pieces("FAKE1", List.last(boards_after(~w(e4))))
      set_up_again(board, 2)
    end

    test "and never when Setup says never" do
      Settings.put("new_game_on_setup", "never")
      board = board_on(7)
      play_on("FAKE1", board.id, ~w(f3 e5 g4 Qh4#))
      Boards.set_result(board.id, "0-1")
      set_pieces("FAKE1", Position.start())
      eventually(fn -> Boards.snapshot(board.id).raw == Position.to_text(Position.start()) end)
      assert length(Games.history(1, 7)) == 1

      # "New game on this board" still does it.
      assert :ok = Boards.new_game(board.id)
      assert Boards.snapshot(board.id).game_no == 2
      assert Boards.snapshot(board.id).status == :waiting_start
    end
  end

  describe "a board's page" do
    setup %{conn: conn} do
      board = board_on(3)
      play_on("FAKE1", board.id, ~w(e4 e5))
      {:ok, view, _html} = live(conn, ~p"/round/1/board/3")
      {:ok, board: board, view: view}
    end

    test "\"Finish game\" is its own panel, not a repair tool: three results and none", %{
      view: view
    } do
      for id <- ~w(result-1-0 result-12-12 result-0-1 result-none) do
        assert has_element?(view, "#finish ##{id}")
        refute has_element?(view, "#tools ##{id}")
      end

      assert has_element?(view, "#finish #new-game")
      refute has_element?(view, "#games-here")

      view |> element("#result-none") |> render_click()
      assert has_element?(view, "#game-state[data-state=finished]")
      assert has_element?(view, "#finish-done", "without a result")
      assert %{status: "finished", result: "*"} = Games.get(1, 3)
      # The result can still be changed, and the game reopened.
      assert has_element?(view, "#finish #result-1-0")
      refute has_element?(view, "#result-none")
      assert has_element?(view, "#finish #tool-reopen")
    end

    test "\"New game on this board\" after a result: a fresh game, the old one listed with its PGN",
         %{view: view, conn: conn, board: board} do
      view |> element("#result-1-0") |> render_click()
      html = view |> element("#new-game") |> render_click()
      assert html =~ "A new game on this board"

      assert Boards.snapshot(board.id).game_no == 2
      refute has_element?(view, "#ply-1")
      assert has_element?(view, "#game-no", "game 2")
      assert has_element?(view, "#games-here #game-here-1", "1-0")
      assert has_element?(view, "#games-here #game-here-2")
      assert has_element?(view, "#game-here-pgn-1[href$='?game=1']")
      assert has_element?(view, "#result-1-0")

      # The pieces are still as the first game left them: not the start.
      # They are not read into the new game as its first moves.
      eventually_html(view, fn _ ->
        has_element?(view, "#game-state[data-state=waiting_start]")
      end)

      assert sans(board.id) == []

      first = conn |> get(~p"/files/round/1/board/3?game=1") |> response(200)
      assert first =~ "1. e4 e5 1-0"
      second = conn |> get(~p"/files/round/1/board/3?game=2") |> response(200)
      refute second =~ "e4"
      assert conn |> get(~p"/files/round/1/board/3?game=9") |> response(404)
      # Without a number: the game being played.
      assert conn |> get(~p"/files/round/1/board/3") |> response(200) == second
    end

    test "\"New game\" over an unfinished game closes it without a result and replaces it", %{
      view: view,
      board: board
    } do
      assert has_element?(view, "#new-game[data-confirm]")
      view |> element("#new-game") |> render_click()
      assert Boards.snapshot(board.id).game_no == 2

      # Board 3 is paired and the game had no result: the new game is the
      # board's game of the round, the abandoned one stays at home.
      assert [
               %{result: "*", status: "finished", local: true},
               %{status: "live", local: false}
             ] = Games.history(1, 3)

      assert Outbox.drain() == :empty
      assert %{status: "live", moves: []} = FakeIngest.game(1, 3)
    end
  end

  describe "the Round page" do
    test "a tile's menu: finish the game, begin the next", %{conn: conn} do
      board = board_on(3)
      play_on("FAKE1", board.id, ~w(e4 e5))
      {:ok, view, _html} = live(conn, ~p"/round/1")
      assert has_element?(view, "#tile-wrap-3 #tile-3")
      assert has_element?(view, "#tile-menu-3 summary", "Finish game")

      view |> element("#tile-result-3-12-12") |> render_click()
      assert %{status: "finished", result: "1/2-1/2"} = Games.get(1, 3)
      eventually_html(view, fn _ -> has_element?(view, "#tile-3 [data-state=finished]") end)
      assert has_element?(view, "#tile-menu-3 summary", "Next game")
      refute has_element?(view, "#tile-result-3-1-0")

      view |> element("#tile-new-game-3") |> render_click()
      assert Boards.snapshot(board.id).game_no == 2
      eventually_html(view, fn _ -> has_element?(view, "#tile-menu-3 summary", "Finish game") end)
    end

    test "a board nobody feeds has no next game to begin", %{conn: conn} do
      {[game], []} = Alnasl.Pgn.load("1. f3 e5 2. g4 Qh4# 0-1")
      {:ok, _} = Boards.attach_pgn(1, 4, game)
      {:ok, view, _html} = live(conn, ~p"/round/1")
      assert view |> element("#tile-new-game-4") |> render_click() =~ "No connected board"
    end
  end

  test "starting a round is one call, for whoever asks: pairings fetched, boards moved" do
    board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
    assert :ok = Boards.start_round(2)
    assert Boards.get!(board.id).round == 2
    assert own().round == 2
  end

  test "Setup has the choice, 'where no pairing names the board' by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup/this-box")
    assert has_element?(view, "#box-new-game option[value=unpaired][selected]")

    view |> form("#box-form", box: %{new_game_on_setup: "always"}) |> render_submit()
    assert Settings.get("new_game_on_setup") == "always"
  end
end
