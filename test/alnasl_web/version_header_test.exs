defmodule AlnaslWeb.VersionHeaderTest do
  @moduledoc """
  `x-alnasl-version` (`AlnaslWeb.Plugs.VersionHeader`): the Mac app's way to
  tell its own version from an old server on the port. Loopback only.
  """
  use AlnaslWeb.ConnCase, async: true

  @version :alnasl |> Application.spec(:vsn) |> to_string()

  test "a loopback peer is told the version", %{conn: conn} do
    conn = get(conn, "/help")
    assert get_resp_header(conn, "x-alnasl-version") == [@version]
  end

  test "another machine is not", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.put_peer_data(%{address: {192, 168, 1, 23}, port: 50_000, ssl_cert: nil})
      |> get("/help")

    assert get_resp_header(conn, "x-alnasl-version") == []
  end

  test "a proxied request is not", %{conn: conn} do
    conn = conn |> put_req_header("x-forwarded-for", "203.0.113.9") |> get("/help")
    assert get_resp_header(conn, "x-alnasl-version") == []
  end
end
