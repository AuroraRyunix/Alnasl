defmodule AlnaslWeb.UxGapsTest do
  @moduledoc """
  The gaps of the 2026-10-21 audit (`docs/ux-gaps-2026-10-21.md`): removing
  a board that a bridge keeps reporting, a page that names a board someone
  else has removed, a table number that is not a number, renaming a board,
  a capture that is already gone, and the pages that used to end in two
  bare words.
  """

  use AlnaslWeb.SiteCase, async: false

  @moduletag :capture_log

  alias Alnasl.Bridges

  defp serve do
    {:ok, pid} =
      Bandit.start_link(plug: AlnaslWeb.Endpoint, port: 0, ip: :loopback, startup_log: false)

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp bridge_joined do
    dir = Path.join(System.tmp_dir!(), "alnasl-gaps-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    port = serve()
    start_supervised!({Arkab.Bridge, data_dir: dir, name: "hall", sources: [], web: false})
    {:ok, code} = Bridges.create_join()
    {:ok, _server_id} = Arkab.Bridge.join("http://127.0.0.1:#{port}/join/#{code.code}")
    [bridge] = Bridges.list()
    eventually(fn -> Bridges.live(bridge.id) end)
    bridge
  end

  describe "removing a board" do
    test "a bridge's board stays removed: the bridge is told to stop reporting it",
         %{conn: conn} do
      bridge = bridge_joined()

      :ok =
        Arkab.Bridge.Ports.add(%{
          "replay" => "test/fixtures/captures/real-06310-knight-moves.jsonl",
          "name" => "COM9",
          "speed" => 50
        })

      row = eventually(fn -> Enum.find(Bridges.rows(bridge), &(&1.port =~ "COM9")) end)
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert view |> element("#delete-#{row.id}") |> render() =~ "its bridge is told"

      html = view |> element("#delete-#{row.id}") |> render_click()
      assert html =~ "told to stop reporting it"
      assert Bridges.rows(bridge) == []

      # The bridge says what it reads once more; the board is not on it.
      Bridges.subscribe()
      {:ok, id} = Bridges.command(bridge.id, "resend")
      assert_receive {:bridges, {:reply, _bridge, ^id, true, nil}}, 5_000
      assert Bridges.rows(bridge) == []
    end

    test "a bridge that is not connected cannot be told, and the page says so", %{conn: conn} do
      {:ok, row} =
        Alnasl.Boards.create(%{
          name: "Far away",
          driver: "remote",
          port: "bridge-9999:COM1",
          enabled: false
        })

      {:ok, view, _html} = live(conn, ~p"/boards")
      html = view |> element("#delete-#{row.id}") |> render_click()

      assert html =~ "not connected"
      assert Alnasl.Boards.get(row.id) == nil
    end

    test "a board with a game in progress asks in plain words first", %{conn: conn} do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 3})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      play_on("FAKE1", board.id, ~w(e4 e5))

      {:ok, view, _html} = live(conn, ~p"/boards")
      assert view |> element("#delete-#{board.id}") |> render() =~ "A game is being played"

      view |> element("#delete-#{board.id}") |> render_click()
      assert Boards.get(board.id) == nil
      assert Games.sans(Games.get(1, 3)) == ~w(e4 e5)
    end

    test "a board someone else removed is said to be gone, not a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      for {event, params} <- [
            {"delete", %{"id" => "424242"}},
            {"toggle", %{"id" => "424242"}},
            {"flip", %{"id" => "424242"}},
            {"show_me", %{"id" => "424242"}},
            {"back_to_table", %{"id" => "424242"}},
            {"table", %{"board_id" => "424242", "table_no" => "3"}},
            {"link", %{"board_id" => "424242", "board_no" => "3"}},
            {"rename", %{"board_id" => "424242", "name" => "Ghost"}}
          ] do
        assert render_hook(view, event, params) =~ "That board is no longer there."
      end

      assert Process.alive?(view.pid)
    end
  end

  describe "a board's name and table" do
    setup %{conn: conn} do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
      {:ok, view, _html} = live(conn, ~p"/boards")
      %{board: board, view: view}
    end

    test "a board can be renamed", %{board: board, view: view} do
      assert has_element?(view, "#rename-form-#{board.id}")

      html =
        view
        |> form("#rename-form-#{board.id}", %{name: "  Board by the window  "})
        |> render_submit()

      assert html =~ "is now"
      assert Boards.get(board.id).name == "Board by the window"
      assert has_element?(view, "#board-#{board.id} .b-name b", "Board by the window")
    end

    test "an empty or very long name is refused and the old one stays", %{
      board: board,
      view: view
    } do
      html = view |> form("#rename-form-#{board.id}", %{name: "   "}) |> render_submit()
      assert html =~ "one to 60 characters"

      html =
        view
        |> form("#rename-form-#{board.id}", %{name: String.duplicate("x", 61)})
        |> render_submit()

      assert html =~ "one to 60 characters"
      assert Boards.get(board.id).name == "DGT FAKE1"
    end

    test "something that is not a table number is said so and changes nothing", %{
      board: board,
      view: view
    } do
      view |> form("#table-form-#{board.id}", %{table_no: "7"}) |> render_change()
      assert Boards.get(board.id).table_no == 7

      html = view |> form("#table-form-#{board.id}", %{table_no: "seven"}) |> render_change()
      assert html =~ "A table number is a number from 1 to 9999."
      assert Boards.get(board.id).table_no == 7

      view |> form("#table-form-#{board.id}", %{table_no: ""}) |> render_change()
      assert Boards.get(board.id).table_no == nil
    end
  end

  describe "a capture that is already gone" do
    test "Delete says so instead of doing nothing", %{conn: conn} do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      play_on("FAKE1", board.id, ~w(e4 e5))

      {:ok, view, _html} = live(conn, ~p"/recordings")
      view |> element("#refresh-captures") |> render_click()
      [capture | _] = Enum.filter(Alnasl.Recorder.list(), &(&1.board_id == board.id))
      key = "#{board.id}-#{Path.rootname(capture.name)}"
      Boards.stop(board)

      File.rm!(capture.path)
      html = view |> element("#delete-#{key}") |> render_click()
      assert html =~ "That capture is already gone."
    end
  end

  describe "pages that used to end" do
    test "a spent invitation has a way to sign in", %{conn: conn} do
      conn = get(conn, ~p"/invite/not-a-real-token")
      assert html_response(conn, 410) =~ ~s(id="invitation-gone-log-in")
    end

    test "not found and broken say so and lead back" do
      for template <- ["404", "500"] do
        html = Phoenix.Template.render_to_string(AlnaslWeb.ErrorHTML, template, "html", [])
        assert html =~ ~s(id="error-home")
        assert html =~ ~s(href="/")
      end
    end
  end
end
