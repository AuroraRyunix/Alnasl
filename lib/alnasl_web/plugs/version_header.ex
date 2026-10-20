defmodule AlnaslWeb.Plugs.VersionHeader do
  @moduledoc """
  `x-alnasl-version` on every answer to this machine, so that a second Mac
  app finding the port taken can tell its own version from an older server
  that was never stopped (`rel/macos/Launcher.swift`).

  Only for a peer on loopback and without a proxy header: the hall's network
  and anyone behind a tunnel are not told which version the box runs.
  """
  @behaviour Plug

  import Plug.Conn

  @header "x-alnasl-version"
  @proxy_headers ~w(x-forwarded-for forwarded x-real-ip cf-connecting-ip x-forwarded-host)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if loopback?(conn) and not Enum.any?(@proxy_headers, &(get_req_header(conn, &1) != [])) do
      put_resp_header(conn, @header, version())
    else
      conn
    end
  end

  @doc "The header's name."
  def header, do: @header

  defp version, do: :alnasl |> Application.spec(:vsn) |> to_string()

  defp loopback?(conn) do
    case get_peer_data(conn) do
      %{address: {127, _, _, _}} -> true
      %{address: {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      %{address: {0, 0, 0, 0, 0, 0xFFFF, a, _}} -> div(a, 256) == 127
      _other -> false
    end
  end
end
