defmodule AlnaslWeb.RoundAndGameTest do
  @moduledoc "The Round page and a board's own page: what the arbiter looks at, and the repair tools."

  use AlnaslWeb.SiteCase

  describe "Round" do
    test "before anything is set up it says where to go", %{conn: conn} do
      own_put(server_url: "", slug: "", relay_key: "", document: nil)
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#round-empty")
      assert has_element?(view, "#empty-setup")
      refute has_element?(view, "#tiles")
    end

    test "shows a tile per board that has a game, with the players from the results server", %{
      conn: conn
    } do
      for n <- 1..4, do: Games.ensure(Alnasl.Tournaments.default_id(), 1, n, %{})
      {:ok, view, _html} = live(conn, ~p"/")
      for n <- 1..4, do: assert(has_element?(view, "#tile-#{n}"))
      assert has_element?(view, "#tile-1 .name", "GM Player 1")
      assert has_element?(view, "#tile-1 [data-state=unlinked]")
      assert has_element?(view, "#link-state")
    end

    test "a board that plays turns its tile live, with the move and the position", %{conn: conn} do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 2})
      {:ok, view, _html} = live(conn, ~p"/round/1")
      eventually_html(view, fn _ -> has_element?(view, "#tile-2 [data-state=waiting_start]") end)

      play_on("FAKE1", board.id, ~w(e4 e5 Nf3))
      eventually_html(view, fn _ -> has_element?(view, "#tile-2 [data-state=live]") end)
      assert has_element?(view, "#tile-2 .last", "f3")
      assert has_element?(view, "#tile-2 svg.board use")
      assert has_element?(view, "#round-summary")
    end

    test "a board that is out of sync stands out and is counted", %{conn: conn} do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
      {:ok, view, _html} = live(conn, ~p"/")
      play_on("FAKE1", board.id, ~w(e4 e5))
      now = List.last(boards_after(~w(e4 e5)))
      set_pieces("FAKE1", now |> put_elem(40, {:w, :r}) |> put_elem(56, nil))

      eventually_html(view, fn _ -> has_element?(view, "#tile-1.bad [data-state=out_of_sync]") end)

      assert has_element?(view, "#nav-round .count", "1")
    end

    test "a clock set the wrong way is said on the tile in words; started that way it is an alarm, counted",
         %{conn: conn} do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 2})
      {:ok, view, _html} = live(conn, ~p"/round/1")
      eventually_html(view, fn _ -> has_element?(view, "#tile-2 [data-state=waiting_start]") end)
      refute has_element?(view, "#tile-clock-2")

      set_clock("FAKE1", {:still, :black})

      eventually_html(view, fn _ ->
        has_element?(
          view,
          "#tile-clock-2",
          "Clock not in starting position: Black's side would run first - the clock is turned or the lever is the wrong way"
        )
      end)

      assert has_element?(view, "#tile-2 [data-state=waiting_start]")

      set_clock("FAKE1", :black)

      eventually_html(view, fn _ -> has_element?(view, "#tile-2.bad [data-state=clock_alarm]") end)

      assert has_element?(view, "#nav-round .count", "1")
      assert has_element?(view, "#round-summary [data-state=clock_alarm]")

      # The board's own page says what it is, and that it is not the pieces.
      {:ok, page, _html} = live(conn, ~p"/round/1/board/2")
      assert has_element?(page, "#game-state[data-state=clock_alarm]")
      assert has_element?(page, "#state-help[role=alert]", "Black's clock is running")
      assert has_element?(page, "#clock-check", "Black's side would run first")
      refute has_element?(page, "#start-check")

      set_clock("FAKE1", :white)
      eventually_html(view, fn _ -> has_element?(view, "#tile-2 [data-state=waiting_start]") end)
      refute has_element?(view, "#tile-clock-2")
      refute has_element?(view, "#nav-round .count")
      eventually_html(page, fn _ -> not has_element?(page, "#clock-check") end)
      assert Boards.snapshot(board.id).clock_check == :ok

      # And the log has both lines, as sentences.
      {:ok, log, _html} = live(conn, ~p"/log")
      html = render(log)
      assert html =~ "Clock alarm: Black&#39;s clock is running from the starting position"
      assert html =~ "The clock is the right way again."
    end

    test "the next round takes the boards along; nothing is fetched from the results server",
         %{conn: conn} do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
      {:ok, view, _html} = live(conn, ~p"/")

      # The box's own tournament has no pairing program to ask.
      refute has_element?(view, "#refresh-pairings")
      assert Enum.all?(FakeIngest.requests(), fn {_status, body} -> is_map_key(body, "moves") end)

      view |> element("#next-round") |> render_click()
      assert_patch(view, ~p"/round/2")
      assert Boards.get!(board.id).round == 2
      assert own().round == 2
      assert has_element?(view, "#round-2[aria-current=true]")
    end
  end

  describe "a board's page" do
    setup %{conn: conn} do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 3})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      play_on("FAKE1", board.id, ~w(e4 e5))
      {:ok, view, _html} = live(conn, ~p"/round/1/board/3")
      {:ok, board: board, view: view}
    end

    test "shows the game: state, players, the move list in figurines", %{view: view} do
      assert has_element?(view, "#game-state[data-state=live]")
      assert has_element?(view, "#ply-1", "e4")
      assert has_element?(view, "#ply-2", "e5")
      assert has_element?(view, "#board-certain use")
      assert has_element?(view, "#position .name", "Player 5")
      refute has_element?(view, "#twin")
    end

    test "out of sync: both boards side by side, and the way back", %{view: view, board: board} do
      now = List.last(boards_after(~w(e4 e5)))
      set_pieces("FAKE1", now |> put_elem(40, {:w, :r}) |> put_elem(56, nil))
      eventually_html(view, fn _ -> has_element?(view, "#game-state[data-state=out_of_sync]") end)
      assert has_element?(view, "#twin #board-raw .diff")
      assert has_element?(view, "#twin #board-certain")
      assert has_element?(view, "#state-help[role=alert]")

      assert view |> element("#tool-resync") |> render_click() =~ "No sequence"

      # Six moves on, the search finds more than one order: the arbiter picks.
      line = ~w(Nf3 Nc6 Bb5 a6 Ba4 Nf6)
      set_pieces("FAKE1", List.last(boards_after(~w(e4 e5) ++ line)))

      eventually(fn ->
        Boards.snapshot(board.id).raw ==
          Position.to_text(List.last(boards_after(~w(e4 e5) ++ line)))
      end)

      # More than one order of them is legal: one is taken, the page says
      # so, and every move of it is marked.
      assert view |> element("#tool-resync") |> render_click() =~ "marked as a guess"
      assert length(sans(board.id)) == 8
      assert has_element?(view, "#ply-8.guess .flag.guess")
      assert has_element?(view, "#guess-notice", "6 moves guessed")
      eventually_html(view, fn _ -> not has_element?(view, "#twin") end)
    end

    test "typed moves are added, or refused by name", %{view: view, board: board} do
      set_pieces("FAKE1", List.last(boards_after(~w(e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6))))

      eventually(fn ->
        Boards.snapshot(board.id).raw ==
          Position.to_text(List.last(boards_after(~w(e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6))))
      end)

      html = view |> form("#type-moves-form", typed: %{moves: "Nf3 Ke5"}) |> render_submit()
      assert html =~ "Ke5" and html =~ "not a legal move"
      assert sans(board.id) == ~w(e4 e5)

      view
      |> form("#type-moves-form", typed: %{moves: "3. Nf3 Nc6 4. Bb5 a6, Ba4 Nf6"})
      |> render_submit()

      assert sans(board.id) == ~w(e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6)
      assert has_element?(view, "#ply-3 .flag")
    end

    test "a move is changed, and a wrong change is refused", %{view: view, board: board} do
      assert view |> form("#edit-move-form", edit: %{ply: "2", san: "Qh4"}) |> render_submit() =~
               "not a legal move"

      assert view |> form("#edit-move-form", edit: %{ply: "x", san: "c5"}) |> render_submit() =~
               "number of the move"

      view |> form("#edit-move-form", edit: %{ply: "2", san: "c5"}) |> render_submit()
      assert sans(board.id) == ~w(e4 c5)
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 3).moves == ~w(e4 c5)
    end

    test "the result is the arbiter's: set, shown, reopened", %{view: view} do
      view |> element("#result-1-0") |> render_click()
      assert has_element?(view, "#game-state[data-state=finished]")
      assert has_element?(view, "#game-result", "1-0")
      assert Outbox.drain() == :empty
      assert %{status: "finished", result: "1-0"} = FakeIngest.game(1, 3)

      view |> element("#tool-reopen") |> render_click()
      refute has_element?(view, "#game-state[data-state=finished]")
    end

    test "a suggested result waits to be confirmed", %{view: view, board: board} do
      Boards.undo(board.id)
      Boards.undo(board.id)
      set_pieces("FAKE1", Position.start())
      eventually(fn -> sans(board.id) == [] end)
      play_on("FAKE1", board.id, ~w(f3 e5 g4 Qh4#))

      eventually_html(view, fn _ -> has_element?(view, "#suggestion") end)
      assert Games.get(1, 3).status == "live"
      view |> element("#confirm-suggestion") |> render_click()
      assert %{status: "finished", result: "0-1"} = Games.get(1, 3)
    end

    test "sending is paused and resumed, the board turned, a position set", %{
      view: view,
      board: board
    } do
      view |> element("#tool-pause") |> render_click()
      assert has_element?(view, "#game-paused")
      assert Games.get(1, 3).paused
      view |> element("#tool-resume") |> render_click()
      refute has_element?(view, "#game-paused")

      view |> element("#tool-flip") |> render_click()
      assert Boards.get!(board.id).flipped
      view |> element("#tool-flip") |> render_click()

      assert view |> form("#set-fen-form", position: %{fen: "rubbish"}) |> render_submit() =~
               "not a position"

      view |> element("#tool-fen-from-board") |> render_click()
      # The pieces after 1. e4 e5: kings and rooks at home, so every right.
      assert has_element?(view, "#fen-input[value*=' w KQkq - 0 1']")

      view
      |> form("#set-fen-form", position: %{fen: "4k3/8/8/8/8/8/4P3/4K3 w - - 0 40"})
      |> render_submit()

      assert sans(board.id) == []
      assert Games.get(1, 3).start_fen == "4k3/8/8/8/8/8/4P3/4K3 w - - 0 40"
    end

    test "undo takes the last move back, and the board is not re-read until it changes", %{
      view: view,
      board: board
    } do
      view |> element("#tool-undo") |> render_click()
      assert sans(board.id) == ~w(e4)
      refute has_element?(view, "#ply-2")
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 3).moves == ~w(e4)

      # The next change on the board is read against the game as it now is.
      play_on("FAKE1", board.id, ~w(Nf3), ~w(e4 e5))
      assert sans(board.id) == ~w(e4 e5 Nf3)
    end
  end

  test "a board nobody feeds: the page says so, and a game from a PGN can still get its result",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/round/1/board/4")
    assert has_element?(view, "#game-empty")

    {[game], []} = Alnasl.Pgn.load("1. f3 e5 2. g4 Qh4# 0-1")
    {:ok, _} = Boards.attach_pgn(1, 4, game)
    {:ok, view, _html} = live(conn, ~p"/round/1/board/4")
    assert has_element?(view, "#game-state[data-state=finished]")
    assert has_element?(view, "#ply-4 .flag")
    assert view |> element("#tool-resync") |> render_click() =~ "No board is linked"
    view |> element("#result-12-12") |> render_click()
    assert Games.get(1, 4).result == "1/2-1/2"

    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/round/x/board/y")
  end
end
