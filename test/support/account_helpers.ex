defmodule AlnaslWeb.AccountHelpers do
  @moduledoc """
  Accounts, halls and the server switch for tests: an account with a
  password, a hall with its own tournament, a role in it, a browser signed
  in, and the deployment settings (server, admins, 02cloud) put back after
  the test. Addresses are example.org's.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Alnasl.{Accounts, Halls, Repo}
  alias Alnasl.Accounts.User
  alias Alnasl.Halls.Hall

  @password "a long enough password"

  def password, do: @password

  @doc "An account (not an admin unless `admin: true`)."
  def user_fixture(email, attrs \\ %{}) do
    %User{admin: Map.get(attrs, :admin, false)}
    |> User.registration_changeset(%{"email" => email, "password" => @password})
    |> Repo.insert!()
  end

  @doc "The box's first account, the way Setup makes it: owner of the own hall, admin."
  def first_owner(email \\ "owner@example.org") do
    {:ok, user} = Accounts.create_first_owner(%{"email" => email, "password" => @password})
    user
  end

  @doc "A hall other than the box's own, with its own tournament."
  def hall_fixture(name) do
    hall = Repo.insert!(%Hall{name: name, own: false})
    Halls.local_tournament(hall)
    hall
  end

  def member(%Hall{} = hall, %User{} = user, role) do
    {:ok, _member} = Halls.put_member(hall, user, role)
    user
  end

  @doc "A browser signed in as `user`, looking at `hall` (or its first)."
  def log_in(conn, %User{} = user, hall \\ nil) do
    token = Accounts.generate_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> then(&if(hall, do: Plug.Conn.put_session(&1, :hall_id, hall.id), else: &1))
  end

  @doc "This Alnasl is the server instance (`ALNASL_NO_LOCAL_BOARDS=true`) for the test."
  def server_mode do
    put_env(:local_boards, false)
  end

  @doc "`ALNASL_ADMIN_EMAILS` for the test."
  def admin_emails(emails), do: put_env(:admin_emails, emails)

  @doc "02cloud set up for the test, answered by `Alnasl.KeycloakStub` and never by the real one."
  def keycloak_on do
    put_env(:keycloak,
      issuer: "https://auth.example.org/realms/zerotwo",
      client_id: "alnasl",
      client_secret: "test-secret",
      redirect_uri: nil
    )
  end

  @doc "Keycloak, in the stub: the token endpoint gives a token, userinfo says `claims`."
  def keycloak_says(claims) do
    Req.Test.stub(Alnasl.KeycloakStub, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/token") ->
          Req.Test.json(conn, %{"access_token" => "at-1", "token_type" => "Bearer"})

        String.ends_with?(conn.request_path, "/userinfo") ->
          Req.Test.json(conn, claims)
      end
    end)
  end

  @doc "Any other `:alnasl` setting for the test (`:lan_addresses`, say)."
  def put_app_env(key, value), do: put_env(key, value)

  defp put_env(key, value) do
    before = Application.fetch_env(:alnasl, key)
    Application.put_env(:alnasl, key, value)

    on_exit(fn ->
      case before do
        {:ok, old} -> Application.put_env(:alnasl, key, old)
        :error -> Application.delete_env(:alnasl, key)
      end
    end)
  end
end
