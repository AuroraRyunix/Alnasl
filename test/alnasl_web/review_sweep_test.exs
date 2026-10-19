defmodule AlnaslWeb.ReviewSweepTest do
  @moduledoc """
  What the review of 2026-10-19 found, one test each: a changed role ends the
  pages that held the old one, the PIN is not for guessing, a bridge stays in
  its hall, a capture of a removed board is an admin's, an admin account is
  an admin's to invite, and the server does not knock on its own doors.
  """

  use AlnaslWeb.SiteCase, async: false

  @moduletag :capture_log

  import AlnaslWeb.AccountHelpers

  alias Alnasl.{Accounts, Boards, Bridges, DoorGuard, Halls, Http, Settings}
  alias AlnaslWeb.{Endpoint, UserAuth}

  describe "a changed membership (ALN-01)" do
    setup do
      owner = first_owner()
      hall = hall_fixture("Hall A")
      user = member(hall, user_fixture("arbiter@example.org"), "arbiter")
      bystander = member(hall, user_fixture("other@example.org"), "arbiter")

      Endpoint.subscribe(UserAuth.session_topic(Accounts.generate_session_token(user)))

      %{
        scope: Accounts.scope(owner, hall.id),
        hall: hall,
        user: user,
        bystander: bystander
      }
    end

    defp member_of(hall, user), do: Enum.find(Halls.members(hall), &(&1.user_id == user.id))

    test "demoting a member disconnects their pages", ctx do
      %{scope: scope, hall: hall, user: user} = ctx
      {:ok, _} = Halls.set_role(scope, hall, member_of(hall, user).id, "viewer")
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "removing a member disconnects their pages", ctx do
      %{scope: scope, hall: hall, user: user} = ctx
      {:ok, _} = Halls.set_role(scope, hall, member_of(hall, user).id, nil)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "changing somebody else's role leaves them alone", ctx do
      %{scope: scope, hall: hall, bystander: other} = ctx
      {:ok, _} = Halls.set_role(scope, hall, member_of(hall, other).id, "viewer")
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "deleting the hall disconnects its members", %{scope: scope, user: user} do
      hall = hall_fixture("Gone")
      member(hall, user, "viewer")
      {:ok, _} = Halls.delete(scope, hall)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end

  describe "the PIN (ALN-03)" do
    setup do
      DoorGuard.reset()
      Settings.set_pin("246810")
      on_exit(&DoorGuard.reset/0)
    end

    defp enter(conn, pin, ip \\ {203, 0, 113, 7}) do
      conn = %{conn | remote_ip: ip}

      conn
      |> get(~p"/unlock")
      |> recycle()
      |> Map.put(:remote_ip, ip)
      |> post(~p"/unlock", %{"pin" => pin})
    end

    test "after five wrong tries an address waits, even with the right PIN", %{conn: conn} do
      for _try <- 1..5, do: assert(response(enter(conn, "000000"), 401))

      throttled = enter(conn, "246810")
      assert response(throttled, 429) =~ "Too many wrong PINs"
      assert [_seconds] = get_resp_header(throttled, "retry-after")
    end

    test "another address is not held up by the first", %{conn: conn} do
      for _try <- 1..6, do: enter(conn, "000000")
      assert redirected_to(enter(conn, "246810", {203, 0, 113, 8}))
    end

    test "the wait doubles, and a right PIN clears the count" do
      ip = {198, 51, 100, 1}
      for _try <- 1..5, do: DoorGuard.failed(ip, 0)
      assert DoorGuard.check(ip, 0) == {:wait, 5}
      DoorGuard.failed(ip, 5)
      assert DoorGuard.check(ip, 5) == {:wait, 10}
      assert DoorGuard.check(ip, 15) == :ok
      DoorGuard.succeeded(ip)
      DoorGuard.failed(ip, 16)
      assert DoorGuard.check(ip, 16) == :ok
    end

    test "the box as a whole takes forty wrong tries a minute" do
      for n <- 1..40, do: DoorGuard.failed({10, 0, 0, n}, 0)
      assert {:wait, 60} = DoorGuard.check({10, 9, 9, 9}, 0)
      assert DoorGuard.check({10, 9, 9, 9}, 61) == :ok
    end

    test "an older, shorter PIN works and is flagged; a six-character one is not" do
      Settings.set_pin("2468")
      assert Settings.pin_valid?("2468")
      assert Settings.pin_short?()

      Settings.set_pin("246810")
      refute Settings.pin_short?()
    end

    test "Setup takes no new PIN shorter than six characters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/access")
      assert view |> form("#pin-form", door: %{pin: "12345"}) |> render_submit() =~ "at least 6"
      view |> form("#pin-form", door: %{pin: "123456"}) |> render_submit()
      assert Settings.pin_valid?("123456")
    end
  end

  describe "a bridge in a hall (ALN-05)" do
    @identity %{"v" => 1, "bridge" => "uid-x", "name" => "hall", "software" => "arkab"}

    test "a code of another hall does not take a bridge that is still in its hall" do
      first_owner()
      a = hall_fixture("Hall A")
      b = hall_fixture("Hall B")
      {:ok, one} = Bridges.create_join(DateTime.utc_now(:second), a.id)
      {:ok, %{key: key, bridge: bridge}} = Bridges.redeem(one.code, @identity)

      {:ok, two} = Bridges.create_join(DateTime.utc_now(:second), b.id)
      assert Bridges.redeem(two.code, @identity) == {:error, :elsewhere}

      # Nothing moved, the key is the old one, and the code is still good.
      assert Bridges.get(bridge.id).hall_id == a.id
      assert {:ok, _} = Bridges.authenticate("uid-x", key)
      assert Alnasl.Repo.get_by(Bridges.Join, code: two.code).used_at == nil

      # Its own hall may let it join again; removed, it may go to another.
      {:ok, three} = Bridges.create_join(DateTime.utc_now(:second), a.id)
      assert {:ok, _} = Bridges.redeem(three.code, @identity)
      Bridges.remove(Bridges.get(bridge.id))
      assert {:ok, %{bridge: moved}} = Bridges.redeem(two.code, @identity)
      assert moved.hall_id == b.id
    end

    test "the link answers a bridge from another hall with a 403", %{conn: conn} do
      first_owner()
      a = hall_fixture("Hall A")
      b = hall_fixture("Hall B")
      {:ok, one} = Bridges.create_join(DateTime.utc_now(:second), a.id)
      {:ok, _} = Bridges.redeem(one.code, @identity)
      {:ok, two} = Bridges.create_join(DateTime.utc_now(:second), b.id)

      assert conn
             |> put_req_header("content-type", "application/json")
             |> post("/join/#{two.code}", Jason.encode!(@identity))
             |> json_response(403) == %{"error" => "elsewhere"}
    end
  end

  describe "captures of a removed board (ALN-07)" do
    test "an arbiter of another hall cannot delete them, an admin can", %{conn: conn} do
      admin = first_owner()
      hall = hall_fixture("Hall A")
      arbiter = member(hall, user_fixture("arbiter@example.org"), "arbiter")

      {:ok, board} =
        Boards.create(%{name: "X", driver: "remote", port: "bridge-0:x", hall_id: hall.id})

      dir = Path.join(Alnasl.Paths.captures(), "board-#{board.id}")
      File.mkdir_p!(dir)
      file = Path.join(dir, "2026-10-19.jsonl")
      File.write!(file, ~s({"t":0,"k":"note","text":"x"}\n))
      Boards.delete(Boards.get!(board.id))

      params = %{"board" => "#{board.id}", "name" => "2026-10-19.jsonl"}

      {:ok, view, _html} = live(log_in(conn, arbiter, hall), ~p"/recordings")
      render_hook(view, "delete", params)
      assert File.exists?(file)

      {:ok, view, _html} = live(log_in(build_conn(), admin, hall), ~p"/recordings")
      render_hook(view, "delete", params)
      refute File.exists?(file)
    end
  end

  describe "the declared admin (ALN-08)" do
    test "a hall owner cannot invite the declared admin's address, on a box either" do
      owner = first_owner()
      hall = hall_fixture("Hall A")
      boss = member(hall, user_fixture("owner2@example.org"), "owner")
      admin_emails(["root@example.org"])

      scope = Accounts.scope(boss, hall.id)
      assert Accounts.invite(scope, hall, "root@example.org", "owner") == {:error, :admin_only}
      assert {:ok, _token} = Accounts.invite(scope, hall, "someone@example.org", "viewer")

      # An admin may.
      assert {:ok, _token} =
               Accounts.invite(Accounts.scope(owner, hall.id), hall, "root@example.org", "owner")
    end

    test "an invitation made before the rule does not make the admin's account" do
      first_owner()
      hall = hall_fixture("Hall A")
      boss = member(hall, user_fixture("owner2@example.org"), "owner")
      scope = Accounts.scope(boss, hall.id)
      {:ok, token} = Accounts.invite(scope, hall, "root@example.org", "owner")
      admin_emails(["root@example.org"])

      assert Accounts.register_with_invitation(token, %{"password" => "a long enough password"}) ==
               {:error, :used_or_expired}
    end
  end

  describe "taking over a tournament with a code (ALN-06)" do
    import Alnasl.LinkHelpers

    alias Alnasl.{FakeOpenPairings, OpenPairings, Repo}
    alias Alnasl.Tournaments.Link

    test "using a code for a tournament of another hall needs a role in that hall" do
      pairing_program()
      first_owner()
      a = hall_fixture("Hall A")
      b = hall_fixture("Hall B")
      arbiter = member(a, user_fixture("arbiter@example.org"), "arbiter")

      FakeOpenPairings.add_tournament(17, name: "Open", boards: 2)
      {:ok, _link, [theirs]} = OpenPairings.add_code(FakeOpenPairings.code(17), b.id)

      noted = Jason.encode!(%{"17" => %{"tournament_id" => theirs.id, "name" => "Open"}})

      mine =
        Repo.insert!(%Link{
          root: "http://elsewhere.test/api/boards/v1",
          secret: "oplt_x",
          kind: "tournament",
          hall_id: a.id,
          elsewhere: noted
        })

      scope = Accounts.scope(arbiter, a.id)
      params = %{"id" => to_string(mine.id), "remote" => "17"}
      refute AlnaslWeb.Permit.allowed?(scope, AlnaslWeb.SetupLive, "use_code", params, %{})

      member(b, arbiter, "arbiter")
      scope = Accounts.scope(arbiter, a.id)
      assert AlnaslWeb.Permit.allowed?(scope, AlnaslWeb.SetupLive, "use_code", params, %{})
    end
  end

  describe "addresses on the hosted server (ALN-09)" do
    test "loopback, private, link-local and mapped addresses are internal" do
      for ip <- ~w(127.0.0.1 10.1.2.3 172.16.0.1 172.31.255.1 192.168.1.1 169.254.169.254
                   100.64.0.1 0.0.0.0 ::1 :: fe80::1 fd00::1 ::ffff:10.0.0.1 ::ffff:127.0.0.1),
          do: assert(Http.forbidden_host?(ip), ip)

      for ip <- ~w(93.184.216.34 8.8.8.8 172.32.0.1 2606:4700:4700::1111),
          do: refute(Http.forbidden_host?(ip), ip)
    end

    test "on the server a request to such a host is refused before it is made" do
      server_mode()

      request =
        Http.request(
          url: "http://127.0.0.1:9/api/server",
          plug: fn _conn -> flunk("the request was sent") end
        )

      assert {:error, %Req.TransportError{reason: :forbidden_address}} = Req.get(request)
    end

    test "on a box the same host is allowed (a desktop copy is at 127.0.0.1)" do
      request =
        Http.request(
          url: "http://127.0.0.1:9/api/server",
          plug: fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end
        )

      assert {:ok, %{status: 200}} = Req.get(request)
    end
  end
end
