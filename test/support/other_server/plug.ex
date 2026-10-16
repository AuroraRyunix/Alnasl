defmodule Alnasl.OtherServer.Plug do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  def init(agent), do: agent

  def call(%{method: "POST", path_info: ["join", "OTHER"]} = conn, _agent) do
    body =
      Jason.encode!(%{key: "other-key", socket: "/bridge/link", server: "other", owner: false})

    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  def call(%{method: "GET", path_info: ["bridge", "link"]} = conn, agent) do
    conn
    |> WebSockAdapter.upgrade(Alnasl.OtherServer.Socket, agent, timeout: 120_000)
    |> halt()
  end

  def call(conn, _agent), do: send_resp(conn, 404, "")
end
