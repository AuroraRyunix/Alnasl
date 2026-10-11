defmodule AlnaslWeb.DoorController do
  @moduledoc """
  The two things that are plain requests rather than live pages: giving the
  PIN from another machine, and switching the language.
  """

  use AlnaslWeb, :controller

  alias Alnasl.{Log, Settings}

  def unlock(conn, _params) do
    if (get_session(conn, :local) or get_session(conn, :unlocked)) || not Settings.pin_set?() do
      redirect(conn, to: ~p"/")
    else
      render(conn, :unlock, error: nil)
    end
  end

  def enter(conn, %{"pin" => pin}) do
    if Settings.pin_valid?(pin) do
      Log.add(:info, "door.unlocked", %{from: conn.remote_ip |> :inet.ntoa() |> to_string()})
      conn |> put_session(:unlocked, true) |> redirect(to: ~p"/")
    else
      Log.add(:warn, "door.refused", %{from: conn.remote_ip |> :inet.ntoa() |> to_string()})
      conn |> put_status(:unauthorized) |> render(:unlock, error: gettext("That is not the PIN."))
    end
  end

  def enter(conn, _params), do: redirect(conn, to: ~p"/unlock")

  def lock(conn, _params) do
    conn |> delete_session(:unlocked) |> redirect(to: ~p"/unlock")
  end

  @doc "The language is the box's, not the browser's: one arbiter, one box."
  def locale(conn, %{"locale" => locale}) when locale in ["en", "nl"] do
    Settings.put("locale", locale)

    back =
      case get_req_header(conn, "referer") do
        [referer | _] -> URI.parse(referer).path || "/"
        [] -> "/"
      end

    redirect(conn,
      to:
        if(String.starts_with?(back, "/") and not String.starts_with?(back, "//"),
          do: back,
          else: "/"
        )
    )
  end

  def locale(conn, _params), do: redirect(conn, to: ~p"/")
end
