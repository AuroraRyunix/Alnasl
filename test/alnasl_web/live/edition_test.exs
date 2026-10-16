defmodule AlnaslWeb.EditionTest do
  @moduledoc """
  The two editions: a box in a hall, and the server. The server does not
  offer what needs a serial port or an install (and refuses the events when
  they come anyway); the box is as it was. And the front page, which draws
  the boards that exist here and the games stored, and counts the rest.
  """

  use AlnaslWeb.SiteCase, async: false

  import AlnaslWeb.AccountHelpers
  import Alnasl.LinkHelpers

  alias Alnasl.{Boards, Settings, Tables, Tournaments, Updates}

  @pgn """
  [White "Anderssen"]
  [Black "Kieseritzky"]
  [Result "1-0"]

  1. e4 e5 2. f4 exf4 3. Bc4 Qh4+ 4. Kf1 b5 1-0
  """

  test "the edition is one answer that the older questions read" do
    assert Alnasl.edition() == :box
    assert Alnasl.Boards.local?()
    refute Alnasl.Accounts.server?()

    server_mode()
    assert Alnasl.edition() == :server
    refute Alnasl.Boards.local?()
    assert Alnasl.Accounts.server?()
  end

  describe "a box" do
    test "Setup keeps its updates, its PIN, the box name, and says which edition it is", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/setup")
      assert has_element?(view, "#about-edition", "Box")
      assert has_element?(view, "#setup-updates")
      assert has_element?(view, "#setup-pin")
      assert has_element?(view, "#box-name")
      assert has_element?(view, "#setup-box", "This box")
    end

    test "Boards keeps adding a board and the serial ports", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#add-board-form")
      assert has_element?(view, "#ports")
      assert has_element?(view, "#find-toggle")
    end
  end

  describe "the server" do
    setup %{conn: conn} do
      owner = first_owner()
      server_mode()
      %{conn: log_in(conn, owner), owner: owner}
    end

    test "Setup draws none of the box's panels, and names itself", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      assert has_element?(view, "#about-edition", "Server")
      assert has_element?(view, "#setup-box", "This server")
      refute has_element?(view, "#box-name")
      refute has_element?(view, "#setup-updates")
      refute has_element?(view, "#autostart-form")
      refute has_element?(view, "#setup-pin")
      refute has_element?(view, "#update-banner")
      # What both editions have stays.
      assert has_element?(view, "#setup-bridges")
      assert has_element?(view, "#setup-accounts")
      assert has_element?(view, "#box-locale")
    end

    test "Setup refuses the box's events", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      render_hook(view, "save_pin", %{"door" => %{"pin" => "1234"}})
      refute Settings.pin_set?()

      render_hook(view, "set_listen", %{"choice" => "lan"})
      render_hook(view, "save_update_mode", %{"mode" => "never"})
      assert Updates.mode() == "ask"

      render_hook(view, "check_update", %{})
      render_hook(view, "update_start", %{})
      refute has_element?(view, "#update-confirm")

      name = Settings.get("box_name")

      render_hook(view, "save_box", %{
        "box" => %{"box_name" => "Renamed", "locale" => "en", "round" => "1"}
      })

      assert Settings.get("box_name") == name
    end

    test "Boards has no Add a board, no serial ports, and refuses both", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")
      refute has_element?(view, "#add-board")
      refute has_element?(view, "#add-board-form")
      refute has_element?(view, "#ports")
      assert has_element?(view, "#phone")
      # Numbering by touching works for bridged boards too.
      assert has_element?(view, "#find-toggle")

      before = length(Boards.list())

      render_hook(view, "add", %{
        "board" => %{"driver" => "simulator", "name" => "", "game" => "1", "speed" => "20"}
      })

      render_hook(view, "read_as_loop", %{"id" => "1"})
      assert length(Boards.list()) == before
    end

    test "PGN does not offer simulator boards, and refuses them", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pgn")
      view |> form("#paste-form", paste: %{text: @pgn}) |> render_submit()
      assert has_element?(view, "#read-1")
      refute has_element?(view, "#simulate-all")
      refute has_element?(view, "#simulate-1")

      before = length(Boards.list())
      render_hook(view, "simulate_all", %{})
      render_hook(view, "simulate", %{"index" => "1"})
      assert length(Boards.list()) == before
    end
  end

  describe "Live" do
    setup do
      pairing_program()
    end

    # Ten tournaments of forty pairings each; four real boards in two of
    # them, stored games in a third, and nothing at all in the other seven.
    defp ten_tournaments do
      ts = for id <- 100..109, do: linked(id, name: "Open #{id}", boards: 40)
      [a, b, c | quiet] = ts

      for {t, n, port} <- [{a, 1, "FAKE1"}, {a, 2, "FAKE2"}, {b, 5, "FAKE3"}, {b, 6, "FAKE4"}] do
        board = fake_dgt(port)
        {:ok, board} = Tables.set_table(board, n)
        {:ok, _} = Boards.update(board, %{tournament_id: t.id, round: 1, board_no: n})
      end

      for n <- 1..3 do
        pairing = Tournaments.board(c.id, 1, n)
        Games.ensure(c.id, 1, n, Games.pairing_attrs(pairing))
      end

      %{a: a, b: b, c: c, quiet: quiet}
    end

    defp tile_count(view),
      do: view |> render() |> String.split(~s(class="tile-wrap")) |> length() |> Kernel.-(1)

    test "draws the real boards and the stored games, and counts the rest", %{conn: conn} do
      %{a: a, b: b, c: c, quiet: quiet} = ten_tournaments()
      {:ok, view, _html} = live(conn, ~p"/")

      # 2 + 2 boards here, 3 games stored: nothing else is a tile.
      assert tile_count(view) == 7
      assert has_element?(view, "#tile-t#{a.id}-1")
      assert has_element?(view, "#tile-t#{b.id}-6")
      assert has_element?(view, "#tile-t#{c.id}-3")
      refute has_element?(view, "#tile-t#{a.id}-3")
      refute has_element?(view, "#tile-t#{c.id}-4")

      assert has_element?(view, "#round-unplaced-t#{a.id}", "38 pairings without a board here")
      assert has_element?(view, "#round-unplaced-t#{c.id}", "37 pairings without a board here")

      # The tournaments with nothing are not sections, not tabs, and one line.
      for t <- quiet do
        refute has_element?(view, "#round-section-t#{t.id}")
        refute has_element?(view, "#filter-#{t.id}")
      end

      for t <- [a, b, c] do
        assert has_element?(view, "#round-section-t#{t.id}")
        assert has_element?(view, "#filter-#{t.id}")
      end

      assert has_element?(view, "#not-on-the-boards", "7 more tournaments")
      assert has_element?(view, "#not-on-the-boards-setup[href='/setup']")
      refute has_element?(view, "#live-empty")
    end

    test "a tournament asked for by name is shown, boards or not", %{conn: conn} do
      %{quiet: [q | _]} = ten_tournaments()
      {:ok, view, _html} = live(conn, ~p"/t/#{q.id}")
      assert has_element?(view, "#round-section-t#{q.id}")
      assert has_element?(view, "#round-empty-t#{q.id}")
      assert has_element?(view, "#round-empty-t#{q.id}", "no board here")
      assert tile_count(view) == 0
    end

    test "a box with one tournament draws every pairing, as the manual says", %{conn: conn} do
      t = linked(100, name: "Open", boards: 12)
      board = fake_dgt("FAKE1")
      {:ok, board} = Tables.set_table(board, 1)
      {:ok, _} = Boards.update(board, %{tournament_id: t.id, round: 1, board_no: 1})

      {:ok, view, _html} = live(conn, ~p"/")
      assert tile_count(view) == 12
      assert has_element?(view, "#tile-t#{t.id}-12")
      refute has_element?(view, "#round-unplaced-t#{t.id}")
    end

    test "nothing on the boards: one place to go, and the count", %{conn: conn} do
      for id <- 100..101, do: linked(id, boards: 3)
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#live-empty")
      assert has_element?(view, "#live-empty-boards")
      assert has_element?(view, "#not-on-the-boards", "more tournaments")
      assert tile_count(view) == 0
    end
  end
end
