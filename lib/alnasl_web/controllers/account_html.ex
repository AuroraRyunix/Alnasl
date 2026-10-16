defmodule AlnaslWeb.AccountHTML do
  @moduledoc "An account's own page: its address, its halls, a new password, signing out."

  use AlnaslWeb, :html

  alias AlnaslWeb.Words

  def show(assigns) do
    ~H"""
    <Layouts.door flash={@flash} id="account" title={gettext("Your account")}>
      <div class="stack">
        <p id="account-email" class="mono">{@user.email}</p>
        <p :if={@scope.admin?} id="account-admin" class="note">
          {gettext("You are an admin: every hall, and the box itself.")}
        </p>
        <ul id="account-halls" class="addresses">
          <li :for={{hall, role} <- @roles} id={"account-hall-#{hall.id}"}>
            <a href={~p"/halls/#{hall.id}/enter"}>{hall.name}</a>
            <span class="note">{Words.role(role)}</span>
          </li>
        </ul>

        <p :if={@user.must_change_password} id="account-must-change" class="note" role="alert">
          {gettext("You signed in with a temporary password. Choose your own to go on.")}
        </p>

        <.form
          for={@form}
          id="password-form"
          action={~p"/account/password"}
          method="put"
          class="stack"
        >
          <.input
            field={@form[:password]}
            type="password"
            label={
              gettext("New password (at least %{n} characters)",
                n: Alnasl.Accounts.User.min_password()
              )
            }
            autocomplete="new-password"
            required
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label={gettext("The same again")}
            autocomplete="new-password"
            required
          />
          <.button id="password-submit" variant="primary" type="submit">
            {gettext("Change the password")}
          </.button>
        </.form>

        <div class="row">
          <.button :if={!@user.must_change_password} id="account-back" href={~p"/"}>
            {gettext("Back to the boards")}
          </.button>
          <.button id="account-log-out" variant="ghost" href={~p"/log-out"} method="delete">
            {gettext("Sign out")}
          </.button>
        </div>
      </div>
    </Layouts.door>
    """
  end
end
