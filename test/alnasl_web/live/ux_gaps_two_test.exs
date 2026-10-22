defmodule AlnaslWeb.UxGapsTwoTest do
  @moduledoc """
  The decisions that followed the 2026-10-21 audit: a viewer is not shown
  what it cannot do, a game can be deleted, the captures of a removed board
  belong to its hall's owner, a bridge can be renamed, a board put back on a
  bridge comes back, and a fair-play analysis can be deleted and leaves a
  frozen copy.
  """

  use AlnaslWeb.SiteCase, async: false

  import AlnaslWeb.AccountHelpers
  import Alnasl.FairPlayFixtures

  alias Alnasl.{Bridges, FairPlay, Halls, Recorder, Repo}
  alias Alnasl.FairPlay.{Snapshot, View}

  @moduletag :capture_log

  defp serve do
    {:ok, pid} =
      Bandit.start_link(plug: AlnaslWeb.Endpoint, port: 0, ip: :loopback, startup_log: false)

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp bridge_joined do
    dir = Path.join(System.tmp_dir!(), "alnasl-gaps2-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    port = serve()
    start_supervised!({Arkab.Bridge, data_dir: dir, name: "hall", sources: [], web: false})
    {:ok, code} = Bridges.create_join()
    {:ok, _server_id} = Arkab.Bridge.join("http://127.0.0.1:#{port}/join/#{code.code}")
    [bridge] = Bridges.list()
    eventually(fn -> Bridges.live(bridge.id) end)
    bridge
  end

  defp joined(email, role), do: Halls.own() |> member(user_fixture(email), role)

  defp command(bridge, cmd, fields) do
    Bridges.subscribe()
    {:ok, id} = Bridges.command(bridge.id, cmd, fields)
    assert_receive {:bridges, {:reply, _bridge, ^id, true, nil}}, 5_000
  end

  describe "a board put back on its bridge" do
    test "comes back in the same connection, once the bridge has forgotten it", %{conn: conn} do
      bridge = bridge_joined()
      replay = "test/fixtures/captures/real-06310-knight-moves.jsonl"
      source = %{"replay" => replay, "name" => "COM9", "speed" => 50}

      :ok = Arkab.Bridge.Ports.add(source)
      row = eventually(fn -> Enum.find(Bridges.rows(bridge), &(&1.port =~ "COM9")) end)

      eventually(fn -> Bridges.live(bridge.id).boards != [] end)
      {:ok, view, _html} = live(conn, ~p"/boards")
      view |> element("#delete-#{row.id}") |> render_click()
      assert Bridges.rows(bridge) == []
      eventually(fn -> Bridges.live(bridge.id).boards == [] end)

      # The bridge reports without it, which is how this end learns it forgot.
      assert Bridges.rows(bridge) == []

      # Forget the port and read it again, as the bridge's page does.
      command(bridge, "forget_port", %{"port" => "COM9"})
      :ok = Arkab.Bridge.Ports.add(source)

      assert eventually(fn -> Enum.find(Bridges.rows(bridge), &(&1.port =~ "COM9")) end)
    end
  end

  describe "renaming a bridge" do
    test "the Bridges tab renames it, and refuses an empty name", %{conn: conn} do
      bridge = bridge_joined()
      {:ok, view, _html} = live(conn, ~p"/halls/#{Halls.own_id()}/bridges")
      assert has_element?(view, "#bridge-#{bridge.id}-rename")

      view |> form("#bridge-#{bridge.id}-rename", %{name: "Annex, north wall"}) |> render_submit()
      assert Bridges.get(bridge.id).name == "Annex, north wall"
      assert has_element?(view, "#bridge-#{bridge.id} b", "Annex, north wall")

      html = view |> form("#bridge-#{bridge.id}-rename", %{name: "  "}) |> render_submit()
      assert html =~ "one to 80 characters"
      assert Bridges.get(bridge.id).name == "Annex, north wall"
    end
  end

  describe "deleting a game" do
    test "a game nothing is reading can be deleted, after a question that says what goes",
         %{conn: conn} do
      game = Alnasl.Games.ensure(Alnasl.Tournaments.default_id(), 1, 5, %{white: "A", black: "B"})
      {:ok, view, _html} = live(conn, ~p"/round/1/board/5")

      assert view |> element("#delete-game") |> render() =~ "PGN file"
      view |> element("#delete-game") |> render_click()

      assert Repo.get(Alnasl.Games.Game, game.id) == nil
      assert "game.deleted" in log_kinds()
    end

    test "a game a connected board is reading is refused", %{conn: conn} do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 7})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      play_on("FAKE1", board.id, ~w(e4 e5))

      {:ok, view, _html} = live(conn, ~p"/round/1/board/7")
      assert has_element?(view, "#delete-game[disabled]")
      assert has_element?(view, "#delete-game-why")

      assert render_hook(view, "delete_game", %{}) =~ "Disconnect it on the Boards page"
      assert Games.sans(Games.get(1, 7)) == ~w(e4 e5)
    end
  end

  describe "what a viewer is shown" do
    setup %{conn: conn} do
      _owner = first_owner()
      viewer = joined("viewer@example.org", "viewer")
      arbiter = joined("arbiter@example.org", "arbiter")
      board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      play_on("FAKE1", board.id, ~w(e4 e5))
      Alnasl.Games.ensure(Alnasl.Tournaments.default_id(), 1, 5, %{white: "A", black: "B"})

      %{board: board, viewer: log_in(conn, viewer), arbiter: log_in(conn, arbiter)}
    end

    test "Boards: nothing to press but looking", %{viewer: conn, arbiter: arbiter, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#board-#{board.id}")
      assert has_element?(view, "#show-me-#{board.id}")

      for id <- ["delete", "toggle", "flip", "rename-form", "table-form", "link-form"] do
        refute has_element?(view, "##{id}-#{board.id}"), "a viewer is shown #{id}"
      end

      for id <- ["add-board", "number-by-touch", "swap-submit", "link-in-order"] do
        refute has_element?(view, "##{id}"), "a viewer is shown #{id}"
      end

      {:ok, view, _html} = live(arbiter, ~p"/boards")

      for id <- ["delete", "toggle", "flip", "rename-form", "table-form", "link-form"] do
        assert has_element?(view, "##{id}-#{board.id}"), "an arbiter is not shown #{id}"
      end

      refute has_element?(view, "#delete-game")
    end

    test "a game's page: results and repairs are the arbiter's, deleting the owner's", %{
      viewer: conn,
      arbiter: arbiter
    } do
      {:ok, view, _html} = live(conn, ~p"/round/1/board/1")
      refute has_element?(view, "#result-1-0")
      refute has_element?(view, "#new-game")
      refute has_element?(view, "#delete-game")
      refute has_element?(view, "#type-moves-form")

      {:ok, view, _html} = live(arbiter, ~p"/round/1/board/1")
      assert has_element?(view, "#result-1-0")
      assert has_element?(view, "#type-moves-form")
      refute has_element?(view, "#delete-game")
    end

    test "Results, Captures and Setup keep their buttons from a viewer", %{
      viewer: conn,
      arbiter: arbiter
    } do
      {:ok, view, _html} = live(conn, ~p"/outbox")
      refute has_element?(view, "#send-now")
      {:ok, view, _html} = live(arbiter, ~p"/outbox")
      assert has_element?(view, "#send-now")

      {:ok, view, _html} = live(conn, ~p"/setup/connections")
      refute has_element?(view, "#code-form")
      {:ok, view, _html} = live(arbiter, ~p"/setup/connections")
      assert has_element?(view, "#code-form")
      {:ok, view, _html} = live(arbiter, ~p"/setup/this-box")
      refute has_element?(view, "#box-form")
    end

    test "Live: no result buttons on a tile", %{viewer: conn, arbiter: arbiter} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "[id^=tile-result-]")
      {:ok, view, _html} = live(arbiter, ~p"/")
      assert has_element?(view, "[id^=tile-result-]")
    end
  end

  describe "the captures of a removed board" do
    test "belong to the hall's owner: an arbiter cannot open them", %{conn: conn} do
      owner = first_owner()
      arbiter = joined("arbiter@example.org", "arbiter")

      board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      play_on("FAKE1", board.id, ~w(e4 e5))
      Recorder.flush()
      [capture | _] = Enum.filter(Recorder.list(), &(&1.board_id == board.id))

      Boards.delete(board)
      assert Recorder.hall_of(board.id) == Halls.own_id()

      path = ~p"/files/capture/#{board.id}/#{capture.name}"
      assert conn |> log_in(owner) |> get(path) |> response(200)
      assert conn |> log_in(arbiter) |> get(path) |> response(404)

      {:ok, view, _html} = live(log_in(conn, owner), ~p"/recordings")
      key = "#{board.id}-#{Path.rootname(capture.name)}"
      assert has_element?(view, "#capture-#{key}")

      {:ok, view, _html} = live(log_in(conn, arbiter), ~p"/recordings")
      refute has_element?(view, "#capture-#{key}")
    end
  end

  describe "deleting a fair-play analysis" do
    setup %{conn: conn} do
      owner = first_owner()
      arbiter = joined("arbiter@example.org", "arbiter")
      tournament = Alnasl.Tournaments.default()
      insert_moves(tournament, 40, "id:1", "Some Player")
      %{conn: log_in(conn, owner), owner: owner, arbiter: arbiter, tournament: tournament}
    end

    test "leaves a frozen copy, an audit line, and an empty report", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, view, _html} = live(conn, ~p"/fair-play/#{tournament.id}")
      assert has_element?(view, "#fair-play-delete-form")
      refute has_element?(view, "#fair-play-snapshots")

      view
      |> form("#fair-play-delete-form", %{delete: %{reason: "player asked"}})
      |> render_submit()

      assert [%Snapshot{moves: 40, reason: "player asked", deleted_by: "owner@example.org"} = s] =
               Repo.all(Snapshot)

      assert [%{"name" => "Some Player", "counted" => 40}] = Snapshot.players(s)
      assert Repo.aggregate(Alnasl.FairPlay.Move, :count) == 0
      assert Repo.get_by(View, tournament_id: tournament.id, action: "delete_analysis")
      assert has_element?(view, "#fair-play-snapshot-#{s.id}", "player asked")
      assert has_element?(view, "#fair-play-snapshot-#{s.id}-players", "Some Player")
    end

    test "is the owner's: an arbiter has neither the panel nor the right", %{
      arbiter: arbiter,
      tournament: tournament,
      owner: owner
    } do
      scope = Alnasl.Accounts.scope(arbiter, Halls.own_id())
      assert {:error, :forbidden} = FairPlay.delete_analysis(scope, tournament, "x")
      assert Repo.aggregate(Snapshot, :count) == 0

      assert {:ok, _} =
               FairPlay.delete_analysis(
                 Alnasl.Accounts.scope(owner, Halls.own_id()),
                 tournament,
                 nil
               )

      assert {:error, :nothing} =
               FairPlay.delete_analysis(
                 Alnasl.Accounts.scope(owner, Halls.own_id()),
                 tournament,
                 nil
               )
    end

    test "the copy goes with the report's retention, not before", %{
      owner: owner,
      tournament: tournament
    } do
      {:ok, _} =
        FairPlay.delete_analysis(Alnasl.Accounts.scope(owner, Halls.own_id()), tournament, "r")

      assert Repo.aggregate(Snapshot, :count) == 1

      # A tournament with no games has no last round: its fair-play rows go at once.
      Alnasl.FairPlay.Retention.purge()
      assert Repo.aggregate(Snapshot, :count) == 0
    end
  end
end
