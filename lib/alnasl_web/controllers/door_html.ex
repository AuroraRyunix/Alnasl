defmodule AlnaslWeb.DoorHTML do
  @moduledoc "The PIN page: the only page a browser from elsewhere sees before it has the PIN."

  use AlnaslWeb, :html

  def unlock(assigns) do
    ~H"""
    <main class="door">
      <p class="door-brand"><.logo /> <b>Alnasl</b></p>
      <.panel id="door" title={gettext("This box asks for a PIN")}>
        <form id="unlock-form" action={~p"/unlock"} method="post" class="stack">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <p class="note">
            {gettext("You are reaching Alnasl from another machine. The arbiter set a PIN for that.")}
          </p>
          <.input
            id="unlock-pin"
            name="pin"
            value=""
            type="password"
            label={gettext("PIN")}
            autocomplete="off"
            inputmode="numeric"
            required
          />
          <p
            :if={@error}
            id="unlock-error"
            class="error"
            role="alert"
            style="color:var(--bad);font-weight:600"
          >
            {@error}
          </p>
          <.button id="unlock-submit" variant="primary" type="submit">{gettext("Open")}</.button>
        </form>
      </.panel>
    </main>
    """
  end
end
