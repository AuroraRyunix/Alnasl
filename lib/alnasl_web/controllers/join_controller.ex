defmodule AlnaslWeb.JoinController do
  @moduledoc """
  `/join/<code>`: the one link a bridge needs (`Alnasl.Bridges`).

  `POST` is the bridge redeeming it - who it is in, its own key out, as
  JSON. A used, expired or unknown code is a 410 and nothing more; a bridge
  that speaks another version of the link is a 409. `GET` is somebody who
  scanned the code with a phone instead of the bridge: a page that says
  where it goes.
  """

  use AlnaslWeb, :controller

  alias Alnasl.Bridges

  def redeem(conn, %{"code" => code} = params) do
    identity = Map.take(params, ["v", "bridge", "name", "software"])

    case Bridges.redeem(code, identity) do
      {:ok, %{key: key}} ->
        json(conn, %{
          key: key,
          socket: "/bridge/link",
          server: Bridges.server_name(),
          # No logins or roles yet: whoever could show the link may make
          # the bridge forget its boards.
          owner: true
        })

      {:error, :version} ->
        conn |> put_status(409) |> json(%{error: "version"})

      {:error, :bad_request} ->
        conn |> put_status(400) |> json(%{error: "bad_request"})

      {:error, _used_or_expired} ->
        conn |> put_status(410) |> json(%{error: "used_or_expired"})
    end
  end

  def show(conn, %{"code" => code}), do: render(conn, :show, code: code)
end
