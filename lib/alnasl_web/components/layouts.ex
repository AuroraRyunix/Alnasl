defmodule AlnaslWeb.Layouts do
  @moduledoc """
  The frame every page stands in.

  On a desk: the rail - the brand (the box's name, or "server"), the hall
  picker, the places in four groups (Play, Send, Manage, Look back, and
  Help), and the account button at its foot. On a phone (860 px and less)
  the rail is a bar along the top with the brand, the hall picker and the
  account button, and the places are a tab bar along the bottom: Live,
  Boards, Results and More, which holds the rest. Nothing the desk has is
  missing on the phone; it is one tap further.

  Above the page: the notices (the results site cannot be reached, a board
  plays outside, a question about tables, a new version), at most two in
  sight and the rest folded behind "N more notices". Then the bar with the
  page's name and the connection badges.
  """

  use AlnaslWeb, :html

  alias Alnasl.Accounts.Scope
  alias Alnasl.ThemePacks
  alias AlnaslWeb.SeatingComponents

  embed_templates "layouts/*"

  @doc """
  The app frame. Every LiveView template begins with it.

  `update` is the newer version the box heard of, if any (`AlnaslWeb.Hall`).
  `nav` is the place the page belongs to; `link` is `Alnasl.Outbox.status/0`
  (assigned by `AlnaslWeb.Hall`); `box` the box's name; `locale` the
  language in use; `path` the page's own address, where the hall picker and
  the language come back to.
  """
  attr :flash, :map, required: true
  attr :nav, :atom, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :link, :map, required: true
  attr :box, :string, default: "Alnasl"
  attr :locale, :string, default: "en"
  attr :path, :string, default: "/"
  attr :update, :any, default: nil, doc: "`Alnasl.Updates.notice/0`"
  attr :alarms, :integer, default: 0

  attr :help, :atom,
    default: nil,
    doc: "a `AlnaslWeb.Components.ManualLink` topic: the \"?\" beside the title"

  attr :scope, :any,
    default: nil,
    doc: "`current_scope` (`AlnaslWeb.Hall`): the halls and the account"

  attr :hall, :map,
    default: nil,
    doc:
      "`AlnaslWeb.Status.build/1`: the badges, the counts, and the lines about boards outside (assigned by `AlnaslWeb.Hall`)"

  slot :actions
  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assigns
      |> assign(:notices, notices(assigns))
      |> assign(:waiting, waiting(assigns))

    ~H"""
    <a class="skip" href="#main">{gettext("Skip to the page")}</a>
    <div class="frame">
      <aside class="rail" id="rail">
        <.link navigate={~p"/"} class="brand" id="brand">
          <.logo />
          <div>
            <b>Alnasl</b> <span id="brand-edition">{edition_name(@box)}</span>
          </div>
        </.link>
        <.hall_picker scope={@scope} hall={@hall} path={@path} />
        <nav class="nav" id="nav" aria-label={gettext("Places")}>
          <div
            :for={{group, label, items} <- groups(@alarms, @waiting, @scope)}
            class="nav-group"
            id={"nav-group-#{group}"}
            role="group"
            aria-label={label}
          >
            <span :if={label} class="nav-head" aria-hidden="true">{label}</span>
            <.nav_item
              :for={item <- items}
              to={item.to}
              key={item.key}
              nav={@nav}
              icon={item.icon}
              count={item.count}
            >
              {item.label}
            </.nav_item>
          </div>
        </nav>

        <div class="rail-foot">
          <.account_menu scope={@scope} locale={@locale} path={@path} />
        </div>
      </aside>

      <div class="main">
        <div :if={@notices != []} id="notices" class="notices">
          <.notice
            :for={key <- Enum.take(@notices, 2)}
            key={key}
            link={@link}
            update={@update}
            hall={@hall}
            nav={@nav}
          />
          <%= if length(@notices) > 2 do %>
            <button
              id="more-notices-button"
              type="button"
              class="banner more-notices"
              aria-expanded="false"
              aria-controls="more-notices"
              phx-click={
                JS.toggle_attribute({"hidden", ""}, to: "#more-notices")
                |> JS.toggle_attribute({"aria-expanded", "true", "false"})
              }
            >
              <.icon name="chevron" />
              <span>
                {ngettext("%{count} more notice", "%{count} more notices", length(@notices) - 2)}
              </span>
            </button>

            <div id="more-notices" hidden>
              <.notice
                :for={key <- Enum.drop(@notices, 2)}
                key={key}
                link={@link}
                update={@update}
                hall={@hall}
                nav={@nav}
              />
            </div>
          <% end %>
        </div>

        <header class="bar">
          <h1>
            {@title}<span :if={@subtitle} class="sub">{@subtitle}</span>
            <AlnaslWeb.Components.ManualLink.manual_link :if={@help} topic={@help} />
          </h1>
          {render_slot(@actions)} <.live_pill />
          <span id="link-state" class="heads">
            <%= if @hall && is_list(@hall.heads) do %>
              <.link
                :for={head <- @hall.heads}
                id={head.id}
                navigate={head.to}
                class="head-link"
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
                title={gettext("Open the live boards on the results site")}
              >
                <span class="head-open-text">{gettext("Live boards")}</span> <.icon name="external" />
              </a>
            <% else %>
              <.link navigate={~p"/outbox"} class="head-link">
                <.link_state link={@link} />
              </.link>
            <% end %>
          </span>
        </header>

        <main id="main" class="page">
          {render_slot(@inner_block)}
        </main>
      </div>
      <.tab_bar nav={@nav} alarms={@alarms} waiting={@waiting} scope={@scope} />
    </div>
    <AlnaslWeb.Components.Tour.tour scope={@scope} />
    <.flash_group flash={@flash} />
    """
  end

  # The box's name under the logo, or "server" on the hosted copy: there is
  # no box to name there.
  defp edition_name(box) do
    case Alnasl.edition() do
      :server -> gettext("server")
      :box -> box
    end
  end

  # What waits in the outbox for this hall's tournaments: `pending` of
  # `Alnasl.Outbox.status/1`, the same number the badge and the Outbox page
  # count, so the rail cannot disagree with them. The whole queue on a box
  # without accounts.
  defp waiting(%{link: %{pending: n}}) when is_integer(n), do: n
  defp waiting(_assigns), do: 0

  # The places, in their groups: `{id, label, [item]}`. Help stands alone,
  # at the end, without a heading.
  defp groups(alarms, waiting, scope) do
    [
      {"play", gettext("Play"),
       [
         item(:round, ~p"/", "round", gettext("Live"), alarms),
         item(:boards, ~p"/boards", "boards", gettext("Boards")),
         item(:pgn, ~p"/pgn", "pgn", gettext("Games"))
       ]},
      {"send", gettext("Send"),
       [item(:outbox, ~p"/outbox", "outbox", gettext("Results"), waiting)]},
      {"manage", gettext("Manage"),
       [
         item(:halls, ~p"/halls", "hall", gettext("Halls")),
         item(:setup, ~p"/setup", "setup", gettext("Setup"))
       ] ++ fair_play_item(scope)},
      {"back", gettext("Look back"),
       [
         item(:log, ~p"/log", "log", gettext("Log")),
         item(:recordings, ~p"/recordings", "recordings", gettext("Recordings"))
       ]},
      {"help", nil, [item(:help, ~p"/help", "help", gettext("Help"))]}
    ]
  end

  # Fair play is the hall owner's and nobody else's, so it is in
  # the menu of somebody who owns a hall (`Alnasl.FairPlay.Access`), or was
  # shown a report by one, and in nobody else's: not the arbiter's, not the
  # viewer's, not the admin's.
  defp fair_play_item(scope) do
    if Alnasl.FairPlay.Access.menu?(scope),
      do: [item(:fair_play, ~p"/fair-play", "search", gettext("Fair play"))],
      else: []
  end

  defp item(key, to, icon, label, count \\ 0),
    do: %{key: key, to: to, icon: icon, label: label, count: count}

  # The tab bar keeps three places in reach of a thumb; More has the rest.
  @tabs [:round, :boards, :outbox]

  attr :nav, :atom, required: true
  attr :alarms, :integer, default: 0
  attr :waiting, :integer, default: 0
  attr :scope, :any, default: nil

  defp tab_bar(assigns) do
    items =
      assigns.alarms |> groups(assigns.waiting, assigns.scope) |> Enum.flat_map(&elem(&1, 2))

    assigns =
      assign(assigns,
        tabs: Enum.map(@tabs, fn key -> Enum.find(items, &(&1.key == key)) end),
        rest: Enum.reject(items, &(&1.key in @tabs))
      )

    ~H"""
    <nav id="tab-bar" class="tab-bar" aria-label={gettext("Places on a phone")}>
      <.link
        :for={tab <- @tabs}
        navigate={tab.to}
        id={"tab-#{tab.key}"}
        class="tab"
        aria-current={if @nav == tab.key, do: "page"}
      >
        <.icon name={tab.icon} /> <span>{tab.label}</span>
        <span :if={tab.count > 0} class="count">{tab.count}</span>
      </.link>

      <div
        id="tab-more"
        class="menu tab-more"
        phx-click-away={close_menu("tab-more")}
        data-close={close_menu("tab-more")}
      >
        <button
          id="tab-more-button"
          type="button"
          class="tab"
          aria-haspopup="true"
          aria-expanded="false"
          aria-controls="tab-more-menu"
          aria-current={if @nav in Enum.map(@rest, & &1.key), do: "page"}
          phx-click={toggle_menu("tab-more")}
        >
          <.icon name="more" /> <span>{gettext("More")}</span>
        </button>

        <div id="tab-more-menu" class="menu-panel more-sheet" hidden>
          <.link
            :for={item <- @rest}
            navigate={item.to}
            id={"tab-#{item.key}"}
            class="menu-item"
            aria-current={if @nav == item.key, do: "page"}
          >
            <.icon name={item.icon} /> <span>{item.label}</span>
            <span :if={item.count > 0} class="count">{item.count}</span>
          </.link>
        </div>
      </div>
    </nav>
    """
  end

  # A menu is a button and a panel: the panel's `hidden` and the button's
  # `aria-expanded` move together, and LiveView keeps both through a redraw.
  # A click elsewhere closes it; so does Escape, which `assets/js/app.js`
  # answers by running the menu's `data-close` (a key binding on the window
  # would take keys from the pages that have their own).
  defp toggle_menu(id) do
    JS.toggle_attribute({"hidden", ""}, to: "##{id}-menu")
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "##{id}-button")
  end

  defp close_menu(id) do
    JS.set_attribute({"hidden", ""}, to: "##{id}-menu")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "##{id}-button")
  end

  # --- notices -----------------------------------------------------------------

  # The notices that are up, most urgent first: the results site, what the
  # boards play in, then the news.
  defp notices(assigns) do
    seating = assigns.hall && assigns.hall.seating

    [
      assigns.link.state in [:offline, :blocked] && :offline,
      seating && seating.auto && :auto,
      seating && seating.outside != [] && :outside,
      seating && seating.ask != [] && assigns.nav != :setup && :ask,
      assigns.update && :update
    ]
    |> Enum.filter(& &1)
  end

  attr :key, :atom, required: true
  attr :link, :map, required: true
  attr :update, :any, default: nil
  attr :hall, :map, default: nil
  attr :nav, :atom, default: nil

  defp notice(%{key: :offline} = assigns) do
    ~H"""
    <div id="offline-banner" class={["banner", @link.state == :blocked && "bad"]} role="status">
      <.icon name="offline" />
      <span>
        <%= if @link.state == :blocked do %>
          {gettext("The results site refuses what Alnasl sends. Nothing is lost: %{count} waiting.",
            count: @link.pending
          )}
        <% else %>
          {gettext("No connection to the results site. Nothing is lost: %{count} waiting.",
            count: @link.pending
          )}
        <% end %>
      </span>
      <.link navigate={~p"/outbox"}>{gettext("What is waiting")}</.link>
    </div>
    """
  end

  defp notice(%{key: :update} = assigns) do
    ~H"""
    <div id="update-banner" class="banner news" role="status">
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

        <.link id="update-banner-setup" navigate={~p"/setup/updates"}>
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
            gettext("Stop looking for new versions? You can switch it on again under Setup, Updates.")
          }
        >
          {gettext("Don't ask again")}
        </button>
      </span>
    </div>
    """
  end

  defp notice(assigns) do
    ~H"""
    <SeatingComponents.notice key={@key} seating={@hall.seating} />
    """
  end

  # --- hall picker -------------------------------------------------------------

  @doc """
  The hall the pages are about, as one button with its live boards; it
  opens the account's halls, each with its role and live boards, a search
  field from seven halls on, and "All halls" at the bottom. Picking one
  keeps the page you are on (`/halls/:id/enter?return_to=`). Nothing when
  there is only one hall.
  """
  attr :scope, :any, default: nil
  attr :hall, :map, default: nil
  attr :path, :string, default: "/"

  def hall_picker(assigns) do
    assigns = assign(assigns, :live, (assigns.hall && assigns.hall[:live]) || %{})

    ~H"""
    <div
      :if={@scope && match?([_, _ | _], @scope.halls)}
      id="hall-picker"
      class="menu hall-picker"
      phx-click-away={close_menu("hall-picker")}
      data-close={close_menu("hall-picker")}
    >
      <button
        id="hall-picker-button"
        type="button"
        class="menu-button"
        aria-haspopup="true"
        aria-expanded="false"
        aria-controls="hall-picker-menu"
        phx-click={toggle_menu("hall-picker")}
      >
        <.icon name="hall" />
        <span class="menu-button-text">
          <span class="hint">{gettext("Hall")}</span>
          <b id="hall-picker-current">{@scope.hall && @scope.hall.name}</b>
        </span>

        <span
          id="hall-picker-live"
          class="live-count"
          title={gettext("Boards connected")}
        >
          {live_words(@scope.hall && Map.get(@live, @scope.hall.id, 0))}
        </span>
        <.icon name="chevron" />
      </button>

      <div id="hall-picker-menu" class="menu-panel" hidden>
        <input
          :if={length(@scope.halls) >= 7}
          id="hall-search"
          type="search"
          class="input menu-search"
          placeholder={gettext("Find a hall")}
          aria-label={gettext("Find a hall")}
          autocomplete="off"
          phx-hook=".HallSearch"
        />
        <script :type={Phoenix.LiveView.ColocatedHook} name=".HallSearch">
          export default {
            mounted() {
              this.el.addEventListener("input", () => {
                const query = this.el.value.trim().toLowerCase()
                document.querySelectorAll("#hall-picker-list [data-hall-name]").forEach((row) => {
                  row.hidden = query !== "" && !row.dataset.hallName.includes(query)
                })
              })
            }
          }
        </script>

        <ul id="hall-picker-list" class="menu-list">
          <li :for={hall <- @scope.halls} data-hall-name={String.downcase(hall.name)}>
            <a
              id={"hall-switch-#{hall.id}"}
              class="menu-item"
              href={~p"/halls/#{hall.id}/enter?#{[return_to: @path]}"}
              aria-current={if @scope.hall && @scope.hall.id == hall.id, do: "true"}
            >
              <span class="menu-item-main">
                <b>{hall.name}</b>
                <span class="hint">{AlnaslWeb.Words.role(Scope.role(@scope, hall.id))}</span>
              </span>
              <span class="live-count">{live_words(Map.get(@live, hall.id, 0))}</span>
            </a>
          </li>
        </ul>

        <.link navigate={~p"/halls"} id="hall-picker-all" class="menu-item menu-foot">
          <.icon name="hall" /> <span>{gettext("All halls")}</span>
        </.link>
      </div>
    </div>
    """
  end

  defp live_words(nil), do: ""

  defp live_words(count),
    do: ngettext("%{count} live", "%{count} live", count)

  # --- account -----------------------------------------------------------------

  @doc """
  The account button at the foot of the rail (top right on a phone): who
  is signed in and their role in this hall, the account page, the language
  this person reads the site in, the colour theme, and Sign out. On a box
  without accounts it holds the language and the theme, for this browser.
  """
  attr :scope, :any, default: nil
  attr :locale, :string, default: "en"
  attr :path, :string, default: "/"

  def account_menu(assigns) do
    user = assigns.scope && assigns.scope.user

    assigns =
      assign(assigns,
        user: user,
        role: user && Scope.role(assigns.scope, Scope.hall_id(assigns.scope))
      )

    ~H"""
    <div
      id="account"
      class="menu account-menu"
      phx-click-away={close_menu("account")}
      data-close={close_menu("account")}
    >
      <button
        id="account-button"
        type="button"
        class="menu-button account-button"
        aria-haspopup="true"
        aria-expanded="false"
        aria-controls="account-menu"
        phx-click={toggle_menu("account")}
      >
        <span class="avatar" aria-hidden="true">
          <%= if @user do %>
            {initial(@user.email)}
          <% else %>
            <.icon name="account" />
          <% end %>
        </span>

        <span class="menu-button-text account-name">
          <%= if @user do %>
            <span class="mono">{@user.email}</span>
          <% else %>
            {gettext("This browser")}
          <% end %>
        </span>
        <.icon name="chevron" />
      </button>

      <div id="account-menu" class="menu-panel account-panel" hidden>
        <div :if={@user} class="menu-head">
          <b id="account-email" class="mono">{@user.email}</b>
          <span :if={@role} id="account-role" class="hint">
            {gettext("%{role} in this hall", role: AlnaslWeb.Words.role(@role))}
          </span>
        </div>

        <.link :if={@user} id="account-link" href={~p"/account"} class="menu-item">
          <.icon name="account" /> <span>{gettext("Account")}</span>
        </.link>

        <div class="menu-section">
          <span class="menu-label" id="locale-label">
            <.icon name="language" /> {gettext("Language")}
          </span>

          <.form
            for={%{}}
            as={:locale_choice}
            action={~p"/locale"}
            method="post"
            id="locale-form"
            class="seg"
            aria-labelledby="locale-label"
          >
            <input type="hidden" name="return_to" value={@path} />
            <button
              :for={{code, name} <- [{"en", "English"}, {"nl", "Nederlands"}]}
              type="submit"
              name="locale"
              value={code}
              id={"locale-#{code}"}
              lang={code}
              aria-current={to_string(@locale == code)}
            >
              {name}
            </button>
          </.form>

          <p class="hint">
            <%= if @user do %>
              {gettext("Kept with your account.")}
            <% else %>
              {gettext("Kept in this browser.")}
            <% end %>
          </p>
        </div>

        <div class="menu-section">
          <span class="menu-label"><.icon name="theme" /> {gettext("Colour theme")}</span>
          <.theme_picker id="theme-picker" />
        </div>

        <button
          :if={@scope && @scope.tour}
          id="tour-start"
          type="button"
          class="menu-item"
          phx-click={close_menu("account") |> JS.push("tour_start")}
        >
          <.icon name="help" /> <span>{gettext("Take the tour")}</span>
        </button>

        <.link :if={@user} id="log-out" href={~p"/log-out"} method="delete" class="menu-item">
          <.icon name="signout" /> <span>{gettext("Sign out")}</span>
        </.link>
      </div>
    </div>
    """
  end

  defp initial(email), do: email |> String.first() |> String.upcase()

  @doc """
  The colour theme, chosen on the device (`assets/js/theme.js` does the work;
  the choice is kept in this browser and nothing is sent to the box). It
  lives in the account menu, and only there.

  Installed theme packs (`Alnasl.ThemePacks`) follow the built-in themes, each
  with its swatch; a pack that was refused is listed under them, greyed, with
  the reason, so whoever installed it finds out here rather than in a log.
  Their ids are prefixed with the picker's own.
  """
  attr :id, :string, required: true

  def theme_picker(assigns) do
    assigns = assign_packs(assigns)

    ~H"""
    <div
      id={@id}
      class="theme-grid"
      role="group"
      aria-label={gettext("Colour theme")}
      phx-update="ignore"
    >
      <.theme_option :for={{key, label} <- themes()} key={key} label={label} />
      <.pack_option :for={{pack, label} <- @packs} picker={@id} pack={pack} label={label} />
      <.pack_refused :for={{id, reason} <- @refused} picker={@id} id={id} reason={reason} />
    </div>
    """
  end

  defp assign_packs(assigns) do
    locale = Gettext.get_locale(AlnaslWeb.Gettext)

    assigns
    |> assign(:packs, Enum.map(ThemePacks.list(), &{&1, ThemePacks.label(&1, locale)}))
    |> assign(:refused, ThemePacks.refused())
  end

  attr :key, :string, required: true
  attr :label, :string, required: true

  defp theme_option(assigns) do
    ~H"""
    <button type="button" class="theme-picker-item" data-theme-opt={@key} aria-pressed="false">
      <span class={"theme-dot theme-dot-#{@key}"} aria-hidden="true"></span> {@label}
    </button>
    """
  end

  attr :picker, :string, required: true
  attr :pack, :map, required: true
  attr :label, :string, required: true

  defp pack_option(assigns) do
    ~H"""
    <button
      type="button"
      class="theme-picker-item is-pack"
      id={"#{@picker}-pack-#{@pack.id}"}
      data-theme-opt={@pack.id}
      aria-pressed="false"
      title={if @pack.author != "", do: gettext("By %{author}", author: @pack.author)}
    >
      <span class="theme-pack-swatch" aria-hidden="true">
        <i :for={colour <- @pack.swatch} style={"background: #{colour}"}></i>
      </span>
      {@label}
    </button>
    """
  end

  attr :picker, :string, required: true
  attr :id, :string, required: true
  attr :reason, :string, required: true

  defp pack_refused(assigns) do
    ~H"""
    <p class="theme-picker-refused" id={"#{@picker}-refused-#{@id}"} title={@reason}>
      {@id}: {gettext("refused: %{reason}", reason: @reason)}
    </p>
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
      <.icon name={@icon} /> <span>{render_slot(@inner_block)}</span>
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
      <span class="live-word">{gettext("Connecting...")}</span> <span class="live-ms"></span>
    </span>
    """
  end

  @doc """
  The frame of the pages before the site: signing in, an invitation, the
  account's password. No rail, nothing about the box but its name.
  """
  attr :flash, :map, required: true
  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  def door(assigns) do
    ~H"""
    <main class="door">
      <p class="door-brand"><.logo /> <b>Alnasl</b></p>

      <.panel id={@id} title={@title}>
        {render_slot(@inner_block)}
      </.panel>
    </main>
    <.flash_group flash={@flash} />
    """
  end

  @doc "The flash messages, and the two that say the page lost its own connection to the box."
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="flashes" aria-live="polite">
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
      <div
        id="client-error"
        class="flash error"
        role="alert"
        hidden
        phx-disconnected={JS.remove_attribute("hidden", to: ".phx-client-error #client-error")}
        phx-connected={JS.set_attribute({"hidden", ""}, to: "#client-error")}
      >
        <.icon name="offline" />
        <p>{gettext("This page lost its connection to Alnasl. Trying again...")}</p>
      </div>
    </div>
    """
  end
end
