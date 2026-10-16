defmodule AlnaslWeb.FrameTest do
  @moduledoc """
  The frame and the front page, as rebuilt: the hall picker that keeps the
  page, the account menu with a person's own language and the theme, the
  notices folded after two, and Live showing what is placed and played in
  the hall on show - as tiles or as a list.
  """

  use AlnaslWeb.SiteCase, async: false

  import AlnaslWeb.AccountHelpers
  import Alnasl.LinkHelpers
  import Phoenix.Component, only: [sigil_H: 2]

  alias Alnasl.{Accounts, Games, Halls, Placements, Settings, Tournaments}
  alias Alnasl.Tournaments.Tournament

  describe "a box without accounts" do
    test "no hall picker for one hall; the account menu holds language and theme", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      refute has_element?(view, "#hall-picker")
      assert has_element?(view, "#account-button[aria-expanded=false]")
      assert has_element?(view, "#account-menu[hidden]")
      assert has_element?(view, "#account-menu #locale-form[action='/locale'][method=post]")
      assert has_element?(view, "#locale-form input[name=return_to][value='/boards']")
      assert has_element?(view, "#account-menu #theme-picker")
      refute has_element?(view, "#account-link")
      refute has_element?(view, "#log-out")
      assert has_element?(view, "#brand-edition", "Alnasl")
    end

    test "the places come in groups, and a phone has them all", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for {group, keys} <- [
            {"play", ~w(round boards pgn)},
            {"send", ~w(outbox)},
            {"manage", ~w(halls setup)},
            {"back", ~w(log recordings)},
            {"help", ~w(help)}
          ],
          key <- keys do
        assert has_element?(view, "#nav-group-#{group} #nav-#{key}")
        # The phone's tab bar, or its More sheet.
        assert has_element?(view, "#tab-bar #tab-#{key}")
      end

      assert has_element?(view, "#nav-round[aria-current=page]", "Live")
      assert has_element?(view, "#nav-outbox", "Results")
      assert has_element?(view, "#tab-more-menu #tab-setup")
      refute has_element?(view, "#tab-more-menu #tab-round")
    end
  end

  describe "the hall picker" do
    setup do
      owner = first_owner()
      annex = hall_fixture("Annex")
      %{owner: owner, own: Halls.own(), annex: annex}
    end

    test "shows the hall, lists the halls with roles, and switching keeps the page", ctx do
      %{conn: conn, owner: owner, own: own, annex: annex} = ctx
      conn = log_in(conn, owner, own)
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#hall-picker-button[aria-expanded=false]")
      assert has_element?(view, "#hall-picker-current", own.name)
      assert has_element?(view, "#hall-picker-live", "0 live")
      assert has_element?(view, "#hall-switch-#{own.id}[aria-current=true]")
      assert has_element?(view, "#hall-switch-#{annex.id}", "owner")
      assert has_element?(view, "#hall-switch-#{annex.id}[href*='return_to=%2Fboards']")
      assert has_element?(view, "#hall-picker-all[href='/halls']")
      # Seven halls before there is a search field.
      refute has_element?(view, "#hall-search")

      conn = get(conn, ~p"/halls/#{annex.id}/enter?return_to=/boards")
      assert redirected_to(conn) == "/boards"
      assert Plug.Conn.get_session(conn, :hall_id) == annex.id
    end

    test "a return_to that leaves the site goes home instead", ctx do
      %{conn: conn, owner: owner, annex: annex} = ctx

      for bad <- ["//evil.example/x", "https://evil.example", "/\\evil.example", "javascript:x"] do
        conn = get(log_in(conn, owner), ~p"/halls/#{annex.id}/enter?#{[return_to: bad]}")
        assert redirected_to(conn) == "/"
      end
    end

    test "from seven halls on, a search field", %{conn: conn, owner: owner} do
      for n <- 1..5, do: hall_fixture("Hall #{n}")
      {:ok, view, _html} = live(log_in(conn, owner), ~p"/")
      assert has_element?(view, "#hall-search[phx-hook]")
    end

    test "nothing for an account with one hall", %{conn: conn, own: own} do
      arbiter = member(own, user_fixture("arbiter@example.org"), "arbiter")
      {:ok, view, _html} = live(log_in(conn, arbiter), ~p"/")
      refute has_element?(view, "#hall-picker")
      assert has_element?(view, "#account-role", "arbiter in this hall")
    end
  end

  describe "the account menu" do
    setup do
      %{owner: first_owner()}
    end

    test "says who and what, and leads to the account and out", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(log_in(conn, owner), ~p"/")
      assert has_element?(view, "#account-email", owner.email)
      assert has_element?(view, "#account-role", "owner in this hall")
      assert has_element?(view, "#account-link[href='/account']")
      assert has_element?(view, "#log-out[data-method=delete]")
      assert has_element?(view, "#account-menu #theme-picker")
    end

    test "the language is kept with the account, and nobody else's changes", %{
      conn: conn,
      owner: owner
    } do
      other = member(Halls.own(), user_fixture("other@example.org"), "viewer")

      conn =
        conn
        |> log_in(owner)
        |> post(~p"/locale", %{"locale" => "nl", "return_to" => "/log"})

      assert redirected_to(conn) == "/log"
      assert Accounts.get_user(owner.id).locale == "nl"
      refute conn.resp_cookies[AlnaslWeb.Hall.locale_cookie()]
      assert Settings.get("locale") == "en"

      {:ok, view, _html} = live(log_in(build_conn(), Accounts.get_user(owner.id)), ~p"/")
      assert has_element?(view, "#locale-nl[aria-current=true]")
      refute has_element?(view, "#nav-group-play[aria-label=Play]")

      {:ok, view, _html} = live(log_in(build_conn(), other), ~p"/")
      assert has_element?(view, "#locale-en[aria-current=true]")
      assert has_element?(view, "#nav-group-play[aria-label=Play]")
    end
  end

  describe "the server" do
    test "the brand says server, not a box's name", %{conn: conn} do
      server_mode()
      user = member(Halls.own(), user_fixture("arbiter@example.org"), "arbiter")
      Settings.put("box_name", "Kitchen")
      {:ok, view, _html} = live(log_in(conn, user), ~p"/")
      assert has_element?(view, "#brand-edition", "server")
      refute has_element?(view, "#brand-edition", "Kitchen")
    end
  end

  describe "notices" do
    test "two in sight, the rest folded, and three tournaments named at most" do
      asks =
        for n <- 1..5,
            do: %{tournament: %Tournament{id: n, name: "Event #{n}"}, from: nil, to: nil}

      assigns = %{
        link: %{state: :offline, pending: 2},
        update: %{version: "9.9.9", url: "https://example.org", size: nil},
        hall: %{
          heads: :results_only,
          waiting: 0,
          live: %{},
          seating: %{auto: nil, outside: [], ask: asks}
        }
      }

      html =
        rendered_to_string(~H"""
        <AlnaslWeb.Layouts.app
          flash={%{}}
          nav={:boards}
          title="T"
          link={@link}
          update={@update}
          hall={@hall}
        >
          page
        </AlnaslWeb.Layouts.app>
        """)

      doc = LazyHTML.from_fragment(html)
      shown = doc |> LazyHTML.query("#notices > div.banner[id]") |> LazyHTML.attribute("id")
      assert shown == ["offline-banner", "ask-banner"]

      assert doc |> LazyHTML.query("#more-notices[hidden] #update-banner") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#more-notices-button") |> LazyHTML.text() =~ "1 more notice"

      ask = doc |> LazyHTML.query("#ask-banner") |> LazyHTML.text()
      assert ask =~ "Event 1, Event 2, Event 3 and 2 more"
      refute ask =~ "Event 4"
    end
  end

  describe "Live" do
    setup do
      pairing_program()
      owner = first_owner()
      %{owner: owner, own: Halls.own(), annex: hall_fixture("Annex")}
    end

    defp store_game(t, n) do
      Games.ensure(t.id, 1, n, Games.pairing_attrs(Tournaments.board(t.id, 1, n)))
    end

    test "shows only the tournaments placed in the hall on show", ctx do
      %{conn: conn, owner: owner, own: own, annex: annex} = ctx
      here = linked(201, name: "Here", boards: 4)
      there = linked(202, name: "There", boards: 4)
      {:ok, _placement, _} = Placements.add(there, annex.id)
      :ok = remove_placement(there, own.id)

      store_game(here, 1)
      store_game(there, 1)

      {:ok, view, _html} = live(log_in(conn, owner, own), ~p"/")
      assert has_element?(view, "#round-section-t#{here.id}")
      refute has_element?(view, "#round-section-t#{there.id}")
      # One tournament here: no tabs.
      refute has_element?(view, "#tournament-filter")

      {:ok, view, _html} = live(log_in(build_conn(), owner, annex), ~p"/")
      assert has_element?(view, "#round-section-t#{there.id}")
      refute has_element?(view, "#round-section-t#{here.id}")
    end

    test "a tournament in two halls shows each hall the games played there", ctx do
      %{conn: conn, owner: owner, own: own, annex: annex} = ctx
      split = linked(203, name: "Split", boards: 16)
      {:ok, split} = Tournaments.assign_tables(split, 1, 8, own.id)
      {:ok, _placement, _} = Placements.add(split, annex.id)

      store_game(split, 2)
      store_game(split, 10)

      # The only tournament here: every pairing of this hall's half is a tile.
      {:ok, view, _html} = live(log_in(conn, owner, own), ~p"/")
      assert has_element?(view, "#tile-t#{split.id}-2")
      assert has_element?(view, "#tile-t#{split.id}-8")
      refute has_element?(view, "#tile-t#{split.id}-10")
      refute has_element?(view, "#round-unplaced-t#{split.id}")

      {:ok, view, _html} = live(log_in(build_conn(), owner, annex), ~p"/")
      assert has_element?(view, "#tile-t#{split.id}-10")
      assert has_element?(view, "#tile-t#{split.id}-16")
      refute has_element?(view, "#tile-t#{split.id}-2")

      # With a second tournament here, the pairings without a board are a
      # count, and only this hall's half of them.
      other = linked(204, name: "Other", boards: 4)
      store_game(other, 1)

      {:ok, view, _html} = live(log_in(build_conn(), owner, own), ~p"/")
      assert has_element?(view, "#tile-t#{split.id}-2")
      refute has_element?(view, "#tile-t#{split.id}-3")
      refute has_element?(view, "#tile-t#{split.id}-10")
      assert has_element?(view, "#round-unplaced-t#{split.id}", "7 pairings")
    end

    defp remove_placement(tournament, hall_id) do
      placement = Placements.in_hall(Tournaments.get!(tournament.id), hall_id)
      Placements.remove(placement)
    end
  end

  describe "Live's two views" do
    test "tiles for a few boards; the list on asking, and a row per board", %{conn: conn} do
      for n <- 1..3, do: Games.ensure(Tournaments.default_id(), 1, n, %{})
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#live-view[phx-hook]")
      assert has_element?(view, "#view-boards[aria-pressed=true]")
      assert has_element?(view, "#tiles")
      refute has_element?(view, "#board-list")

      view |> element("#view-list") |> render_click()
      assert has_element?(view, "#view-list[aria-pressed=true]")
      refute has_element?(view, "#tiles")
      assert has_element?(view, "#board-list #row-1 #row-link-1[href='/round/1/board/1']")
      assert has_element?(view, "#board-list #row-3")

      # The hook tells the page what this browser chose before.
      render_hook(view, "set_view", %{"view" => "boards"})
      assert has_element?(view, "#tiles")
      render_hook(view, "set_view", %{"view" => "nonsense"})
      assert has_element?(view, "#tiles")
    end

    test "from 24 boards a browser that chose nothing gets the list", %{conn: conn} do
      for n <- 1..24, do: Games.ensure(Tournaments.default_id(), 1, n, %{})
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#view-list[aria-pressed=true]")
      assert has_element?(view, "#board-list #row-24")
      refute has_element?(view, "#tiles")
    end

    test "a board's message for a board that is not here changes nothing", %{conn: conn} do
      for n <- 1..2, do: Games.ensure(Tournaments.default_id(), 1, n, %{})
      {:ok, view, _html} = live(conn, ~p"/")
      send(view.pid, {:board, 987_654})
      send(view.pid, :refresh)
      assert has_element?(view, "#tile-1")
    end
  end
end
