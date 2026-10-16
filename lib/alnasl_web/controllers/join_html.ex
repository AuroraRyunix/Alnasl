defmodule AlnaslWeb.JoinHTML do
  @moduledoc "A join link opened in a browser: it is for a bridge, and says so."

  use AlnaslWeb, :html

  def show(assigns) do
    ~H"""
    <main class="door">
      <p class="door-brand"><.logo /> <b>Alnasl</b></p>
      <.panel id="join" title={gettext("This link is for an Arkab bridge")}>
        <p class="note">
          {gettext(
            "Open the bridge's page, and paste this link in its \"Join a server\" field - or scan the code with the bridge's page. The bridge does the rest."
          )}
        </p>
        <p id="join-code"><code>{@code}</code></p>
      </.panel>
    </main>
    """
  end
end
