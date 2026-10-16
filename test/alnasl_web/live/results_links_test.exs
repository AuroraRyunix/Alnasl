defmodule AlnaslWeb.ResultsLinksTest do
  @moduledoc """
  Links to the results site where the arbiter looks (the Round page, a
  board's page, Setup, the Outbox, the bar), the QR code of the live page,
  and a game that stays on the box saying so.

  The tournament of these tests is on `http://results.test` as `test-open`
  and pairs boards 1-4 of round 1; board 7 is a board nobody is paired on.
  """

  use AlnaslWeb.SiteCase

  import Alnasl.LinkHelpers

  alias Alnasl.Tournaments

  @site "http://results.test/t/test-open"

  defp board_on(number, port \\ "FAKE1") do
    board = fake_dgt(port, %{round: 1, board_no: number})
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    board
  end

  # A board that plays in the box's own tournament although another is linked.
  defp own_board do
    board = board_on(1)
    Boards.update(board, %{tournament_id: Tournaments.default_id(), round: 1, board_no: 1})
    board
  end

  # Opens in another tab and does not hand the arbiter's page to the other site.
  defp new_tab?(view, id, href) do
    has_element?(view, "##{id}[href='#{href}'][target=_blank][rel~=noopener]")
  end

  describe "the Round page" do
    test "opens the live boards of the round on the results site, in a new tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert new_tab?(view, "site-open", @site <> "/live/1")
      assert has_element?(view, "#site-open", "Open the results site")
      refute has_element?(view, "#site-none")
    end

    test "follows the round that is shown", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/round/2")
      assert new_tab?(view, "site-open", @site <> "/live/2")
    end

    test "each tile has a link to its board's live page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      for n <- 1..4, do: assert(new_tab?(view, "tile-site-link-#{n}", @site <> "/live/1/#{n}"))
      # A link beside the tile, not inside the tile's own link.
      refute has_element?(view, "#tile-1 a")
    end

    test "a QR code of the live page, behind a small 'QR' toggle", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "details#site-qr:not([open]) summary", "QR")
      assert has_element?(view, "#site-qr-code svg[role=img]")
      assert has_element?(view, "#site-qr-code svg[aria-label*='test-open/live']")
      assert has_element?(view, "#site-qr-url", @site <> "/live")
      assert has_element?(view, "#site-qr-code rect[fill='#000000']")
    end

    test "without a results page: no link, and the reason", %{conn: conn} do
      own_put(server_url: "")
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#site-open")
      refute has_element?(view, "#site-qr")
      refute has_element?(view, "[id^=tile-site-link-]")
      assert has_element?(view, "#site-none", "No results site")

      own_put(server_url: "http://results.test", slug: "")
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#site-open")
      assert has_element?(view, "#site-none", "short name")
    end

    test "several tournaments: each links to its own site and tournament", %{conn: conn} do
      pairing_program()
      open = linked(17, name: "Open", boards: 2)
      own_board()
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#round-section")
      assert has_element?(view, "#round-section-t#{open.id}")
      assert new_tab?(view, "site-open", @site <> "/live/1")
      assert new_tab?(view, "site-open-t#{open.id}", "http://results.test/t/slug-17/live/1")
      assert has_element?(view, "#site-qr-url-t#{open.id}", "http://results.test/t/slug-17/live")

      assert new_tab?(
               view,
               "tile-site-link-t#{open.id}-1",
               "http://results.test/t/slug-17/live/1/1"
             )
    end

    test "a slug that needs escaping is escaped", %{conn: conn} do
      own_put(slug: "open 2026")
      {:ok, view, _html} = live(conn, ~p"/")
      assert new_tab?(view, "site-open", "http://results.test/t/open%202026/live/1")
    end
  end

  describe "a game that stays on the box" do
    setup %{conn: conn} do
      board = board_on(3)
      play_on("FAKE1", board.id, ~w(f3 e5 g4 Qh4#))
      Boards.set_result(board.id, "0-1")
      {:ok, conn: conn, board: board}
    end

    test "after a result, 'New game' is an extra one, said so; the other choice is there", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/round/1")
      eventually_html(view, fn _ -> has_element?(view, "#tile-3 [data-state=finished]") end)
      assert has_element?(view, "#tile-new-game-3[phx-value-kind=extra]", "stays on this box")
      assert has_element?(view, "#tile-new-game-replace-3", "replaces the game of the pairing")
      refute has_element?(view, "#tile-local-3")

      view |> element("#tile-new-game-3") |> render_click()
      assert Boards.snapshot(board.id).game_no == 2

      # Never silent: the tile says it, with one tap to change it.
      eventually_html(view, fn _ -> has_element?(view, "#tile-local-flag-3") end)
      assert has_element?(view, "#tile-local-3", "game 2 on this board")
      assert has_element?(view, "#tile-send-this-3[data-confirm]", "Send this one instead")

      view |> element("#tile-send-this-3") |> render_click()
      refute has_element?(view, "#tile-local-3")
      refute has_element?(view, "#tile-local-flag-3")
      assert [%{local: true, game_no: 1}, %{local: false, game_no: 2}] = Games.history(1, 3)
    end

    test "the board's page says it too, and sends this one instead", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/round/1/board/3")
      assert has_element?(view, "#new-game[phx-value-kind=extra]", "An extra game")
      assert has_element?(view, "#new-game-replace", "It replaces the game of the pairing")
      refute has_element?(view, "#game-local")
      assert new_tab?(view, "game-site-link", @site <> "/live/1/3")

      view |> element("#new-game") |> render_click()
      assert Boards.snapshot(board.id).game_no == 2

      assert has_element?(view, "#game-local", "This game stays on the box")
      assert has_element?(view, "#game-local", "game 2 on this board")
      assert has_element?(view, "#game-here-where-1", "leaves the box")
      assert has_element?(view, "#game-here-where-2", "stays on the box")
      # A link to the other game's page would show the wrong game.
      refute has_element?(view, "#game-site-link")

      view |> element("#send-this-instead") |> render_click()
      refute has_element?(view, "#game-local")
      assert has_element?(view, "#game-here-where-2", "leaves the box")
      assert has_element?(view, "#game-here-where-1", "stays on the box")
      assert has_element?(view, "#game-site-link")
    end

    test "'It replaces the game of the pairing' on purpose", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/round/1/board/3")
      assert has_element?(view, "#new-game-replace[data-confirm]")
      view |> element("#new-game-replace") |> render_click()
      assert [%{local: true, result: "0-1"}, %{local: false, game_no: 2}] = Games.history(1, 3)
      refute has_element?(view, "#game-local")
      # No result on the new one now: the next 'New game' replaces it.
      assert has_element?(view, "#new-game:not([phx-value-kind=extra])")
      refute has_element?(view, "#new-game-replace")
    end

    test "the Outbox says why nothing is waiting for that board", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/round/1/board/3")
      view |> element("#new-game") |> render_click()

      {:ok, outbox, _html} = live(conn, ~p"/outbox")
      tid = Tournaments.default_id()
      assert has_element?(outbox, "#staying-home-#{tid}-3", "Board 3 plays a game that stays")
      assert has_element?(outbox, "#staying-home-#{tid}-3 a[href='/round/1/board/3']")

      view |> element("#send-this-instead") |> render_click()
      {:ok, outbox, _html} = live(conn, ~p"/outbox")
      refute has_element?(outbox, "#staying-home")
    end
  end

  describe "a new game over a game with no result" do
    test "is the game of the pairing, and the confirm text says so", %{conn: conn} do
      board = board_on(3)
      play_on("FAKE1", board.id, ~w(e4 e5))
      {:ok, view, _html} = live(conn, ~p"/round/1/board/3")

      assert has_element?(
               view,
               "#new-game[phx-value-kind=replace][data-confirm*='game of the pairing']"
             )

      refute has_element?(view, "#new-game-replace")
      view |> element("#new-game") |> render_click()
      assert [%{local: true}, %{local: false}] = Games.history(1, 3)
      refute has_element?(view, "#game-local")

      {:ok, round, _html} = live(conn, ~p"/round/1")
      assert has_element?(round, "#tile-new-game-3[phx-value-kind=replace]", "New game")
      refute has_element?(round, "#tile-local-3")
    end

    test "on a board nobody is paired on it stays, as ever, and says so", %{conn: conn} do
      board = board_on(7)
      play_on("FAKE1", board.id, ~w(e4 e5))
      Boards.new_game(board.id)

      {:ok, view, _html} = live(conn, ~p"/round/1/board/7")
      assert has_element?(view, "#game-local", "game 2 on this board")
      refute has_element?(view, "#new-game-replace")
      assert has_element?(view, "#send-this-instead")
    end
  end

  describe "Setup" do
    test "the tournament's results page is a link; a tournament without one says why", %{
      conn: conn
    } do
      pairing_program()
      open = linked(17, name: "Open", boards: 2)
      own = Tournaments.default()
      {:ok, view, _html} = live(conn, ~p"/setup")

      assert new_tab?(view, "tournament-site-link-#{open.id}", "http://results.test/t/slug-17")
      assert new_tab?(view, "tournament-site-link-#{own.id}", @site)
      assert new_tab?(view, "server-site-link", @site)

      own_put(server_url: "")
      {:ok, view, _html} = live(conn, ~p"/setup")
      refute has_element?(view, "#tournament-site-link-#{own.id}")
      refute has_element?(view, "#server-site-link")
      assert has_element?(view, "#tournament-site-none-#{own.id}", "No results site")
    end
  end

  describe "the Outbox" do
    test "the results site's card links to where it sends, each tournament to its own", %{
      conn: conn
    } do
      pairing_program()
      open = linked(17, name: "Open", boards: 2)
      own_board()
      own = Tournaments.default()
      {:ok, view, _html} = live(conn, ~p"/outbox")

      assert new_tab?(view, "dest-site-link-#{own.id}", @site)
      assert new_tab?(view, "dest-site-link-#{open.id}", "http://results.test/t/slug-17")
      assert new_tab?(view, "link-target-open-#{open.id}", "http://results.test/t/slug-17")
    end

    test "a tournament without a results page has no link and says why", %{conn: conn} do
      own_put(server_url: "")
      {:ok, view, _html} = live(conn, ~p"/outbox")
      own = Tournaments.default()
      refute has_element?(view, "#dest-site-link-#{own.id}")
      assert has_element?(view, "#dest-site-#{own.id}", "No results site")
    end
  end

  describe "the bar" do
    test "with one tournament in use, the results badge has a link to its page", %{conn: conn} do
      pairing_program()
      open = linked(17, name: "Open", boards: 2)
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#head-results")
      assert new_tab?(view, "head-results-open", "http://results.test/t/slug-17")
      assert open.id != Tournaments.default_id()
    end

    test "with several in use there is no telling which one, so no link", %{conn: conn} do
      pairing_program()
      linked(17, name: "Open", boards: 2)
      linked(18, name: "U12", boards: 2)
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#head-results")
      refute has_element?(view, "#head-results-open")
    end
  end

  test "Help says the public page may be behind on purpose", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/help/openpairings-and-openresults")
    assert has_element?(view, "#results-site")
    assert has_element?(view, "#manual-chapter-body", "Open the results site")
    assert has_element?(view, "#manual-chapter-body", "behind on purpose")

    {:ok, view, _html} = live(conn, ~p"/help/following-games")
    assert has_element?(view, "#new-game", "Another game on the same board")
    assert has_element?(view, "#manual-chapter-body", "Send this one instead")
  end
end
