defmodule AlnaslWeb.AccountController do
  @moduledoc """
  The first account of a box (from Setup), and an account's own page: who
  it is, its halls, and a new password.
  """

  use AlnaslWeb, :controller

  alias Alnasl.{Accounts, Halls}
  alias Alnasl.Accounts.User
  alias AlnaslWeb.{Hall, UserAuth}

  @doc """
  The first account: only on a box that has none, is not the server, and
  only from a browser that may use the box now (the box itself, the PIN
  given, or no PIN) - the one who can already change everything here.
  """
  def first(conn, %{"user" => attrs}) do
    may? =
      not Accounts.login_required?() and
        Hall.allowed?(get_session(conn, :local) == true, get_session(conn, :unlocked))

    if may? do
      case Accounts.create_first_owner(attrs) do
        {:ok, user} ->
          conn
          |> put_flash(
            :info,
            gettext("The box has an owner now. Every page asks who you are from here on.")
          )
          |> UserAuth.log_in_user(user, ~p"/halls")

        {:error, %Ecto.Changeset{} = changeset} ->
          message =
            changeset.errors
            |> Enum.map(fn {field, error} ->
              "#{field_name(field)}: #{AlnaslWeb.CoreComponents.translate_error(error)}"
            end)
            |> Enum.join("; ")

          conn
          |> put_flash(:error, message)
          |> redirect(to: ~p"/setup/access#setup-accounts")

        {:error, _taken} ->
          conn
          |> put_flash(:error, gettext("This box has an account already."))
          |> redirect(to: ~p"/log-in")
      end
    else
      conn |> put_status(:forbidden) |> text("Forbidden")
    end
  end

  def first(conn, _params), do: redirect(conn, to: ~p"/setup/access")

  def show(conn, _params) do
    case conn.assigns.current_scope do
      %{user: %User{} = user} = scope ->
        render_show(conn, scope, Accounts.change_user_password(user))

      _nobody ->
        redirect(conn, to: ~p"/log-in")
    end
  end

  def update_password(conn, %{"user" => attrs}) do
    case conn.assigns.current_scope do
      %{user: %User{} = user} = scope ->
        case Accounts.update_password(user, attrs) do
          {:ok, {user, tokens}} ->
            UserAuth.disconnect_sessions(tokens)

            conn
            |> put_flash(
              :info,
              gettext("Password changed. Other browsers signed in as you are signed out.")
            )
            |> UserAuth.log_in_user(user, ~p"/account")

          {:error, changeset} ->
            conn |> put_status(:unprocessable_entity) |> render_show(scope, changeset)
        end

      _nobody ->
        redirect(conn, to: ~p"/log-in")
    end
  end

  def update_password(conn, _params), do: redirect(conn, to: ~p"/account")

  defp field_name(:email), do: gettext("Email address")
  defp field_name(:password), do: gettext("Password")
  defp field_name(other), do: to_string(other)

  defp render_show(conn, scope, changeset) do
    render(conn, :show,
      user: scope.user,
      scope: scope,
      roles: for(hall <- scope.halls, do: {hall, Alnasl.Accounts.Scope.role(scope, hall.id)}),
      own_id: Halls.own_id(),
      form: Phoenix.Component.to_form(changeset, as: :user)
    )
  end
end
