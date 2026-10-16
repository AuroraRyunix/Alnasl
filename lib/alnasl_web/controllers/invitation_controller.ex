defmodule AlnaslWeb.InvitationController do
  @moduledoc """
  An invitation link (`Alnasl.Accounts.invite/4`): whoever opens it makes
  the account for the address it names - with a password, or with 02cloud
  for that same address - or, having one, signs in and joins the hall. The
  link is spent by its first use.
  """

  use AlnaslWeb, :controller

  alias Alnasl.{Accounts, Keycloak}
  alias Alnasl.Accounts.User
  alias AlnaslWeb.UserAuth

  def show(conn, %{"token" => token}) do
    case Accounts.get_invitation(token) do
      nil ->
        conn |> put_status(:gone) |> render(:gone)

      invitation ->
        conn
        # Carried through a 02cloud sign-in, and back here after a password one.
        |> put_session(:invitation, token)
        |> put_session(:user_return_to, ~p"/invite/#{token}")
        |> render_show(invitation, token, Accounts.change_user_registration())
    end
  end

  def accept(conn, %{"token" => token} = params) do
    case conn.assigns.current_scope do
      %{user: %User{} = user} ->
        invitation = Accounts.get_invitation(token)

        case Accounts.accept_invitation(token, user) do
          {:ok, _user} ->
            conn
            |> delete_session(:invitation)
            |> delete_session(:user_return_to)
            |> put_flash(:info, gettext("You are in."))
            |> redirect(to: ~p"/halls/#{invitation.hall_id}/enter")

          {:error, :other_address} ->
            conn
            |> put_flash(
              :error,
              gettext("This invitation is for another address. Sign out first.")
            )
            |> redirect(to: ~p"/invite/#{token}")

          {:error, _used} ->
            conn |> put_status(:gone) |> render(:gone)
        end

      _nobody ->
        register(conn, token, params["user"] || %{})
    end
  end

  defp register(conn, token, attrs) do
    invitation = Accounts.get_invitation(token)

    case invitation && Accounts.register_with_invitation(token, attrs) do
      nil ->
        conn |> put_status(:gone) |> render(:gone)

      {:ok, user} ->
        conn
        |> delete_session(:invitation)
        |> delete_session(:user_return_to)
        |> UserAuth.log_in_user(user, ~p"/halls/#{invitation.hall_id}/enter")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_show(invitation, token, changeset)

      {:error, _used} ->
        conn |> put_status(:gone) |> render(:gone)
    end
  end

  defp render_show(conn, invitation, token, changeset) do
    render(conn, :show,
      invitation: invitation,
      token: token,
      form: Phoenix.Component.to_form(changeset, as: :user),
      account?: Accounts.get_user_by_email(invitation.email) != nil,
      keycloak?: Keycloak.configured?()
    )
  end
end
