defmodule AlnaslWeb.AccountsTest do
  @moduledoc """
  The door, once there is one: a box without accounts as open as it was,
  the first account closing it for every page (the box's own screen too),
  the phone's sign-in code good once and briefly, the server shut to
  everybody not signed in, and the two ways in there - an admin named by
  the deployment, or an invitation - with 02cloud answered by a stub.
  """

  use AlnaslWeb.SiteCase, async: false

  import AlnaslWeb.AccountHelpers

  alias Alnasl.{Accounts, Halls}
  alias Alnasl.Accounts.{User, UserToken}

  describe "a box without accounts" do
    test "is open as before: pages, Setup's first-account form, no sign-in page", %{conn: conn} do
      refute Accounts.login_required?()
      {:ok, view, _html} = live(conn, ~p"/boards")
      refute has_element?(view, "#account-link")

      {:ok, view, _html} = live(conn, ~p"/setup")
      assert has_element?(view, "#first-account-form")
      assert has_element?(view, "#bridge-add")

      assert redirected_to(get(build_conn(), ~p"/log-in")) == "/"
    end

    test "the first account switches the sign-in on for every page", %{conn: conn} do
      conn =
        post(conn, ~p"/accounts/first", %{
          "user" => %{"email" => "owner@example.org", "password" => password()}
        })

      assert redirected_to(conn) == "/halls"

      [user] = Accounts.list_users()
      assert user.admin
      assert Halls.roles(user) == %{Halls.own_id() => "owner"}

      # Signed in: in. The box's own screen, not signed in: out.
      {:ok, _view, _html} = live(recycle(conn), ~p"/boards")
      assert {:error, {:redirect, %{to: "/log-in"}}} = live(build_conn(), ~p"/boards")
      assert redirected_to(get(build_conn(), ~p"/files/labels")) == "/log-in"
      assert html_response(get(build_conn(), ~p"/log-in"), 200) =~ "log-in-form"
    end

    test "a second first account is refused", %{conn: conn} do
      first_owner()

      conn =
        post(conn, ~p"/accounts/first", %{
          "user" => %{"email" => "late@example.org", "password" => password()}
        })

      assert response(conn, 403)
      assert length(Accounts.list_users()) == 1
    end

    test "signing in with the password, and a wrong one", %{conn: conn} do
      first_owner()

      wrong =
        post(conn, ~p"/log-in", %{
          "user" => %{"email" => "owner@example.org", "password" => "nope"}
        })

      assert html_response(wrong, 401) =~ "log-in-error"

      right =
        post(build_conn(), ~p"/log-in", %{
          "user" => %{"email" => "owner@example.org", "password" => password()}
        })

      assert redirected_to(right) == "/"
      assert get_session(right, :user_token)
    end
  end

  describe "the phone's sign-in code" do
    test "Setup makes one, and it signs a phone in once", %{conn: conn} do
      put_app_env(:lan_addresses, ["192.0.2.10"])
      owner = first_owner()
      {:ok, view, _html} = live(log_in(conn, owner), ~p"/setup")

      refute has_element?(view, "#setup-phone-access-qr")
      view |> element("#setup-phone-access-signin") |> render_click()
      assert has_element?(view, "#setup-phone-access-signin-expiry")
      assert has_element?(view, "#setup-phone-access-qr svg")

      [row] = Alnasl.Repo.all(from t in UserToken, where: t.context == "qr")
      assert row.user_id == owner.id

      # The token itself is only in the link: take it from a fresh one.
      token = Accounts.create_qr_token(owner)
      phone = get(build_conn(), ~p"/log-in/qr/#{token}?to=/boards/number")
      assert redirected_to(phone) == "/boards/number"
      assert get_session(phone, :user_token)

      again = get(build_conn(), ~p"/log-in/qr/#{token}")
      assert redirected_to(again) == "/log-in"
      refute get_session(again, :user_token)
    end

    test "runs out after five minutes" do
      owner = first_owner()
      token = Accounts.create_qr_token(owner)
      old = DateTime.add(DateTime.utc_now(:second), -6 * 60)

      Alnasl.Repo.update_all(from(t in UserToken, where: t.context == "qr"),
        set: [inserted_at: old]
      )

      assert Accounts.use_qr_token(token) == :error
      assert redirected_to(get(build_conn(), ~p"/log-in/qr/#{token}")) == "/log-in"
    end
  end

  describe "the server" do
    setup do
      server_mode()
      :ok
    end

    test "turns away everything not signed in, the loopback address included", %{conn: conn} do
      assert Accounts.login_required?()

      for path <- [
            "/",
            "/boards",
            "/setup",
            "/halls",
            "/log",
            "/files/labels",
            "/round/1/board/1"
          ] do
        assert redirected_to(get(conn, path)) == "/log-in", path
      end

      assert {:error, {:redirect, %{to: "/log-in"}}} = live(conn, ~p"/outbox")
      assert html_response(get(conn, ~p"/log-in"), 200) =~ "log-in-invitation-only"

      assert response(
               post(conn, ~p"/accounts/first", %{
                 "user" => %{"email" => "x@example.org", "password" => password()}
               }),
               403
             )
    end

    test "an admin named by the deployment gets an account at the first 02cloud sign-in", %{
      conn: conn
    } do
      admin_emails(["admin@example.org"])
      keycloak_on()

      keycloak_says(%{
        "sub" => "kc-admin",
        "email" => "Admin@example.org",
        "email_verified" => true
      })

      conn = get(conn, ~p"/auth/keycloak")

      assert redirected_to(conn) =~
               "https://auth.example.org/realms/zerotwo/protocol/openid-connect/auth?"

      state = get_session(conn, :keycloak_state)

      back = get(recycle(conn), ~p"/auth/keycloak/callback?code=c-1&state=#{state}")
      assert redirected_to(back) == "/"

      user = Accounts.get_user_by_email("admin@example.org")
      assert %User{keycloak_sub: "kc-admin"} = user
      assert Accounts.admin?(user)

      {:ok, view, _html} = live(recycle(back), ~p"/halls")
      assert has_element?(view, "#hall-new-form")
    end

    test "02cloud alone gets nobody else in", %{conn: conn} do
      admin_emails(["admin@example.org"])
      keycloak_on()

      keycloak_says(%{
        "sub" => "kc-other",
        "email" => "someone@example.org",
        "email_verified" => true
      })

      conn = get(conn, ~p"/auth/keycloak")
      state = get_session(conn, :keycloak_state)
      back = get(recycle(conn), ~p"/auth/keycloak/callback?code=c-1&state=#{state}")

      assert redirected_to(back) == "/log-in"
      refute get_session(back, :user_token)
      assert Accounts.list_users() == []
    end

    test "an unverified address does not link, even an admin's", %{conn: conn} do
      admin_emails(["admin@example.org"])
      keycloak_on()

      keycloak_says(%{
        "sub" => "kc-admin",
        "email" => "admin@example.org",
        "email_verified" => false
      })

      conn = get(conn, ~p"/auth/keycloak")
      state = get_session(conn, :keycloak_state)
      back = get(recycle(conn), ~p"/auth/keycloak/callback?code=c-1&state=#{state}")

      assert redirected_to(back) == "/log-in"
      assert Accounts.list_users() == []
    end

    test "a callback with someone else's state is refused", %{conn: conn} do
      keycloak_on()
      conn = get(conn, ~p"/auth/keycloak")
      back = get(recycle(conn), ~p"/auth/keycloak/callback?code=c-1&state=forged")
      assert redirected_to(back) == "/log-in"
    end

    test "an invitation is good once, by password", %{conn: conn} do
      admin = user_fixture("admin@example.org")
      admin_emails(["admin@example.org"])
      hall = hall_fixture("Annex")
      {:ok, token} = Accounts.invite(Accounts.scope(admin), hall, "new@example.org", "arbiter")

      assert html_response(get(conn, ~p"/invite/#{token}"), 200) =~ "invitation-form"

      made =
        post(build_conn(), ~p"/invite/#{token}", %{
          "user" => %{"email" => "ignored@example.org", "password" => password()}
        })

      assert redirected_to(made) == "/halls/#{hall.id}/enter"
      user = Accounts.get_user_by_email("new@example.org")
      assert Halls.roles(user) == %{hall.id => "arbiter"}

      assert response(get(build_conn(), ~p"/invite/#{token}"), 410)

      assert response(
               post(build_conn(), ~p"/invite/#{token}", %{"user" => %{"password" => password()}}),
               410
             )

      assert length(Accounts.list_users()) == 2
    end

    test "an invitation is good once, by 02cloud", %{conn: conn} do
      admin = user_fixture("admin@example.org")
      admin_emails(["admin@example.org"])
      keycloak_on()
      hall = hall_fixture("Annex")
      {:ok, token} = Accounts.invite(Accounts.scope(admin), hall, "guest@example.org", "viewer")

      keycloak_says(%{
        "sub" => "kc-guest",
        "email" => "guest@example.org",
        "email_verified" => true
      })

      conn = get(conn, ~p"/invite/#{token}")
      conn = get(recycle(conn), ~p"/auth/keycloak")
      state = get_session(conn, :keycloak_state)
      back = get(recycle(conn), ~p"/auth/keycloak/callback?code=c-1&state=#{state}")

      refute redirected_to(back) == "/log-in"
      user = Accounts.get_user_by_email("guest@example.org")
      assert Halls.roles(user) == %{hall.id => "viewer"}
      assert Accounts.get_invitation(token) == nil
    end

    test "on the server only an admin invites an address with no account", %{conn: _conn} do
      admin_emails(["admin@example.org"])
      owner = user_fixture("owner@example.org")
      hall = hall_fixture("Annex")
      member(hall, owner, "owner")
      existing = user_fixture("arbiter@example.org")

      scope = Accounts.scope(owner, hall.id)

      assert Accounts.invite(scope, hall, "stranger@example.org", "viewer") ==
               {:error, :admin_only}

      assert {:ok, _token} = Accounts.invite(scope, hall, existing.email, "arbiter")
    end

    test "a temporary password from an admin asks for a new one at sign-in", %{conn: conn} do
      admin = user_fixture("admin@example.org")
      admin_emails(["admin@example.org"])
      hall = hall_fixture("Annex")
      someone = member(hall, user_fixture("someone@example.org"), "arbiter")

      {:ok, view, _html} = live(log_in(conn, admin, hall), ~p"/halls/#{hall.id}")
      [m] = Halls.members(hall)
      view |> element("#member-#{m.id}-temporary") |> render_click()

      password =
        view
        |> element("#hall-temporary b")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      signed =
        post(build_conn(), ~p"/log-in", %{
          "user" => %{"email" => someone.email, "password" => password}
        })

      assert redirected_to(signed) == "/account"
      assert redirected_to(get(recycle(signed), ~p"/boards")) == "/account"
    end
  end
end
