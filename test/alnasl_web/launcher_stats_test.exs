defmodule AlnaslWeb.LauncherStatsTest do
  @moduledoc """
  `GET /_launcher/stats` (`AlnaslWeb.Plugs.LauncherStats`): a
  loopback peer, this start's secret and no proxy header, or a 404.
  """
  use AlnaslWeb.ConnCase, async: false

  @token "a-launcher-secret-for-this-test"

  setup do
    Application.put_env(:alnasl, :launcher_token, @token)
    on_exit(fn -> Application.delete_env(:alnasl, :launcher_token) end)
    :ok
  end

  defp ask(conn, token) do
    conn = if token, do: put_req_header(conn, "x-launcher-token", token), else: conn
    get(conn, "/_launcher/stats")
  end

  test "no secret, a wrong one, or an empty one: 404", %{conn: conn} do
    assert ask(conn, nil).status == 404
    assert ask(build_conn(), "not-the-secret").status == 404
    assert ask(build_conn(), "").status == 404
  end

  test "the secret from another machine: 404", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.put_peer_data(%{address: {192, 168, 1, 23}, port: 50_000, ssl_cert: nil})
      |> ask(@token)

    assert conn.status == 404
  end

  test "a forwarded header does not make a request local", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.put_peer_data(%{address: {10, 0, 0, 7}, port: 50_000, ssl_cert: nil})
      |> put_req_header("x-forwarded-for", "127.0.0.1")
      |> ask(@token)

    assert conn.status == 404
  end

  test "a proxy header on a loopback request: 404 (a tunnel in front of a desktop copy)" do
    for header <- ~w(x-forwarded-for forwarded x-real-ip cf-connecting-ip x-forwarded-host) do
      conn = build_conn() |> put_req_header(header, "203.0.113.9") |> ask(@token)
      assert conn.status == 404, header
    end
  end

  test "no secret made (details switched off): 404 even with a guess", %{conn: conn} do
    Application.delete_env(:alnasl, :launcher_token)
    assert ask(conn, @token).status == 404
  end

  test "anything but GET: 404", %{conn: conn} do
    conn = conn |> put_req_header("x-launcher-token", @token) |> post("/_launcher/stats", %{})
    assert conn.status == 404
  end

  test "with the secret: the documented shape", %{conn: conn} do
    conn = ask(conn, @token)
    assert conn.status == 200
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    # Nothing in the answer is a secret: not this start's, not a key.
    refute conn.resp_body =~ @token
    refute conn.resp_body =~ ~r/secret|password|api_key/i

    body = Jason.decode!(conn.resp_body)

    assert %{
             "app" => "alnasl",
             "version" => version,
             "uptime_s" => uptime,
             "started_at" => _,
             "system" => %{"os" => _, "arch" => _, "otp" => _, "cores" => _},
             "beam" => %{
               "memory_bytes" => %{"total" => total, "processes" => _, "ets" => _, "binary" => _},
               "processes" => processes,
               "schedulers" => schedulers,
               "run_queue" => _,
               "cpu_percent" => _
             },
             "database" => %{
               "size_bytes" => _,
               "ping_ms" => ping,
               "slow_queries" => slow,
               "slow_threshold_ms" => 100
             },
             "log" => %{"source" => _},
             "alnasl" => %{
               "live_views" => live_views,
               "tournaments" => tournaments,
               "boards" => boards,
               "boards_connected" => 0,
               "buses_open" => 0,
               "outbox_pending" => 0,
               "relay" => relay
             },
             "summary" => [_ | _] = summary
           } = body

    assert is_binary(version)
    assert is_integer(uptime) and is_integer(total) and is_integer(processes)
    assert is_integer(schedulers) and schedulers > 0
    assert is_number(ping) and ping >= 0
    assert is_list(slow)
    assert is_integer(live_views) and is_integer(tournaments) and is_integer(boards)
    assert is_binary(relay)

    for line <- summary do
      assert %{"label" => label, "value" => value} = line
      assert is_binary(label) and is_binary(value)
    end

    assert Enum.map(summary, & &1["label"]) == Alnasl.LauncherDetails.Stats.labels("en")
  end

  test "in Dutch when asked", %{conn: conn} do
    conn = conn |> put_req_header("x-launcher-token", @token) |> get("/_launcher/stats?lang=nl")
    labels = conn.resp_body |> Jason.decode!() |> Map.fetch!("summary") |> Enum.map(& &1["label"])
    assert labels == Alnasl.LauncherDetails.Stats.labels("nl")
    assert "Versie" in labels
  end
end
