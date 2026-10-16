defmodule AlnaslWeb.DoorController do
  @moduledoc """
  The two things that are plain requests rather than live pages: giving the
  PIN from another machine, and a person switching their language.
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

  @doc """
  A person's language, from the account menu: kept on the account when
  someone is signed in, in a cookie of this browser when nobody is. It
  changes nobody else's - the box's default is Setup's, for an admin. A
  POST, so no link a browser prefetches switches it.
  """
  def locale(conn, %{"locale" => locale} = params) when locale in ["en", "nl"] do
    conn =
      case conn.assigns[:current_scope] do
        %{user: %Alnasl.Accounts.User{} = user} ->
          {:ok, _user} = Alnasl.Accounts.set_locale(user, locale)
          conn

        _nobody ->
          put_resp_cookie(conn, AlnaslWeb.Hall.locale_cookie(), locale,
            max_age: 365 * 86_400,
            same_site: "Lax",
            http_only: true
          )
      end

    redirect(conn, to: AlnaslWeb.UserAuth.local_path(params["return_to"]))
  end

  def locale(conn, params),
    do: redirect(conn, to: AlnaslWeb.UserAuth.local_path(params["return_to"]))
end
