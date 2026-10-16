defmodule AlnaslWeb.UserAuth do
  @moduledoc """
  Signing in and out, and the scope of a request (`current_scope`).

  The session holds the token of the session row (`Alnasl.Accounts`) and
  the hall the browser looked at last. A cookie of its own keeps the token
  for thirty days, so a phone in the hall stays signed in through a weekend
  without its browser having to stay open.

  Whether a request must be signed in at all is `AlnaslWeb.Hall.gate/2`'s
  question; this module only says who it is.
  """

  use AlnaslWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Alnasl.Accounts
  alias Alnasl.Accounts.{User, UserToken}

  @remember_cookie "_alnasl_remember"
  @remember_options [
    sign: true,
    max_age: UserToken.session_days() * 86_400,
    same_site: "Lax",
    http_only: true
  ]

  @doc "Puts `current_scope` on the request: the account signed in (or none) and its hall."
  def fetch_current_scope(conn, _opts) do
    {user, conn} = current_user(conn)
    assign(conn, :current_scope, Accounts.scope(user, get_session(conn, :hall_id)))
  end

  defp current_user(conn) do
    case get_session(conn, :user_token) do
      token when is_binary(token) ->
        {Accounts.get_user_by_session_token(token), conn}

      _none ->
        conn = fetch_cookies(conn, signed: [@remember_cookie])

        with token when is_binary(token) <- conn.cookies[@remember_cookie],
             %User{} = user <- Accounts.get_user_by_session_token(token) do
          {user, put_token(conn, token)}
        else
          _none -> {nil, conn}
        end
    end
  end

  @doc """
  Signs `user` in: a fresh session (nothing of the one before is kept but
  the PIN note and the hall), the token in the cookie, and off to where the
  browser was going - or to choosing a new password, when an admin gave a
  temporary one.
  """
  def log_in_user(conn, %User{} = user, to \\ nil) do
    token = Accounts.generate_session_token(user)
    return_to = to || get_session(conn, :user_return_to)
    hall_id = get_session(conn, :hall_id)

    conn
    |> renew()
    |> put_session(:hall_id, hall_id)
    |> put_token(token)
    |> put_resp_cookie(@remember_cookie, token, @remember_options)
    |> redirect(to: if(user.must_change_password, do: ~p"/account", else: safe(return_to)))
  end

  @doc "Signs out: the session row goes, every page of this browser is disconnected."
  def log_out_user(conn) do
    token = get_session(conn, :user_token)
    Accounts.delete_session_token(token)

    if live_socket_id = get_session(conn, :live_socket_id),
      do: AlnaslWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})

    conn
    |> renew()
    |> delete_resp_cookie(@remember_cookie, @remember_options)
    |> redirect(to: ~p"/log-in")
  end

  @doc "Disconnects the pages of the given sessions (a password changed, a temporary one given)."
  def disconnect_sessions(tokens) do
    for %{token: token} <- tokens,
        do: AlnaslWeb.Endpoint.broadcast(topic(token), "disconnect", %{})

    :ok
  end

  @doc "A place on this site to go back to; anything else is the front page."
  def safe(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//"), do: path, else: "/"
  end

  def safe(_none), do: "/"

  @doc """
  A path on this site to go back to, or `"/"`: a `return_to` from a form or
  a link. Stricter than `safe/1`: no scheme, no host, no backslash (which
  some browsers read as a slash, making `/\\evil.example` a host) and no
  control characters. Path and query survive; a fragment does not.
  """
  def local_path(path) when is_binary(path) do
    with "/" <> rest <- path,
         false <- String.starts_with?(rest, ["/", "\\"]),
         false <- String.contains?(path, "\\"),
         false <- String.match?(path, ~r/[\x00-\x1f\x7f]/),
         %URI{scheme: nil, host: nil, path: "/" <> _ = clean, query: query} <- URI.parse(path) do
      if query in [nil, ""], do: clean, else: clean <> "?" <> query
    else
      _other -> "/"
    end
  end

  def local_path(_none), do: "/"

  defp renew(conn) do
    delete_csrf_token()
    unlocked = get_session(conn, :unlocked)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> then(&if(unlocked, do: put_session(&1, :unlocked, unlocked), else: &1))
  end

  defp put_token(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, topic(token))
  end

  defp topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc "The account of a LiveView's session, if any."
  def session_user(session) do
    case session["user_token"] do
      token when is_binary(token) -> Accounts.get_user_by_session_token(token)
      _none -> nil
    end
  end
end
