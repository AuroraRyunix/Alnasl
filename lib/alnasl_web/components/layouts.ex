defmodule AlnaslWeb.Layouts do
  @moduledoc """
  The frame every page stands in: the rail with the eight places, the bar with
  the page's name and the connection to the results server, and - on every
  page, whenever the server cannot be reached - the banner that says so.
  """

  use AlnaslWeb, :html

  embed_templates "layouts/*"

  @doc """
  The app frame. Every LiveView template begins with it.

  `nav` is the place the page belongs to; `link` is `Alnasl.Outbox.status/0`
  (assigned by `AlnaslWeb.Hall`); `box` the box's name; `locale` the
  language in use.
  """
  attr :flash, :map, required: true
  attr :nav, :atom, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :link, :map, required: true
  attr :box, :string, default: "Alnasl"
  attr :locale, :string, default: "en"
  attr :alarms, :integer, default: 0
  slot :actions
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a class="skip" href="#main">{gettext("Skip to the page")}</a>
    <div class="frame">
      <aside class="rail">
        <.link navigate={~p"/"} class="brand" id="brand">
          <.icon name="arrow" />
          <div>
            <b>Alnasl</b>
            <span>{@box}</span>
          </div>
        </.link>
        <nav class="nav" aria-label={gettext("Places")}>
          <.nav_item to={~p"/"} key={:round} nav={@nav} icon="round" count={@alarms}>
            {gettext("Round")}
          </.nav_item>
          <.nav_item to={~p"/boards"} key={:boards} nav={@nav} icon="boards">
            {gettext("Boards")}
          </.nav_item>
          <.nav_item to={~p"/outbox"} key={:outbox} nav={@nav} icon="outbox" count={@link.pending}>
            {gettext("Outbox")}
          </.nav_item>
          <.nav_item to={~p"/pgn"} key={:pgn} nav={@nav} icon="pgn">
            {gettext("PGN")}
          </.nav_item>
          <.nav_item to={~p"/recordings"} key={:recordings} nav={@nav} icon="recordings">
            {gettext("Recordings")}
          </.nav_item>
          <.nav_item to={~p"/log"} key={:log} nav={@nav} icon="log">
            {gettext("Log")}
          </.nav_item>
          <.nav_item to={~p"/setup"} key={:setup} nav={@nav} icon="setup">
            {gettext("Setup")}
          </.nav_item>
          <.nav_item to={~p"/help"} key={:help} nav={@nav} icon="help">
            {gettext("Help")}
          </.nav_item>
        </nav>
        <div class="rail-foot">
          <div class="seg" role="group" aria-label={gettext("Language")}>
            <a
              id="locale-en"
              href={~p"/locale/en"}
              aria-current={to_string(@locale == "en")}
              lang="en"
            >EN</a>
            <a
              id="locale-nl"
              href={~p"/locale/nl"}
              aria-current={to_string(@locale == "nl")}
              lang="nl"
            >NL</a>
          </div>
          <button
            id="theme-toggle"
            type="button"
            class="btn small ghost"
            phx-click={JS.dispatch("alnasl:theme")}
            aria-label={gettext("Light or dark")}
            title={gettext("Light or dark")}
          >
            <.icon name="theme" />
          </button>
        </div>
      </aside>

      <div class="main">
        <div
          :if={@link.state in [:offline, :blocked]}
          id="offline-banner"
          class={["banner", @link.state == :blocked && "bad"]}
          role="status"
        >
          <.icon name="offline" />
          <span>
            <%= if @link.state == :blocked do %>
              {gettext("The results server refuses this box. Nothing is lost: %{count} waiting.",
                count: @link.pending
              )}
            <% else %>
              {gettext("No connection to the results server. Nothing is lost: %{count} waiting.",
                count: @link.pending
              )}
            <% end %>
          </span>
          <.link navigate={~p"/outbox"}>{gettext("What is waiting")}</.link>
        </div>

        <header class="bar">
          <h1>
            {@title}<span :if={@subtitle} class="sub">{@subtitle}</span>
          </h1>
          {render_slot(@actions)}
          <.link navigate={~p"/outbox"} id="link-state" style="text-decoration:none">
            <.link_state link={@link} />
          </.link>
        </header>

        <main id="main" class="page">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :to, :string, required: true
  attr :key, :atom, required: true
  attr :nav, :atom, required: true
  attr :icon, :string, required: true
  attr :count, :integer, default: 0
  slot :inner_block, required: true

  defp nav_item(assigns) do
    ~H"""
    <.link navigate={@to} id={"nav-#{@key}"} aria-current={if @nav == @key, do: "page"}>
      <.icon name={@icon} />
      <span>{render_slot(@inner_block)}</span>
      <span :if={@count > 0} class="count">{@count}</span>
    </.link>
    """
  end

  @doc "The connection to the results server in one badge: a shape, a word, and how much is waiting."
  attr :link, :map, required: true

  def link_state(assigns) do
    ~H"""
    <%= case @link.state do %>
      <% :connected -> %>
        <.badge tone="ok" icon="live">{gettext("Connected")}</.badge>
      <% :offline -> %>
        <.badge tone="warn" icon="offline">
          {gettext("Offline, %{count} waiting", count: @link.pending)}
        </.badge>
      <% :blocked -> %>
        <.badge tone="bad" icon="out_of_sync">{gettext("Refused")}</.badge>
      <% :unconfigured -> %>
        <.badge icon="waiting">{gettext("Not set up")}</.badge>
      <% _idle -> %>
        <.badge icon="waiting">
          <%= if @link.pending > 0 do %>
            {gettext("%{count} waiting", count: @link.pending)}
          <% else %>
            {gettext("Nothing sent yet")}
          <% end %>
        </.badge>
    <% end %>
    """
  end

  @doc "The flash messages, and the two that say the page lost its own connection to the box."
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="flashes" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <div
        id="client-error"
        class="flash error"
        role="alert"
        hidden
        phx-disconnected={JS.remove_attribute("hidden", to: ".phx-client-error #client-error")}
        phx-connected={JS.set_attribute({"hidden", ""}, to: "#client-error")}
      >
        <.icon name="offline" />
        <p>{gettext("This page lost its connection to the box. Trying again...")}</p>
      </div>
    </div>
    """
  end
end
