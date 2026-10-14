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

  `update` is the newer version the box heard of, if any (`AlnaslWeb.Hall`).
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
  attr :update, :any, default: nil, doc: "`Alnasl.Updates.notice/0`"
  attr :alarms, :integer, default: 0

  attr :hall, :map,
    default: nil,
    doc:
      "`AlnaslWeb.Status.build/1`: the badges, and the lines about boards outside (assigned by `AlnaslWeb.Hall`)"

  slot :actions
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a class="skip" href="#main">{gettext("Skip to the page")}</a>
    <div class="frame">
      <aside class="rail">
        <.link navigate={~p"/"} class="brand" id="brand">
          <.logo />
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
          <.theme_picker id="theme-picker" />
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

        <AlnaslWeb.SeatingComponents.notices seating={@hall && @hall.seating} nav={@nav} />

        <div :if={@update} id="update-banner" class="banner news" role="status">
          <.icon name="send" />
          <span>
            {gettext("Alnasl %{version} is out. This box runs %{current}.",
              version: @update.version,
              current: Alnasl.Updates.current_version()
            )}
            <span :if={Map.get(@update, :no_build)} id="update-banner-no-build">
              {gettext("There is no Mac build for Intel.")}
            </span>
            <span :if={@update.size} id="update-banner-size">
              {gettext("The download is %{size}.", size: AlnaslWeb.Words.megabytes(@update.size))}
            </span>
          </span>
          <span class="banner-actions">
            <a id="update-banner-notes" href={@update.url} target="_blank" rel="noopener">
              {gettext("What is new")}
            </a>
            <.link id="update-banner-setup" navigate={~p"/setup#setup-updates"}>
              {gettext("Update...")}
            </.link>
            <button id="update-banner-later" type="button" class="linkish" phx-click="update_later">
              {gettext("Later")}
            </button>
            <button
              id="update-banner-never"
              type="button"
              class="linkish"
              phx-click="update_never"
              data-confirm={
                gettext(
                  "Stop looking for new versions? You can switch it on again under Setup, Updates."
                )
              }
            >
              {gettext("Don't ask again")}
            </button>
          </span>
        </div>

        <header class="bar">
          <h1>
            {@title}<span :if={@subtitle} class="sub">{@subtitle}</span>
          </h1>
          {render_slot(@actions)}
          <.live_pill />
          <span id="link-state" class="heads">
            <%= if @hall && is_list(@hall.heads) do %>
              <.link
                :for={head <- @hall.heads}
                id={head.id}
                navigate={head.to}
                style="text-decoration:none"
              >
                <.badge tone={head.tone} icon={head.icon}>{head.text}</.badge>
              </.link>
              <a
                :for={head <- @hall.heads}
                :if={head[:open]}
                id={head.id <> "-open"}
                href={head.open}
                target="_blank"
                rel="noopener"
                class="head-open"
                aria-label={gettext("Open the results site")}
                title={gettext("Open the results site")}
              >
                <.icon name="external" />
              </a>
            <% else %>
              <.link navigate={~p"/outbox"} style="text-decoration:none">
                <.link_state link={@link} />
              </.link>
            <% end %>
          </span>
        </header>

        <main id="main" class="page">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The colour theme, chosen on the device (`assets/js/theme.js` does the work;
  the choice is kept in this browser and nothing is sent to the box). `popover`
  is the rail's; `grid` is Setup's, where a phone finds it.
  """
  attr :id, :string, required: true
  attr :variant, :atom, default: :popover, values: [:popover, :grid]

  def theme_picker(%{variant: :grid} = assigns) do
    ~H"""
    <div
      id={@id}
      class="theme-grid"
      role="group"
      aria-label={gettext("Colour theme")}
      phx-update="ignore"
    >
      <.theme_option :for={{key, label} <- themes()} key={key} label={label} />
    </div>
    """
  end

  def theme_picker(assigns) do
    ~H"""
    <details id={@id} class="theme-picker" phx-update="ignore">
      <summary class="btn small ghost" title={gettext("Colour theme")}>
        <.icon name="theme" /> <span class="sr-only">{gettext("Colour theme")}</span>
      </summary>
      <div class="theme-picker-panel" role="group" aria-label={gettext("Colour theme")}>
        <.theme_option :for={{key, label} <- themes()} key={key} label={label} />
      </div>
    </details>
    """
  end

  attr :key, :string, required: true
  attr :label, :string, required: true

  defp theme_option(assigns) do
    ~H"""
    <button type="button" class="theme-picker-item" data-theme-opt={@key} aria-pressed="false">
      <span class={"theme-dot theme-dot-#{@key}"} aria-hidden="true"></span>
      {@label}
    </button>
    """
  end

  @doc "The themes, in the order they are offered; the names are OpenResults' own."
  def themes do
    [
      {"system", gettext("Match device")},
      {"paper", gettext("Paper")},
      {"night", gettext("Night")},
      {"board", gettext("Board")},
      {"slate", gettext("Slate")},
      {"contrast", gettext("High contrast")}
    ]
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
      <% :disabled -> %>
        <.badge icon="waiting">{gettext("Switched off")}</.badge>
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

  @doc """
  "Live · 2 ms": this browser's connection to the box, in the bar. The
  number is how long the box takes to answer a question asked every few
  seconds (`assets/js/app.js`, `LivePill`); when the socket drops it says
  "Reconnecting...". It says nothing about the results server.
  """
  def live_pill(assigns) do
    ~H"""
    <span
      id="live-pill"
      class="live-pill"
      phx-hook="LivePill"
      phx-update="ignore"
      data-state="connecting"
      data-live={gettext("Live")}
      data-reconnecting={gettext("Reconnecting...")}
      data-connecting={gettext("Connecting...")}
      role="status"
    >
      <span class="live-dot" aria-hidden="true"></span>
      <span class="live-word">{gettext("Connecting...")}</span>
      <span class="live-ms"></span>
    </span>
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
