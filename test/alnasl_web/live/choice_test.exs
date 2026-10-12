defmodule AlnaslWeb.ChoiceTest do
  @moduledoc """
  Moves the box worked out: the marks on them, the counts, and the question
  that settles a guess - one move at a time, each option on a board.
  """

  use AlnaslWeb.SiteCase

  alias AlnaslWeb.Choice

  describe "the question, on its own" do
    # Four moves after 1. e4 e5, White's two in either order and Black's two
    # in either order: four lines.
    @alt %{
      from: 3,
      to: 6,
      fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
      current: ~w(Bc4 Nc6 Nf3 Nf6),
      options: [
        ~w(Bc4 Nc6 Nf3 Nf6),
        ~w(Bc4 Nf6 Nf3 Nc6),
        ~w(Nf3 Nc6 Bc4 Nf6),
        ~w(Nf3 Nf6 Bc4 Nc6)
      ]
    }

    test "asks about the first move the lines differ on, the game as it stands first" do
      ask = Choice.ask(@alt, [])
      assert ask.settled == [] and ask.left == 4 and ask.line == nil
      assert ask.number == 3 and ask.white?

      assert [%{san: "Bc4", left: 2, standing?: true}, %{san: "Nf3", left: 2, standing?: false}] =
               ask.options

      # Each option is a board with the move's two squares.
      [bc4, _] = ask.options
      assert String.length(bc4.position) == 64

      assert bc4.squares ==
               {Alnasl.Position.square_index("f1"), Alnasl.Position.square_index("c4")}
    end

    test "an answer halves the lines; moves every remaining line has are not asked about" do
      ask = Choice.ask(@alt, ["Nf3"])
      assert ask.settled == ["Nf3"] and ask.left == 2
      assert ask.number == 4 and not ask.white?
      assert Enum.map(ask.options, & &1.san) == ~w(Nc6 Nf6)
      # The game as it stands went another way at the first question.
      refute Enum.any?(ask.options, & &1.standing?)

      # After Black's move nothing is left to ask: White's second move and
      # Black's second follow.
      done = Choice.ask(@alt, ["Nf3", "Nc6"])
      assert done.line == ~w(Nf3 Nc6 Bc4 Nf6) and done.left == 1 and done.options == []
      assert done.changed == [true, false, true, false]
    end

    test "an answer that fits no line is not an answer" do
      assert Choice.ask(@alt, ["Qh5"]) == Choice.ask(@alt, [])
    end

    test "lines that begin alike begin without a question" do
      alt = %{@alt | options: [~w(Bc4 Nc6 Nf3 Nf6), ~w(Bc4 Nf6 Nf3 Nc6)]}
      ask = Choice.ask(alt, [])
      assert ask.settled == ["Bc4"] and ask.number == 4
    end
  end

  describe "on a board's page" do
    setup %{conn: conn} do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 3})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      play_on("FAKE1", board.id, ~w(e4 e5))

      # Four moves go by with nothing read of them; the board stands, and
      # the box takes one of the four lines.
      set_pieces("FAKE1", List.last(boards_after(~w(e4 e5 Nf3 Nc6 Bc4 Nf6))))
      eventually(fn -> length(sans(board.id)) == 6 end)
      {:ok, view, _html} = live(conn, ~p"/round/1/board/3")
      {:ok, board: board, view: view}
    end

    test "guessed moves carry a shape and a word, and the page says how many", %{
      view: view,
      board: board
    } do
      assert Enum.sort(Enum.drop(sans(board.id), 2)) == Enum.sort(~w(Nf3 Nc6 Bc4 Nf6))
      for n <- 3..6, do: assert(has_element?(view, "#ply-#{n}.guess .flag.guess", "guessed"))
      refute has_element?(view, "#ply-2 .flag")
      assert has_element?(view, "#guess-notice", "4 moves guessed")
      assert has_element?(view, "#review-guess")
      assert has_element?(view, "#game-state[data-state=recovered]")
      refute has_element?(view, "#choice")
      assert "move.guessed" in log_kinds()
    end

    test "the Round tile and the Boards list count them", %{conn: conn, board: board} do
      {:ok, round, _html} = live(conn, ~p"/round/1")
      assert has_element?(round, "#tile-3 #tile-guessed-3", "4 moves guessed")
      refute has_element?(round, "#tile-reconstructed-3")

      {:ok, boards, _html} = live(conn, ~p"/boards")
      assert has_element?(boards, "#guessed-#{board.id}", "4 moves guessed")
    end

    test "they went to the results server like any other moves, without a mark", %{board: board} do
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 3).moves == sans(board.id)
    end

    test "\"Check them\": one question at a time, each option on a board; the answers rewrite the game",
         %{view: view, board: board} do
      view |> element("#review-guess") |> render_click()
      assert has_element?(view, "#choice #choice-before")
      assert has_element?(view, "#choice #choice-after")
      assert has_element?(view, "#choice-ask", "Move 3")
      assert has_element?(view, "#choice-option-0 svg.board")
      assert has_element?(view, "#choice-option-0.standing")
      assert has_element?(view, "#choice-option-1")
      refute has_element?(view, "#choice-option-2")
      refute has_element?(view, "#choice-apply")

      standing = Enum.at(sans(board.id), 2)
      other = hd(~w(Nf3 Bc4) -- [standing])
      view |> element("#choice-option-1") |> render_click()
      assert has_element?(view, "#choice-settled", String.slice(other, -2, 2))
      assert has_element?(view, "#choice-ask", "Move 4")
      assert has_element?(view, "#choice-back")

      # One question back, and forward again.
      view |> element("#choice-back") |> render_click()
      assert has_element?(view, "#choice-ask", "Move 3")
      view |> element("#choice-option-1") |> render_click()

      view |> element("#choice-option-0") |> render_click()
      assert has_element?(view, "#choice-answer .choice-san.changed")
      html = view |> element("#choice-apply") |> render_click()
      assert html =~ "Settled"

      refute has_element?(view, "#choice")
      line = Enum.drop(sans(board.id), 2)
      assert hd(line) == other
      # The arbiter's word now: no red, nothing left to check.
      refute has_element?(view, ".ply.guess")
      refute has_element?(view, "#guess-notice")
      assert Enum.all?(Enum.drop(Boards.snapshot(board.id).plies, 2), &(&1.flags == [:arbiter]))

      # Sent again, in full.
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 3).moves == sans(board.id)
      assert "repair.choose" in log_kinds()
    end

    test "\"Keep it as it stands\" is one tap, and the moves are no longer a guess", %{
      view: view,
      board: board
    } do
      before = sans(board.id)
      view |> element("#review-guess") |> render_click()
      view |> element("#choice-keep") |> render_click()
      refute has_element?(view, "#choice")
      assert sans(board.id) == before
      refute has_element?(view, ".ply.guess")
    end

    test "a tap on a red move asks about it; \"Not now\" leaves it red", %{view: view} do
      view |> element("#ply-4") |> render_click()
      assert has_element?(view, "#choice")
      view |> element("#choice-close") |> render_click()
      refute has_element?(view, "#choice")
      assert has_element?(view, "#ply-4.guess")
      assert has_element?(view, "#guess-notice")
    end

    test "after an Undo, \"the board is right\" does not put the same moves back", %{
      view: view,
      board: board
    } do
      before = sans(board.id)
      view |> element("#tool-undo") |> render_click()
      view |> element("#tool-undo") |> render_click()
      assert length(sans(board.id)) == 4

      html = view |> element("#tool-resync") |> render_click()
      assert html =~ "moves you took back"
      assert sans(board.id) == Enum.take(before, 4)
    end
  end

  test "moves reconstructed with one line only are orange: a diamond and the word", %{conn: conn} do
    board = fake_dgt("FAKE1", %{round: 1, board_no: 2})
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    play_on("FAKE1", board.id, ~w(e4 e5))
    set_pieces("FAKE1", List.last(boards_after(~w(e4 e5 Nf3 Nc6))))
    eventually(fn -> sans(board.id) == ~w(e4 e5 Nf3 Nc6) end)

    {:ok, view, _html} = live(conn, ~p"/round/1/board/2")
    assert has_element?(view, "#ply-3.rec .flag.rec", "reconstructed")
    assert has_element?(view, "#reconstructed-notice", "2 moves reconstructed")
    refute has_element?(view, "#guess-notice")

    {:ok, round, _html} = live(conn, ~p"/round/1")
    assert has_element?(round, "#tile-reconstructed-2", "2 moves reconstructed")
  end
end
