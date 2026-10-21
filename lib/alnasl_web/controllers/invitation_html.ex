defmodule AlnaslWeb.InvitationHTML do
  @moduledoc "An invitation link opened: join the hall, with an account that exists or a new one."

  use AlnaslWeb, :html

  alias AlnaslWeb.Words

  def show(assigns) do
    ~H"""
    <Layouts.door flash={@flash} id="invitation" title={gettext("An invitation")}>
      <div class="stack">
        <p id="invitation-what">
          {gettext("To %{hall}, as %{role}, for %{email}.",
            hall: @invitation.hall.name,
            role: Words.role(@invitation.role),
            email: @invitation.email
          )}
        </p>

        <%= cond do %>
          <% @current_scope && @current_scope.user && @current_scope.user.email == @invitation.email -> %>
            <.form for={%{}} id="invitation-accept" action={~p"/invite/#{@token}"} method="post">
              <.button id="invitation-accept-submit" variant="primary" type="submit">
                {gettext("Join %{hall}", hall: @invitation.hall.name)}
              </.button>
            </.form>
          <% @current_scope && @current_scope.user -> %>
            <p id="invitation-other" class="note">
              {gettext("You are signed in as %{email}. This invitation is for another address.",
                email: @current_scope.user.email
              )}
            </p>
            <.button id="invitation-log-out" href={~p"/log-out"} method="delete">
              {gettext("Sign out")}
            </.button>
          <% @account? -> %>
            <p class="note">
              {gettext("That address has an account here. Sign in, and you come back here to join.")}
            </p>
            <.button id="invitation-log-in" variant="primary" href={~p"/log-in"}>
              {gettext("Sign in")}
            </.button>
          <% true -> %>
            <.form for={@form} id="invitation-form" action={~p"/invite/#{@token}"} class="stack">
              <p class="note">
                {gettext("Choose a password for the new account (at least %{n} characters).",
                  n: Alnasl.Accounts.User.min_password()
                )}
              </p>
              <.input
                field={@form[:password]}
                type="password"
                label={gettext("Password")}
                autocomplete="new-password"
                required
              />
              <.button id="invitation-submit" variant="primary" type="submit">
                {gettext("Make the account and join")}
              </.button>
            </.form>
        <% end %>

        <div :if={@keycloak? && !(@current_scope && @current_scope.user)}>
          <p class="note">
            {gettext("Or with 02cloud, if %{email} is your address there:", email: @invitation.email)}
          </p>
          <.button id="invitation-keycloak" href={~p"/auth/keycloak"}>
            {gettext("Sign in with 02cloud")}
          </.button>
        </div>
      </div>
    </Layouts.door>
    """
  end

  def gone(assigns) do
    ~H"""
    <Layouts.door flash={@flash} id="invitation-gone" title={gettext("An invitation")}>
      <p class="note">
        {gettext(
          "This invitation is used, withdrawn or has run out (a week). Ask whoever sent it for a new one."
        )}
      </p>
      <p>
        <.button id="invitation-gone-log-in" href={~p"/log-in"}>{gettext("Sign in")}</.button>
      </p>
    </Layouts.door>
    """
  end
end
