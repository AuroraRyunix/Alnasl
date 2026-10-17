defmodule AlnaslWeb.BridgesTest do
  @moduledoc """
  Bridges from this end: a code that works once and not for long, a key
  that is only ever a hash here, the Setup panel with its link and QR code,
  commands down the link, and Remove from either side ending it for both.
  The bridge is a real Arkab bridge over a real socket; its boards are
  replays, never a serial port.
  """

  use AlnaslWeb.SiteCase, async: false

  # A bridge stopped at the end of a test aborts its socket, and the web
  # server says so in red. It is not news.
  @moduletag :capture_log

  alias Alnasl.Bridges
  alias Alnasl.Bridges.Bridge

  @identity %{"v" => 1, "bridge" => "uid-1", "name" => "hall", "software" => "arkab 0.1.0"}

  defp serve do
    {:ok, pid} =
      Bandit.start_link(plug: AlnaslWeb.Endpoint, port: 0, ip: :loopback, startup_log: false)

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp bridge_joined do
    dir = Path.join(System.tmp_dir!(), "alnasl-bridges-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    port = serve()
    start_supervised!({Arkab.Bridge, data_dir: dir, name: "hall", sources: [], web: false})
    {:ok, code} = Bridges.create_join()
    {:ok, server_id} = Arkab.Bridge.join("http://127.0.0.1:#{port}/join/#{code.code}")
    [bridge] = Bridges.list()
    eventually(fn -> Bridges.live(bridge.id) end)
    {bridge, server_id}
  end

  describe "the code" do
    test "works once, for fifteen minutes, and only the key's hash is kept" do
      now = ~U[2026-10-16 12:00:00Z]
      {:ok, join} = Bridges.create_join(now)
      assert join.code =~ ~r/^[2-9A-HJKMNP-Z]{3}-[2-9A-HJKMNP-Z]{4}$/

      assert {:ok, %{key: key, bridge: %Bridge{} = bridge}} =
               Bridges.redeem(join.code, @identity, DateTime.add(now, 60))

      refute bridge.key_hash =~ key
      assert {:ok, %Bridge{id: id}} = Bridges.authenticate("uid-1", key)
      assert id == bridge.id
      assert Bridges.authenticate("uid-1", "not the key") == {:error, :key}
      assert Bridges.authenticate("someone", key) == {:error, :key}

      assert Bridges.redeem(join.code, @identity, DateTime.add(now, 61)) ==
               {:error, :used_or_expired}

      {:ok, late} = Bridges.create_join(now)

      assert Bridges.redeem(late.code, @identity, DateTime.add(now, 15 * 60)) ==
               {:error, :used_or_expired}

      {:ok, other} = Bridges.create_join(now)
      assert Bridges.redeem(other.code, %{@identity | "v" => 99}, now) == {:error, :version}
    end

    test "a bridge removed here and joined again is the same row, with a new key" do
      {:ok, one} = Bridges.create_join()
      {:ok, %{key: old, bridge: bridge}} = Bridges.redeem(one.code, @identity)
      Bridges.remove(bridge)
      assert Bridges.list() == []
      assert Bridges.authenticate("uid-1", old) == {:error, :revoked}

      {:ok, two} = Bridges.create_join()
      {:ok, %{key: new, bridge: again}} = Bridges.redeem(two.code, @identity)
      assert again.id == bridge.id
      assert {:ok, _} = Bridges.authenticate("uid-1", new)
      assert Bridges.authenticate("uid-1", old) == {:error, :key}
    end

    test "the link answers a bridge in JSON and a browser in words", %{conn: conn} do
      {:ok, join} = Bridges.create_join()

      page = conn |> get("/join/#{join.code}") |> html_response(200)
      assert page =~ join.code

      answer =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/join/#{join.code}", Jason.encode!(@identity))
        |> json_response(200)

      assert %{"key" => _key, "socket" => "/bridge/link", "owner" => true} = answer

      assert build_conn()
             |> put_req_header("content-type", "application/json")
             |> post("/join/#{join.code}", Jason.encode!(@identity))
             |> json_response(410)
    end
  end

  describe "The hall page" do
    test "Add a bridge shows the link and its QR code; a bridge that joins is listed", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/halls/#{Alnasl.Halls.own_id()}")
      assert has_element?(view, "#bridge-none")

      view |> element("#bridge-add") |> render_click()
      assert has_element?(view, "#bridge-join-qr svg")
      link = view |> element("#bridge-join-link") |> render()
      assert link =~ "/join/"

      {bridge, _server_id} = bridge_joined()
      eventually_html(view, &(&1 =~ "bridge-#{bridge.id}-up"))
      assert has_element?(view, "#bridge-#{bridge.id}-remove")
    end
  end

  describe "the link" do
    test "a command goes down and its answer comes back" do
      {bridge, _server_id} = bridge_joined()
      Bridges.subscribe()
      assert Arkab.Bridge.recording?()

      {:ok, id} = Bridges.command(bridge.id, "record", %{on: false})
      assert_receive {:bridges, {:reply, _bridge, ^id, true, nil}}, 5_000
      refute Arkab.Bridge.recording?()

      assert Bridges.command(bridge.id, "launch_rockets") == {:error, :unknown_command}
    end

    test "a board the bridge reads gets a row of its own, named after where it is" do
      {bridge, _server_id} = bridge_joined()

      :ok =
        Arkab.Bridge.Ports.add(%{
          "replay" => "test/fixtures/captures/real-06310-knight-moves.jsonl",
          "name" => "COM9",
          "speed" => 50
        })

      row = eventually(fn -> Enum.find(Bridges.rows(bridge), &(&1.port =~ "COM9")) end)
      assert row.driver == "remote" and row.name == "hall COM9"
      eventually(fn -> Boards.snapshot(row.id).raw end)
    end

    test "Remove on the server ends it on the bridge" do
      {bridge, _server_id} = bridge_joined()
      Bridges.remove(Repo.get!(Bridge, bridge.id))
      eventually(fn -> Arkab.Bridge.Store.servers() == [] end)
    end

    test "Remove on the bridge ends it here, boards and all" do
      {bridge, server_id} = bridge_joined()
      {:ok, _row} = Bridges.board_row(bridge, "COM3")
      Arkab.Bridge.remove(server_id)
      eventually(fn -> Bridges.list() == [] end)
      assert Bridges.rows(bridge) == []
    end
  end
end
