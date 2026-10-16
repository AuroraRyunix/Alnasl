defmodule AlnaslWeb.KeycloakAuthController do
  @moduledoc """
  "Sign in with 02cloud": `new/2` sends the browser to Keycloak with a fresh
  `state`, `callback/2` takes it back, exchanges the code, asks who it is,
  and hands that to `Alnasl.Accounts.keycloak_sign_in/2` - which signs in
  an account that exists, makes one only for an admin named by the
  deployment or for an invitation in hand, and otherwise says no.

  The way back is `/auth/keycloak/callback` on the address the browser
  used (`ALNASL_KEYCLOAK_REDIRECT_URI` when set), and it is kept in the
  session between the two, so the exchange names the same one Keycloak saw.
  """

  use AlnaslWeb, :controller

  require Logger

  alias Alnasl.{Accounts, Keycloak}
  alias AlnaslWeb.UserAuth

  def new(conn, _params) do
    if Keycloak.configured?() do
      state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      redirect_uri = Keycloak.redirect_uri(callback_url(conn))

      conn
      |> put_session(:keycloak_state, state)
      |> put_session(:keycloak_redirect_uri, redirect_uri)
      |> redirect(external: Keycloak.authorize_url(state, redirect_uri))
    else
      conn
      |> put_flash(:error, gettext("Signing in with 02cloud is not set up on this Alnasl."))
      |> redirect(to: ~p"/log-in")
    end
  end

  def callback(conn, %{"error" => _} = params) do
    detail = params["error_description"] || params["error"]

    conn
    |> clear()
    |> put_flash(:error, gettext("02cloud sign-in was cancelled (%{why}).", why: detail))
    |> redirect(to: ~p"/log-in")
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected = get_session(conn, :keycloak_state)
    redirect_uri = get_session(conn, :keycloak_redirect_uri)
    invitation = get_session(conn, :invitation)
    conn = clear(conn)

    if Keycloak.configured?() and is_binary(expected) and is_binary(redirect_uri) and
         Plug.Crypto.secure_compare(state, expected) do
      complete(conn, code, redirect_uri, invitation)
    else
      conn
      |> put_flash(
        :error,
        gettext("The 02cloud sign-in took too long or was opened twice. Try again.")
      )
      |> redirect(to: ~p"/log-in")
    end
  end

  def callback(conn, _params) do
    conn
    |> clear()
    |> put_flash(:error, gettext("02cloud answered with something incomplete. Try again."))
    |> redirect(to: ~p"/log-in")
  end

  defp complete(conn, code, redirect_uri, invitation) do
    with {:ok, %{"access_token" => token}} <- Keycloak.exchange_code(code, redirect_uri),
         {:ok, %{"sub" => sub} = claims} when is_binary(sub) <- Keycloak.fetch_userinfo(token),
         {:ok, user} <-
           Accounts.keycloak_sign_in(
             %{
               sub: sub,
               email: claims["email"],
               email_verified: claims["email_verified"] == true
             },
             invitation
           ) do
      conn
      |> delete_session(:invitation)
      |> UserAuth.log_in_user(user)
    else
      {:error, :no_account} ->
        conn
        |> put_flash(
          :error,
          gettext(
            "02cloud knows you, but there is no account here for that address. Alnasl is by invitation: ask for one."
          )
        )
        |> redirect(to: ~p"/log-in")

      {:error, :unverified} ->
        conn
        |> put_flash(
          :error,
          gettext("02cloud has not verified that address yet, so it cannot sign you in here.")
        )
        |> redirect(to: ~p"/log-in")

      other ->
        Logger.warning("02cloud sign-in failed: #{inspect(other)}")

        conn
        |> put_flash(
          :error,
          gettext("Signing in with 02cloud failed. Try again, or use your password.")
        )
        |> redirect(to: ~p"/log-in")
    end
  end

  defp clear(conn),
    do: conn |> delete_session(:keycloak_state) |> delete_session(:keycloak_redirect_uri)

  # The address the browser used: behind the tunnel the request arrives in
  # plain HTTP, and says so in `x-forwarded-proto`. A forged header only
  # changes an address Keycloak checks against its list anyway.
  defp callback_url(conn) do
    {scheme, port} =
      case get_req_header(conn, "x-forwarded-proto") do
        # Through a proxy: its own port, which is the scheme's.
        [proto | _] when proto in ["http", "https"] -> {proto, nil}
        _none -> {to_string(conn.scheme), conn.port}
      end

    port = if port in [nil, 80, 443], do: nil, else: port

    URI.to_string(%URI{
      scheme: scheme,
      host: conn.host,
      port: port,
      path: "/auth/keycloak/callback"
    })
  end
end
