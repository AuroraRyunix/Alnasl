defmodule AlnaslWeb.OpenPairingsConnectControllerTest do
  @moduledoc """
  "Connect an OpenPairings account": out to OpenPairings' consent page with
  a `state` this browser keeps, back with a grant that is traded for a code
  once, and the code added to the hall the button was pressed in. And the
  ways it does not happen: a role too small, a `state` not ours, Cancel, a
  grant used or run out, a server that does not answer.
  """

  use AlnaslWeb.SiteCase, async: false

  @moduletag :capture_log

  import Alnasl.LinkHelpers
  import AlnaslWeb.AccountHelpers

  alias Alnasl.{FakeOpenPairings, Halls, Settings, Tournaments}
  alias Alnasl.OpenPairings.Connect

  @address "http://pairings.test"

  setup do
    pairing_program()
  end

  defp start(conn, address \\ @address),
    do: post(conn, ~p"/setup/openpairings/connect", %{"connect" => %{"address" => address}})

  defp query(conn) do
    %URI{query: query} = conn |> redirected_to() |> URI.parse()
    URI.decode_query(query)
  end

  # Out to OpenPairings and back: the browser keeps its session cookie.
  defp round_trip(conn, answer) do
    out = start(conn)
    state = query(out)["state"]
    get(recycle(out), ~p"/setup/openpairings/callback", Map.put(answer, "state", state))
  end

  defp flash_error(conn), do: Phoenix.Flash.get(conn.assigns.flash, :error)

  describe "the way out" do
    test "sends the browser to the consent page with a way back, a state and the box's name",
         %{conn: conn} do
      out = start(conn, "  pairings.test/api/boards/v1/ ")
      location = redirected_to(out)

      assert String.starts_with?(location, "https://pairings.test/boards/connect?")
      params = query(out)
      assert params["return_to"] == "http://www.example.com/setup/openpairings/callback"
      assert params["box"] =~ ~r/\AAlnasl - /
      assert byte_size(params["state"]) >= 40

      assert %{"state" => state} = get_session(out, :openpairings_connect)
      assert state == params["state"]

      # Remembered for next time.
      assert Connect.default_address() == "https://pairings.test"
    end

    test "behind the tunnel the way back is the public https address", %{conn: conn} do
      out = conn |> put_req_header("x-forwarded-proto", "https") |> start()
      assert query(out)["return_to"] == "https://www.example.com/setup/openpairings/callback"
    end

    test "not an address: said, and nowhere to go", %{conn: conn} do
      out = start(conn, "ftp://pairings.test")
      assert redirected_to(out) == ~p"/setup/connections"
      assert flash_error(out) =~ "not the address of an OpenPairings"
    end

    test "a viewer of the hall is refused on the way out", %{conn: conn} do
      first_owner()
      hall = hall_fixture("Hall A")
      viewer = member(hall, user_fixture("viewer@example.org"), "viewer")

      out = conn |> log_in(viewer, hall) |> start()
      assert redirected_to(out) == ~p"/setup/connections"
      assert flash_error(out) =~ "follow the games"
      assert get_session(out, :openpairings_connect) == nil
    end
  end

  describe "the way back" do
    test "a grant becomes an account link in the hall, listed with its count", %{conn: conn} do
      FakeOpenPairings.add_tournament(17, boards: 2, name: "Open")
      FakeOpenPairings.add_tournament(18, boards: 2, name: "Rapid")
      code = FakeOpenPairings.account_code([17, 18])
      grant = FakeOpenPairings.grant(code)

      back = round_trip(conn, %{"grant" => grant})
      assert redirected_to(back) == ~p"/setup/connections"
      assert Phoenix.Flash.get(back.assigns.flash, :info) =~ "Connected"

      assert [link] = Tournaments.links()
      assert link.kind == "account"
      assert link.hall_id == Halls.own_id()
      assert Enum.map(Tournaments.of_link(link), & &1.remote_id) == [17, 18]

      {:ok, _view, html} = live(build_conn(), ~p"/setup/connections")
      assert html =~ "All your tournaments on pairings.test (2)"

      # The grant was good once.
      assert {:error, :expired} = Connect.redeem(@address, grant)
    end

    test "a state that is not this browser's is refused, and nothing is traded", %{conn: conn} do
      code = FakeOpenPairings.account_code([])
      grant = FakeOpenPairings.grant(code)

      out = start(conn)

      back =
        get(recycle(out), ~p"/setup/openpairings/callback", %{
          "grant" => grant,
          "state" => "someone-elses"
        })

      assert flash_error(back) =~ "does not belong"
      assert Tournaments.links() == []
      assert FakeOpenPairings.requests("POST", "/grant") == []

      # Without any connection started at all.
      again = get(build_conn(), ~p"/setup/openpairings/callback", %{"grant" => grant})
      assert flash_error(again) =~ "does not belong"
    end

    test "the state is good once", %{conn: conn} do
      out = start(conn)
      state = query(out)["state"]

      first =
        get(recycle(out), ~p"/setup/openpairings/callback", %{
          "error" => "denied",
          "state" => state
        })

      second =
        get(recycle(first), ~p"/setup/openpairings/callback", %{"grant" => "g", "state" => state})

      assert flash_error(second) =~ "does not belong"
    end

    test "Cancel at OpenPairings", %{conn: conn} do
      back = round_trip(conn, %{"error" => "denied"})
      assert flash_error(back) =~ "Cancelled in OpenPairings"
      assert Tournaments.links() == []
    end

    test "an account with every box slot taken", %{conn: conn} do
      back = round_trip(conn, %{"error" => "too_many_codes"})
      assert flash_error(back) =~ "already has 8 boxes"
    end

    test "a grant used or run out", %{conn: conn} do
      back = round_trip(conn, %{"grant" => "never-issued"})
      assert flash_error(back) =~ "good once and for two minutes"
      assert Tournaments.links() == []
    end

    test "OpenPairings not answering", %{conn: conn} do
      grant = FakeOpenPairings.grant(FakeOpenPairings.account_code([]))
      FakeOpenPairings.mode(:down)

      back = round_trip(conn, %{"grant" => grant})
      assert flash_error(back) =~ "cannot be reached"
      assert Tournaments.links() == []
    end
  end

  describe "the address" do
    test "what is typed or pasted, cut back to the server" do
      assert Connect.normalize("pairings.example.org") == {:ok, "https://pairings.example.org"}
      assert Connect.normalize("http://127.0.0.1:4000/") == {:ok, "http://127.0.0.1:4000"}

      assert Connect.normalize("https://p.example/api/boards/v1#oplt_abc") ==
               {:ok, "https://p.example"}

      assert Connect.normalize("") == {:error, :not_an_address}
      assert Connect.normalize("ftp://p.example") == {:error, :not_an_address}
      assert Connect.normalize("https://me:pw@p.example") == {:error, :not_an_address}
      assert Connect.normalize("https://p.example/?a=1") == {:error, :not_an_address}
    end

    test "offered: the last one used, else the configured one" do
      put_app_env(:openpairings_url, "https://configured.example")
      assert Connect.default_address() == "https://configured.example"
      Settings.put("openpairings_url", "https://used.example")
      assert Connect.default_address() == "https://used.example"
    end
  end
end
