defmodule AlnaslWeb.SetupSectionsTest do
  @moduledoc """
  Setup, split: each section its own address with a list beside it (a select
  on a phone), the sections an edition or a role cannot use not drawn, and
  the tournaments as compact rows - the ones with boards here first, the
  rest folded, the quiet ones behind a toggle, a search from nine on.
  """

  use AlnaslWeb.SiteCase, async: false

  import AlnaslWeb.AccountHelpers

  alias Alnasl.{Boards, Halls, Tables}
  alias Alnasl.Tournaments.Tournament

  @panels [
    {"tournaments", "#setup-tournaments"},
    {"connections", "#setup-connections"},
    {"results", "#setup-server"},
    {"results", "#setup-lichess"},
    {"this-box", "#setup-about"},
    {"this-box", "#setup-box"},
    {"access", "#setup-pin"},
    {"access", "#setup-phone"},
    {"access", "#setup-accounts"},
    {"updates", "#setup-updates"},
    {"advanced", "#setup-tracker"}
  ]

  defp tournament(name, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Tournament{
          kind: "linked",
          name: name,
          label: name,
          state: "running",
          hall_id: Halls.own_id()
        },
        attrs
      )
    )
  end

  defp board_in(t, port, n) do
    {:ok, board} = Tables.set_table(fake_dgt(port), n)
    {:ok, _} = Boards.update(board, %{tournament_id: t.id, round: 1, board_no: n})
  end

  describe "the sections of a box" do
    test "each has its own address and holds its panels", %{conn: conn} do
      for {slug, selector} <- @panels do
        {:ok, view, _html} = live(conn, "/setup/#{slug}")
        assert has_element?(view, selector), "#{selector} on /setup/#{slug}"
        assert has_element?(view, "#setup-nav-#{slug}.current"), slug
      end
    end

    test "a panel is on its own section only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/connections")
      refute has_element?(view, "#setup-tournaments")
      refute has_element?(view, "#setup-lichess")
      refute has_element?(view, "#setup-tracker")
    end

    test "/setup is the wizard until it is done, and an unknown section leads there", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/setup")
      assert has_element?(view, "#setup-wizard")
      assert has_element?(view, "#setup-nav-wizard.current")

      assert {:error, {:live_redirect, %{to: "/setup/wizard"}}} =
               live(conn, "/setup/nothing-here")
    end

    test "the list beside the page and the select on a phone name the same sections", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/setup")

      for slug <- ~w(wizard tournaments connections results this-box access updates advanced) do
        assert has_element?(view, "#setup-nav-#{slug}[href='/setup/#{slug}']")
        assert has_element?(view, "#setup-select option[value=#{slug}]")
      end
    end

    test "the select moves to a section, and refuses one that is not there", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view |> form("#setup-select-form", section: "access") |> render_change()
      assert_patch(view, "/setup/access")
      assert has_element?(view, "#setup-pin")

      render_hook(view, "goto_section", %{"section" => "no-such-thing"})
      assert has_element?(view, "#setup-pin")
    end

    test "the colour theme and the bridges are not on any section", %{conn: conn} do
      for {slug, _selector} <- Enum.uniq_by(@panels, &elem(&1, 0)) do
        {:ok, view, _html} = live(conn, "/setup/#{slug}")
        refute has_element?(view, "#setup-look"), slug
        refute has_element?(view, "#theme-grid"), slug
        refute has_element?(view, "#setup-bridges"), slug
      end
    end
  end

  describe "the sections of an account that is not the box's admin" do
    setup %{conn: conn} do
      _owner = first_owner()
      hall = hall_fixture("Annex")
      arbiter = member(hall, user_fixture("arbiter@example.org"), "arbiter")
      %{conn: log_in(conn, arbiter, hall)}
    end

    test "only the sections it can use are there", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      assert has_element?(view, "#setup-nav-tournaments")
      assert has_element?(view, "#setup-nav-connections")
      assert has_element?(view, "#setup-nav-this-box")
      refute has_element?(view, "#setup-nav-updates")
      refute has_element?(view, "#setup-nav-advanced")
      refute has_element?(view, "#setup-nav-results")

      for slug <- ~w(updates advanced results) do
        assert {:error, {:live_redirect, %{to: "/setup/wizard"}}} =
                 live(conn, "/setup/#{slug}")
      end
    end
  end

  describe "the server" do
    setup %{conn: conn} do
      owner = first_owner()
      server_mode()
      %{conn: log_in(conn, owner)}
    end

    test "has no Access and no Updates, and its phone and accounts are under This server", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/setup/this-box")
      assert has_element?(view, "#setup-box", "This server")
      assert has_element?(view, "#setup-phone")
      assert has_element?(view, "#setup-accounts")
      refute has_element?(view, "#setup-nav-access")
      refute has_element?(view, "#setup-nav-updates")
      assert has_element?(view, "#setup-nav-advanced")
    end
  end

  describe "the tournaments as rows" do
    test "a row says name, state, round, boards and tables; the details open on a click", %{
      conn: conn
    } do
      t = tournament("Open", %{round: 3})
      board_in(t, "FAKE1", 1)
      {:ok, view, _html} = live(conn, ~p"/setup/tournaments")

      assert has_element?(view, "#tournament-#{t.id} .tdot.ok")
      assert has_element?(view, "#tournament-status-#{t.id}", "Running")
      assert has_element?(view, "#tournament-round-#{t.id}", "round 3")
      assert has_element?(view, "#tournament-count-#{t.id}", "1 board")
      assert has_element?(view, "#tournament-chip-#{t.id}")
      refute has_element?(view, "#tournament-body-#{t.id}")
      refute has_element?(view, "#tables-form-#{t.id}")

      view |> element("#tournament-toggle-#{t.id}") |> render_click()
      assert has_element?(view, "#tournament-body-#{t.id} #tables-form-#{t.id}")
      assert has_element?(view, "#placements-#{t.id}")
      assert has_element?(view, "#tournament-toggle-#{t.id}[aria-expanded=true]")

      view |> element("#tournament-toggle-#{t.id}") |> render_click()
      refute has_element?(view, "#tournament-body-#{t.id}")
    end

    test "the ones with boards here come first, the others are one line until asked for", %{
      conn: conn
    } do
      here = tournament("Here")
      away = tournament("Away")
      board_in(here, "FAKE1", 1)
      {:ok, view, _html} = live(conn, ~p"/setup/tournaments")

      assert has_element?(view, "#tournaments #tournament-#{here.id}")
      refute has_element?(view, "#tournament-#{away.id}")
      assert has_element?(view, "#toggle-rest", "more tournament")

      view |> element("#toggle-rest") |> render_click()
      assert has_element?(view, "#tournaments-rest #tournament-#{away.id}")

      view |> element("#toggle-rest") |> render_click()
      refute has_element?(view, "#tournament-#{away.id}")
    end

    test "with no board anywhere the list is not folded", %{conn: conn} do
      one = tournament("One")
      two = tournament("Two")
      {:ok, view, _html} = live(conn, ~p"/setup/tournaments")
      assert has_element?(view, "#tournament-#{one.id}")
      assert has_element?(view, "#tournament-#{two.id}")
      refute has_element?(view, "#toggle-rest")
    end

    test "finished and not started tournaments are behind a toggle, unless one is asked for",
         %{conn: conn} do
      live_one = tournament("Live")
      over = tournament("Over", %{state: "finished"})
      later = tournament("Later", %{state: "setup"})
      {:ok, view, _html} = live(conn, ~p"/setup/tournaments")

      assert has_element?(view, "#tournament-#{live_one.id}")
      refute has_element?(view, "#tournament-#{over.id}")
      refute has_element?(view, "#tournament-#{later.id}")
      assert has_element?(view, "#toggle-quiet", "2 tournaments not started or finished")

      view |> element("#toggle-quiet") |> render_click()
      assert has_element?(view, "#tournament-#{over.id}")
      assert has_element?(view, "#tournament-#{later.id}")
      assert has_element?(view, "#tournament-status-#{over.id}", "Finished")
      assert has_element?(view, "#tournament-status-#{later.id}", "Not started")

      view |> element("#toggle-quiet") |> render_click()
      refute has_element?(view, "#tournament-#{over.id}")

      {:ok, view, _html} = live(conn, ~p"/setup/tournaments?open=#{over.id}")
      assert has_element?(view, "#tournament-#{over.id}")
      assert has_element?(view, "#tournament-body-#{over.id}")
    end

    test "the search field comes with the ninth tournament and filters by name", %{conn: conn} do
      # The box's own tournament is one of them.
      for n <- 1..7, do: tournament("Cup #{n}")
      {:ok, view, _html} = live(conn, ~p"/setup/tournaments")
      refute has_element?(view, "#tournament-search")

      tournament("Zebra Open")
      {:ok, view, _html} = live(conn, ~p"/setup/tournaments")
      assert has_element?(view, "#tournament-search")

      html = view |> form("#tournament-search-form", q: "zebra") |> render_change()
      assert html =~ "Zebra Open"
      refute html =~ "Cup 3"

      html = view |> form("#tournament-search-form", q: "nothing like it") |> render_change()
      assert has_element?(view, "#tournaments-empty")
      refute html =~ "Zebra Open"

      html = view |> form("#tournament-search-form", q: "") |> render_change()
      assert html =~ "Cup 3"
    end

    test "a search finds a tournament that is finished", %{conn: conn} do
      for n <- 1..8, do: tournament("Cup #{n}")
      over = tournament("Old Masters", %{state: "finished"})
      {:ok, view, _html} = live(conn, ~p"/setup/tournaments")
      refute has_element?(view, "#tournament-#{over.id}")

      view |> form("#tournament-search-form", q: "masters") |> render_change()
      assert has_element?(view, "#tournament-#{over.id}")
    end
  end

  describe "the connections as lines" do
    test "a line per connection with its state and a menu, and + Add opens the forms", %{
      conn: conn
    } do
      Alnasl.LinkHelpers.pairing_program()
      Alnasl.LinkHelpers.linked(17, name: "Open", boards: 2)
      [link] = Alnasl.Tournaments.links()

      {:ok, view, _html} = live(conn, ~p"/setup/connections")
      assert has_element?(view, "#link-#{link.id} .conn-line #link-state-#{link.id}")
      assert has_element?(view, "#link-menu-#{link.id} #test-link-#{link.id}")
      assert has_element?(view, "#link-menu-#{link.id} #remove-link-#{link.id}")

      # A connection is there: the forms are folded until "+ Add".
      assert has_element?(view, "#add-connection-panel.is-collapsed")
      view |> element("#add-connection") |> render_click()
      refute has_element?(view, "#add-connection-panel.is-collapsed")
      assert has_element?(view, "#add-connection-panel #code-form")
      assert has_element?(view, "#add-connection-panel #op-connect-form")
    end

    test "with none, the forms are open at once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/connections")
      assert has_element?(view, "#links-empty")
      refute has_element?(view, "#add-connection-panel.is-collapsed")
    end
  end
end
