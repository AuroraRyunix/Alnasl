defmodule AlnaslWeb.ReviewTest do
  @moduledoc """
  "Check them", and a tap on a marked move: always something to see.

  On the real board the button did nothing at all: the box had one line
  (`4. d4 Ba3 5. dxe5 Bf8`), found no other of the same length, and closed
  the question it had not opened - under a notice that said "more than one
  line of moves". These are the states it can be in, each with what the
  arbiter is shown.
  """

  use AlnaslWeb.SiteCase

  # A game as the box holds it, on a board that reads its last position.
  defp game_on_board(conn, sans, flags) do
    game = Games.ensure(1, 3, %{})

    plies =
      sans
      |> Enum.with_index()
      |> Enum.map(fn {san, index} -> %{san: san, flags: flags.(index), clock: nil} end)

    Games.apply_event(game, {:moves, plies}, System.os_time(:millisecond))

    board = fake_dgt("FAKE1")
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    set_pieces("FAKE1", List.last(boards_after(sans)))

    eventually(fn ->
      Boards.snapshot(board.id).raw == Position.to_text(List.last(boards_after(sans)))
    end)

    {:ok, _} = Boards.link(board, 1, 3)
    eventually(fn -> Boards.snapshot(board.id).status in [:live, :recovered] end)
    {:ok, view, _html} = live(conn, ~p"/round/1/board/3")
    {board, view}
  end

  describe "the game of that morning: 3. d3 e5 4. d4 Ba3 5. dxe5 Bf8, the last four guessed" do
    setup %{conn: conn} do
      {board, view} =
        game_on_board(conn, ~w(e4 Nc6 Nc3 Nf6 d3 e5 d4 Ba3 dxe5 Bf8), fn index ->
          if index >= 6, do: [:guessed, :alone, :long_gap], else: []
        end)

      {:ok, board: board, view: view}
    end

    test "the notice says why it is a guess: one line found, not several", %{view: view} do
      assert has_element?(view, "#guess-notice", "4 moves guessed")
      assert has_element?(view, "#guess-why-alone")
      refute has_element?(view, "#guess-why-several")
    end

    test "\"Check them\" opens the question, the misread pawn first", %{view: view, board: board} do
      view |> element("#review-guess") |> render_click()
      assert has_element?(view, "#choice")
      assert has_element?(view, "#choice-ask", "Move 5")
      # The likeliest answer first: d4, not the d3 the game has.
      assert has_element?(view, "#choice-option-0 .choice-san", "d4")
      refute has_element?(view, "#choice-option-0.standing")
      assert has_element?(view, "#choice-option-1.standing .choice-san", "d3")

      view |> element("#choice-option-0") |> render_click()
      assert has_element?(view, "#choice-answer")
      view |> element("#choice-apply") |> render_click()

      assert sans(board.id) == ~w(e4 Nc6 Nc3 Nf6 d4 e5 dxe5)
      refute has_element?(view, "#choice")
      refute has_element?(view, "#guess-notice")
      refute has_element?(view, ".ply.guess")
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 3).moves == ~w(e4 Nc6 Nc3 Nf6 d4 e5 dxe5)
    end

    test "a tap on any of the red moves opens the same question", %{view: view} do
      view |> element("#ply-8") |> render_click()
      assert has_element?(view, "#choice-ask", "Move 5")
    end
  end

  describe "a guess with no other line to offer" do
    # 2. Nf3 Nc6 marked as a guess (a line found that could not be vouched
    # for): from the position after 1. e4 e5 nothing else leads there.
    setup %{conn: conn} do
      {board, view} =
        game_on_board(conn, ~w(e4 e5 Nf3 Nc6), fn index ->
          if index >= 2, do: [:guessed, :alone], else: []
        end)

      {:ok, board: board, view: view}
    end

    test "\"Check them\" says so, and offers what can be done", %{view: view} do
      assert has_element?(view, "#guess-why-alone")
      view |> element("#review-guess") |> render_click()

      assert has_element?(view, "#choice #choice-none", "No other line")
      refute has_element?(view, "#choice-question")
      refute has_element?(view, "#choice-apply")

      for id <- ~w(choice-keep choice-undo choice-type choice-close) do
        assert has_element?(view, "#choice ##{id}")
      end
    end

    test "keep them: they are the arbiter's, and the mark is gone", %{view: view, board: board} do
      view |> element("#review-guess") |> render_click()
      view |> element("#choice-keep") |> render_click()
      refute has_element?(view, "#choice")
      refute has_element?(view, "#guess-notice")
      assert sans(board.id) == ~w(e4 e5 Nf3 Nc6)
      assert Enum.all?(Enum.drop(Boards.snapshot(board.id).plies, 2), &(&1.flags == [:arbiter]))
    end

    test "take them back", %{view: view, board: board} do
      view |> element("#review-guess") |> render_click()
      assert view |> element("#choice-undo") |> render_click() =~ "taken back"
      assert sans(board.id) == ~w(e4 e5)
      refute has_element?(view, "#choice")
    end

    test "type the right moves: the tool for it, with the move number filled in", %{view: view} do
      view |> element("#review-guess") |> render_click()
      view |> element("#choice-type") |> render_click()
      refute has_element?(view, "#choice")
      assert has_element?(view, "#edit-tool[phx-hook]")
      assert has_element?(view, "#edit-ply[value='3']")
      assert_push_event(view, "alnasl:go", %{to: "edit-move-form"})
    end

    test "a tap on the red move does the same as the button", %{view: view} do
      view |> element("#ply-4") |> render_click()
      assert has_element?(view, "#choice-none")
    end

    test "an answer to a question that is gone is said to be that", %{view: view, board: board} do
      view |> element("#review-guess") |> render_click()
      # Another browser settles it meanwhile.
      {:ok, 0} = Boards.choose(board.id, 3, ~w(Nf3 Nc6))
      html = view |> element("#choice-keep") |> render_click()
      # Kept is what it already was: no error, and the panel is gone.
      refute has_element?(view, "#choice")
      assert html =~ "Settled" or html =~ "no longer fit"
    end

    test "with the board unplugged, the tap says why nothing can be gone over", %{
      view: view,
      board: board
    } do
      Boards.stop(board)
      eventually_html(view, fn _ -> has_element?(view, "#review-guess") end)
      html = view |> element("#review-guess") |> render_click()
      assert html =~ "not connected" or html =~ "No board is linked"
      refute has_element?(view, "#choice")
    end
  end

  describe "a move rewritten while the game is played" do
    setup %{conn: conn} do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 3})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      # 3. d4 is read as d3; then 3...e5 4. dxe5.
      read = play_on("FAKE1", board.id, ~w(e4 Nc6 Nc3 Nf6 d3 e5))
      b = List.last(boards_after(read))

      set_pieces(
        "FAKE1",
        b
        |> put_elem(Position.square_index("d3"), nil)
        |> put_elem(Position.square_index("e5"), {:w, :p})
      )

      eventually(fn -> sans(board.id) == ~w(e4 Nc6 Nc3 Nf6 d4 e5 dxe5) end)
      {:ok, view, _html} = live(conn, ~p"/round/1/board/3")
      {:ok, board: board, view: view}
    end

    test "is marked in the list with what it was read as, and said in a sentence above", %{
      view: view
    } do
      assert has_element?(view, "#ply-5 #ply-read-5", "read as d3")
      assert has_element?(view, "#rewritten-notice-5", "3. d3 was read")
      assert has_element?(view, "#rewritten-notice-5", "3. d4")
      assert has_element?(view, "#review-rewritten-5")
      assert has_element?(view, "#game-state[data-state=recovered]")
      assert "move.rewritten" in log_kinds()
    end

    test "went to the results server as the game it now is", %{board: board} do
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 3).moves == sans(board.id)
    end

    test "\"Check it\": the move as it was read is there to go back to", %{
      view: view,
      board: board
    } do
      view |> element("#review-rewritten-5") |> render_click()
      assert has_element?(view, "#choice #choice-read", "3. d3 was read")
      assert has_element?(view, "#choice-option-0.standing .choice-san", "d4")
      assert has_element?(view, "#choice-option-1 .choice-san", "d3")

      # Kept: the arbiter's now, no mark, nothing more to check.
      view |> element("#choice-keep") |> render_click()
      assert sans(board.id) == ~w(e4 Nc6 Nc3 Nf6 d4 e5 dxe5)
      refute has_element?(view, "#rewritten-notice-5")
      refute has_element?(view, "#ply-read-5")
    end
  end
end
