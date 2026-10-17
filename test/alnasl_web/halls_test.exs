defmodule AlnaslWeb.HallsTest do
  @moduledoc """
  Halls and roles: a viewer changes nothing, an arbiter runs the games but
  adds no bridge, an owner does both and invites; and an account sees its
  own halls' boards, tournaments and bridges and nobody else's - on first
  sight and when the boards change underneath an open page.
  """

  use AlnaslWeb.SiteCase, async: false

  # A bridge stopped at the end of a test aborts its socket; not news.
  @moduletag :capture_log

  import AlnaslWeb.AccountHelpers

  alias Alnasl.{Accounts, Boards, Bridges, Halls, Tournaments}
  alias Alnasl.Bridges.Join

  defp remote_board(hall, name) do
    {:ok, board} =
      Boards.create(%{name: name, driver: "remote", port: "bridge-0:#{name}", hall_id: hall.id})

    board
  end

  defp bridge_in(hall, uid) do
    {:ok, join} = Bridges.create_join(DateTime.utc_now(:second), hall.id)

    {:ok, %{bridge: bridge}} =
      Bridges.redeem(join.code, %{"v" => 1, "bridge" => uid, "name" => uid, "software" => "arkab"})

    bridge
  end

  setup do
    owner = first_owner()
    a = hall_fixture("Hall A")
    b = hall_fixture("Hall B")
    %{owner: owner, a: a, b: b}
  end

  describe "roles" do
    test "a viewer follows and changes nothing", %{conn: conn, a: a} do
      viewer = member(a, user_fixture("viewer@example.org"), "viewer")
      board = remote_board(a, "A-1")

      {:ok, view, _html} = live(log_in(conn, viewer, a), ~p"/boards")
      assert has_element?(view, "#board-#{board.id}") or render(view) =~ "A-1"

      render_hook(view, "table", %{"board_id" => "#{board.id}", "table_no" => "7"})
      assert has_element?(view, "#flash-error")
      assert Boards.get(board.id).table_no == nil

      {:ok, setup, _html} = live(log_in(build_conn(), viewer, a), ~p"/setup")
      refute has_element?(setup, "#bridge-add")
      render_hook(setup, "add_bridge", %{})
      assert Alnasl.Repo.aggregate(Join, :count) == 0
    end

    test "an arbiter numbers tables but adds no bridge", %{conn: conn, a: a} do
      arbiter = member(a, user_fixture("arbiter@example.org"), "arbiter")
      board = remote_board(a, "A-1")

      {:ok, view, _html} = live(log_in(conn, arbiter, a), ~p"/boards")
      render_hook(view, "table", %{"board_id" => "#{board.id}", "table_no" => "7"})
      assert Boards.get(board.id).table_no == 7

      {:ok, setup, _html} = live(log_in(build_conn(), arbiter, a), ~p"/setup")
      refute has_element?(setup, "#bridge-add")
      render_hook(setup, "add_bridge", %{})
      assert Alnasl.Repo.aggregate(Join, :count) == 0

      {:ok, page, _html} = live(log_in(build_conn(), arbiter, a), ~p"/halls/#{a.id}")
      refute has_element?(page, "#bridge-add")
      refute has_element?(page, "#invite-form")
      render_hook(page, "add_bridge", %{})
      assert Alnasl.Repo.aggregate(Join, :count) == 0
    end

    test "an owner adds a bridge to the hall and invites", %{conn: conn, a: a} do
      owner = member(a, user_fixture("hall-owner@example.org"), "owner")

      {:ok, page, _html} = live(log_in(conn, owner, a), ~p"/halls/#{a.id}/bridges")
      page |> element("#bridge-add") |> render_click()
      assert has_element?(page, "#bridge-join-link")
      assert [%Join{hall_id: hall_id}] = Alnasl.Repo.all(Join)
      assert hall_id == a.id

      page |> element("#hall-tab-invitations") |> render_click()

      page
      |> form("#invite-form", invite: %{email: "hall-owner@example.org", role: "viewer"})
      |> render_submit()

      assert has_element?(page, "#invite-link")
    end

    test "the last owner of a hall stays one", %{conn: conn, a: a} do
      owner = member(a, user_fixture("hall-owner@example.org"), "owner")
      [m] = Halls.members(a)

      {:ok, page, _html} = live(log_in(conn, owner, a), ~p"/halls/#{a.id}")
      page |> element("#member-#{m.id}-remove") |> render_click()
      assert Halls.roles(owner) == %{a.id => "owner"}
    end
  end

  describe "what an account sees" do
    test "its hall's boards, live, and not another's", %{conn: conn, a: a, b: b} do
      arbiter = member(a, user_fixture("arbiter@example.org"), "arbiter")
      remote_board(a, "Alpha-board")
      remote_board(b, "Bravo-board")

      {:ok, view, html} = live(log_in(conn, arbiter, a), ~p"/boards")
      assert html =~ "Alpha-board"
      refute html =~ "Bravo-board"

      # The page hears of every board on the box; it shows its hall's.
      remote_board(b, "Bravo-late")
      remote_board(a, "Alpha-late")
      html = eventually_html(view, &(&1 =~ "Alpha-late"))
      refute html =~ "Bravo-late"
      refute html =~ "Bravo-board"

      {:ok, _round, html} = live(log_in(build_conn(), arbiter, a), ~p"/")
      refute html =~ "Bravo"
    end

    test "not another hall's tournament, page or files", %{conn: conn, a: a, b: b} do
      arbiter = member(a, user_fixture("arbiter@example.org"), "arbiter")
      theirs = Halls.local_tournament(b)
      conn = log_in(conn, arbiter, a)

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/t/#{theirs.id}/round/1")

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/t/#{theirs.id}/round/1/board/1")

      assert response(get(conn, ~p"/files/t/#{theirs.id}/round/1"), 404)
      refute Enum.any?(Halls.active(Accounts.scope(arbiter, a.id)), &(&1.id == theirs.id))

      {:ok, setup, _html} = live(log_in(build_conn(), arbiter, a), ~p"/setup")
      refute has_element?(setup, "#tournament-#{theirs.id}")
      refute has_element?(setup, "#tournament-#{Tournaments.default_id()}")
    end

    test "its hall's bridges only, and no other hall's page", %{conn: conn, a: a, b: b} do
      owner = member(a, user_fixture("hall-owner@example.org"), "owner")
      mine = bridge_in(a, "alpha-pi")
      theirs = bridge_in(b, "bravo-pi")

      {:ok, page, _html} = live(log_in(conn, owner, a), ~p"/halls/#{a.id}/bridges")
      assert has_element?(page, "#bridge-#{mine.id}")
      refute has_element?(page, "#bridge-#{theirs.id}")

      # Not by naming it either.
      render_hook(page, "remove_bridge", %{"id" => "#{theirs.id}"})
      assert Bridges.get(theirs.id).revoked_at == nil

      # Setup no longer holds the bridges; it leads to the hall's page.
      {:ok, setup, _html} = live(log_in(build_conn(), owner, a), ~p"/setup/access")
      refute has_element?(setup, "#setup-bridges")
      refute has_element?(setup, "#bridge-#{mine.id}")
      assert has_element?(setup, ~s(#setup-bridges-link[href="/halls/#{a.id}/bridges"]))

      assert {:error, {:live_redirect, %{to: "/halls"}}} =
               live(log_in(build_conn(), owner, a), ~p"/halls/#{b.id}")

      {:ok, index, _html} = live(log_in(build_conn(), owner, a), ~p"/halls")
      assert has_element?(index, "#hall-#{a.id}")
      refute has_element?(index, "#hall-#{b.id}")

      switched = get(log_in(build_conn(), owner, a), ~p"/halls/#{b.id}/enter")
      assert redirected_to(switched) == "/halls"
      refute get_session(switched, :hall_id) == b.id
    end

    test "an admin moves a bridge to another hall, boards and all", %{
      conn: conn,
      owner: admin,
      a: a,
      b: b
    } do
      bridge = bridge_in(a, "alpha-pi")
      {:ok, row} = Bridges.board_row(bridge, "COM3")
      assert row.hall_id == a.id

      {:ok, page, _html} = live(log_in(conn, admin, a), ~p"/halls/#{a.id}/bridges")

      page
      |> form("#bridge-#{bridge.id}-move", %{"hall" => "#{b.id}"})
      |> render_change(%{"bridge" => "#{bridge.id}", "hall" => "#{b.id}"})

      assert Bridges.get(bridge.id).hall_id == b.id
      moved = Boards.get(row.id)
      assert moved.hall_id == b.id
      assert moved.tournament_id == Halls.local_tournament(b).id
      refute has_element?(page, "#bridge-#{bridge.id}")
    end

    test "an account in no hall sees only that it is in none", %{conn: conn} do
      nobody = user_fixture("nobody@example.org")
      conn = log_in(conn, nobody)
      assert {:error, {:redirect, %{to: "/halls"}}} = live(conn, ~p"/boards")
      {:ok, view, _html} = live(conn, ~p"/halls")
      assert has_element?(view, "#halls-none")
    end
  end

  describe "bridges behind the sign-in" do
    test "a bridge joins and links with accounts on, by its own code and key", %{a: a} do
      dir = Path.join(System.tmp_dir!(), "alnasl-halls-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, pid} =
        Bandit.start_link(plug: AlnaslWeb.Endpoint, port: 0, ip: :loopback, startup_log: false)

      Process.unlink(pid)
      on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

      assert Accounts.login_required?()
      start_supervised!({Arkab.Bridge, data_dir: dir, name: "annex", sources: [], web: false})
      {:ok, code} = Bridges.create_join(DateTime.utc_now(:second), a.id)
      {:ok, _server_id} = Arkab.Bridge.join("http://127.0.0.1:#{port}/join/#{code.code}")

      [bridge] = Bridges.list()
      assert bridge.hall_id == a.id
      eventually(fn -> Bridges.live(bridge.id) end)
    end
  end
end
