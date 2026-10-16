defmodule AlnaslWeb.SessionController do
  @moduledoc """
  Signing in with an address and a password, signing out, and the sign-in
  link of the QR code on Setup (`Alnasl.Accounts.use_qr_token/1`).
  """

  use AlnaslWeb, :controller

  alias Alnasl.{Accounts, Keycloak, Log}
  alias AlnaslWeb.UserAuth

  def new(conn, _params) do
    if Accounts.login_required?() do
      render_form(conn, nil)
    else
      # A box with no accounts has nobody to sign in.
      redirect(conn, to: ~p"/")
    end
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        Log.add(:warn, "account.refused", %{from: conn.remote_ip |> :inet.ntoa() |> to_string()})

        conn
        |> put_status(:unauthorized)
        |> render_form(gettext("That address and password do not match an account here."))

      user ->
        UserAuth.log_in_user(conn, user)
    end
  end

  def create(conn, _params), do: redirect(conn, to: ~p"/log-in")

  def delete(conn, _params), do: UserAuth.log_out_user(conn)

  @doc "A phone that scanned the QR code: signed in once, within five minutes, as whoever made the code."
  def qr(conn, %{"token" => token} = params) do
    case Accounts.use_qr_token(token) do
      {:ok, user} ->
        UserAuth.log_in_user(conn, user, UserAuth.safe(params["to"]))

      :error ->
        conn
        |> put_flash(
          :error,
          gettext("That sign-in code is used or has run out. Make a new one on Setup.")
        )
        |> redirect(to: ~p"/log-in")
    end
  end

  defp render_form(conn, error) do
    render(conn, :new,
      form: Phoenix.Component.to_form(%{"email" => "", "password" => ""}, as: :user),
      error: error,
      keycloak?: Keycloak.configured?(),
      server?: Accounts.server?()
    )
  end
end
