defmodule AlnaslWeb.Plugs.LauncherStats do
  @moduledoc """
  `GET /_launcher/stats`, for the launcher's *Details* panel and
  `alnasl.sh details` and for nothing else. See `Alnasl.LauncherDetails` and
  `docs/launcher-details.md`.

  Answered only when all three hold, and a 404 like any missing page
  otherwise - no hint which of them failed:

    1. the peer is this machine, read from the socket and never from a
       forwarded header. The site itself may be open to the hall's network
       (`ALNASL_LISTEN=lan`); this is not;
    2. the request carries this start's secret in `x-launcher-token`;
    3. no proxy header is on it (`x-forwarded-for`, `forwarded`, `x-real-ip`,
       `cf-connecting-ip`, `x-forwarded-host`). The launcher and the terminal
       command talk to the socket directly. A box that somebody put behind a
       tunnel or a reverse proxy sees its public traffic arrive from
       loopback, with one of those headers; that traffic gets a 404 even if
       it somehow had the secret.

  There is no "hosted" Alnasl to exclude: the box is an appliance, and where
  the secret does not exist (`config :alnasl, launcher_details: false`, the
  tests) the answer is always 404.

  It sits in the endpoint ahead of the request logger, so a panel left open
  for an afternoon does not write a log line every two seconds into the very
  log the panel is showing.
  """
  @behaviour Plug

  import Plug.Conn

  alias Alnasl.LauncherDetails
  alias Alnasl.LauncherDetails.Stats

  @path ["_launcher", "stats"]
  @proxy_headers ~w(x-forwarded-for forwarded x-real-ip cf-connecting-ip x-forwarded-host)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: @path} = conn, _opts) do
    if conn.method == "GET" and loopback?(conn) and not proxied?(conn) and
         LauncherDetails.authorized?(given_token(conn)) do
      conn = fetch_query_params(conn)

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, Phoenix.json_library().encode!(Stats.collect(conn.query_params["lang"])))
      |> halt()
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp given_token(conn) do
    case get_req_header(conn, LauncherDetails.header()) do
      [token | _] -> token
      [] -> nil
    end
  end

  defp proxied?(conn), do: Enum.any?(@proxy_headers, &(get_req_header(conn, &1) != []))

  defp loopback?(conn) do
    case get_peer_data(conn) do
      %{address: {127, _, _, _}} -> true
      %{address: {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      %{address: {0, 0, 0, 0, 0, 0xFFFF, a, _}} -> div(a, 256) == 127
      _other -> false
    end
  end
end
