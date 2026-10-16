defmodule AlnaslWeb.HallsLive do
  @moduledoc """
  The halls of an account.

  * `:index` - every hall the account may see, at a glance: how many boards
    are live, which bridges are connected, and what wants an arbiter now.
    An admin makes new halls here.
  * `:show` - one hall, in tabs that each have an address of their own:
    People (`/halls/3`), Invitations (`/halls/3/invitations`), Bridges
    (`/halls/3/bridges`; "Add a bridge" joins this hall) and Settings
    (`/halls/3/settings`: rename, delete).

  Who may do what is checked here, per hall, not by the page-wide permit:
  a viewer of one hall can be the owner of the next.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Accounts, Boards, Bridges, Halls}
  alias Alnasl.Accounts.Scope
  alias AlnaslWeb.{BridgeComponents, Words}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Halls.subscribe()
      Bridges.subscribe()
      Boards.subscribe()
    end

    {:ok,
     socket
     |> assign(page_title: gettext("Halls"), base_url: nil, shown: nil)
     |> assign(bridge_join: nil, bridge_message: nil, bridges: [])
     |> assign(invite_link: nil, temporary: nil, deleting: false, delete_typed: "")
     |> assign(new_form: to_form(%{"name" => ""}, as: :hall))
     |> assign(invite_form: invite_form())}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket = assign(socket, base_url: BridgeComponents.base_url(URI.parse(uri)))

    case socket.assigns.live_action do
      :index ->
        {:noreply, socket |> assign(shown: nil) |> load_index()}

      :show ->
        with {id, ""} <- Integer.parse(params["id"] || ""),
             %{} = hall <- Halls.get(id),
             true <- Scope.sees?(socket.assigns.current_scope, hall.id) do
          {:noreply,
           socket
           |> assign(shown: hall, page_title: hall.name, invite_link: nil, temporary: nil)
           |> assign(tab: pick_tab(socket.assigns.current_scope, hall, params["tab"]))
           |> assign(deleting: false, delete_typed: "")
           |> assign(bridge_join: nil, bridge_message: nil)
           |> assign(name_form: to_form(%{"name" => hall.name}, as: :hall))
           |> load_show()}
        else
          _not_yours ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("That hall is not one of yours."))
             |> push_navigate(to: ~p"/halls")}
        end
    end
  end

  # The tabs of a hall, in order; what a scope may not use is not offered.
  @tabs ~w(people invitations bridges settings)

  defp tabs(scope, hall) do
    owner? = Scope.can?(scope, :owner, hall.id) and not scope.open?
    Enum.filter(@tabs, &(&1 in ~w(people bridges) or owner?))
  end

  defp pick_tab(scope, hall, wanted) do
    if wanted in tabs(scope, hall), do: wanted, else: "people"
  end

  defp tab_path(hall, "people"), do: ~p"/halls/#{hall.id}"
  defp tab_path(hall, tab), do: ~p"/halls/#{hall.id}/#{tab}"

  defp tab_label("people"), do: gettext("People")
  defp tab_label("invitations"), do: gettext("Invitations")
  defp tab_label("bridges"), do: gettext("Bridges")
  defp tab_label("settings"), do: gettext("Settings")

  defp invite_form, do: to_form(%{"email" => "", "role" => "arbiter"}, as: :invite)

  defp load_index(socket) do
    scope = socket.assigns.current_scope
    snapshots = Halls.visible(scope, Boards.snapshots())
    bridges = Halls.visible(scope, Bridges.list())

    rows =
      for hall <- scope.halls do
        boards = Enum.filter(snapshots, &(hall_of(&1) == hall.id))
        hall_bridges = Enum.filter(bridges, &(Halls.of(&1) == hall.id))

        %{
          hall: hall,
          role: Scope.role(scope, hall.id),
          boards: length(boards),
          live: Enum.count(boards, & &1.connected?),
          attention: Enum.filter(boards, &attention?/1),
          bridges: length(hall_bridges),
          bridges_up: Enum.count(hall_bridges, &(Bridges.live(&1.id) != nil))
        }
      end

    assign(socket, rows: rows)
  end

  defp hall_of(%{hall_id: id}) when is_integer(id), do: id
  defp hall_of(_snapshot), do: Halls.own_id()

  # What wants an arbiter: a board out of step with its game, a clock
  # running the wrong way, or a game in play nobody hears from.
  defp attention?(%{status: status}) when status in [:out_of_sync, :clock_alarm], do: true

  defp attention?(%{status: :no_signal, linked?: true, game_status: status}),
    do: status != "finished"

  defp attention?(_snapshot), do: false

  defp load_show(socket) do
    hall = socket.assigns.shown
    scope = socket.assigns.current_scope

    assign(socket,
      members: if(scope.open?, do: [], else: Halls.members(hall)),
      invitations:
        if(Scope.can?(scope, :owner, hall.id), do: Accounts.open_invitations(hall), else: []),
      bridges: BridgeComponents.list(hall.id),
      owner?: Scope.can?(scope, :owner, hall.id),
      admin?: Scope.can?(scope, :admin),
      all_halls: if(Scope.can?(scope, :admin), do: Halls.list(), else: [])
    )
  end

  # --- events ------------------------------------------------------------------

  @impl true
  def handle_event("create_hall", %{"hall" => attrs}, socket) do
    case Halls.create(socket.assigns.current_scope, attrs) do
      {:ok, hall} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Hall %{name} is there. Invite its people next.", name: hall.name)
         )
         |> push_navigate(to: ~p"/halls/#{hall.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, new_form: to_form(changeset, as: :hall))}

      {:error, :forbidden} ->
        {:noreply, refuse(socket)}
    end
  end

  def handle_event(_event, _params, %{assigns: %{shown: nil}} = socket), do: {:noreply, socket}

  def handle_event("rename", %{"hall" => attrs}, socket) do
    case Halls.rename(socket.assigns.current_scope, socket.assigns.shown, attrs) do
      {:ok, hall} ->
        {:noreply,
         socket
         |> assign(
           shown: hall,
           page_title: hall.name,
           name_form: to_form(%{"name" => hall.name}, as: :hall)
         )
         |> put_flash(:info, gettext("Renamed."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, name_form: to_form(changeset, as: :hall))}

      {:error, :forbidden} ->
        {:noreply, refuse(socket)}
    end
  end

  def handle_event("delete_ask", _params, socket) do
    {:noreply, assign(socket, deleting: true, delete_typed: "")}
  end

  def handle_event("delete_cancel", _params, socket) do
    {:noreply, assign(socket, deleting: false, delete_typed: "")}
  end

  def handle_event("delete_typing", %{"name" => typed}, socket) do
    {:noreply, assign(socket, delete_typed: typed)}
  end

  def handle_event("delete_hall", %{"name" => typed}, socket) do
    hall = socket.assigns.shown

    # The button is disabled until the name matches; a forged event is not let through.
    if String.trim(typed) == hall.name do
      case Halls.delete(socket.assigns.current_scope, hall) do
        {:ok, hall} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Hall %{name} is gone.", name: hall.name))
           |> push_navigate(to: ~p"/halls")}

        {:error, {:not_empty, left}} ->
          {:noreply,
           socket
           |> assign(deleting: false, delete_typed: "")
           |> put_flash(:error, not_empty_message(left))}

        {:error, :own} ->
          {:noreply,
           socket
           |> assign(deleting: false)
           |> put_flash(:error, gettext("The box's own hall cannot be deleted."))}

        {:error, _forbidden} ->
          {:noreply, refuse(assign(socket, deleting: false))}
      end
    else
      {:noreply, assign(socket, delete_typed: typed)}
    end
  end

  def handle_event("invite", %{"invite" => %{"email" => email, "role" => role}}, socket) do
    case Accounts.invite(socket.assigns.current_scope, socket.assigns.shown, email, role) do
      {:ok, token} ->
        link = (socket.assigns.base_url || AlnaslWeb.Endpoint.url()) <> "/invite/" <> token

        {:noreply,
         socket
         |> assign(invite_link: %{url: link, email: String.downcase(String.trim(email))})
         |> assign(invite_form: invite_form())
         |> load_show()}

      {:error, :email} ->
        {:noreply, put_flash(socket, :error, gettext("That is not an email address."))}

      {:error, :admin_only} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "This address has no account here yet, and on this server new accounts come from an admin. Ask one to invite it."
           )
         )}

      {:error, _forbidden} ->
        {:noreply, refuse(socket)}
    end
  end

  def handle_event("withdraw", %{"invitation" => id}, socket) do
    case Accounts.withdraw_invitation(socket.assigns.current_scope, id) do
      {:ok, _gone} -> {:noreply, socket |> assign(invite_link: nil) |> load_show()}
      {:error, :forbidden} -> {:noreply, refuse(socket)}
      {:error, _gone} -> {:noreply, load_show(socket)}
    end
  end

  def handle_event("set_role", %{"member" => id, "role" => role}, socket) do
    role = if role == "", do: nil, else: role

    case Halls.set_role(socket.assigns.current_scope, socket.assigns.shown, id, role) do
      {:ok, _member} ->
        {:noreply, load_show(socket)}

      {:error, :last_owner} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("A hall keeps at least one owner. Make someone else owner first.")
         )
         |> load_show()}

      {:error, :forbidden} ->
        {:noreply, refuse(socket)}

      {:error, _other} ->
        {:noreply, load_show(socket)}
    end
  end

  def handle_event("temporary_password", %{"user" => id}, socket) do
    scope = socket.assigns.current_scope

    with true <- Scope.can?(scope, :admin),
         %{} = user <- Accounts.get_user(id),
         {:ok, password, tokens} <- Accounts.set_temporary_password(scope, user) do
      AlnaslWeb.UserAuth.disconnect_sessions(tokens)
      {:noreply, assign(socket, temporary: %{email: user.email, password: password})}
    else
      _no -> {:noreply, refuse(socket)}
    end
  end

  def handle_event(event, params, socket)
      when event in ~w(add_bridge bridge_command remove_bridge move_bridge) do
    scope = socket.assigns.current_scope
    hall = socket.assigns.shown
    need = if event == "move_bridge", do: :admin, else: :owner

    if Scope.can?(scope, need, hall.id) do
      {:noreply, BridgeComponents.handle(event, params, socket, hall.id)}
    else
      {:noreply, refuse(socket)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # "2 bridges and 1 tournament - remove them first"
  defp not_empty_message(left) do
    parts =
      [
        left.bridges > 0 &&
          ngettext("%{count} bridge", "%{count} bridges", left.bridges),
        left.tournaments > 0 &&
          ngettext("%{count} tournament", "%{count} tournaments", left.tournaments),
        left.links > 0 &&
          ngettext(
            "%{count} connection to OpenPairings",
            "%{count} connections to OpenPairings",
            left.links
          )
      ]
      |> Enum.filter(& &1)

    what =
      case Enum.reverse(parts) do
        [one] ->
          one

        [last | rest] ->
          Enum.join(Enum.reverse(rest), ", ") <> " " <> gettext("and") <> " " <> last
      end

    gettext("This hall still has %{what} - remove them first.", what: what)
  end

  defp refuse(socket),
    do: put_flash(socket, :error, gettext("Your role in this hall does not let you do that."))

  # --- what happened elsewhere ---------------------------------------------------

  @impl true
  def handle_info({:bridges, {:reply, _bridge, _id, true, _error}}, socket),
    do: {:noreply, assign(socket, bridge_message: gettext("The bridge did it."))}

  def handle_info({:bridges, {:reply, _bridge, _id, false, error}}, socket),
    do:
      {:noreply,
       assign(socket, bridge_message: gettext("The bridge said no: %{why}.", why: error))}

  def handle_info({tag, _what}, socket) when tag in [:bridges, :halls, :board],
    do: {:noreply, reload(socket)}

  def handle_info(_other, socket), do: {:noreply, socket}

  defp reload(%{assigns: %{shown: nil}} = socket), do: load_index(socket)

  defp reload(socket) do
    case Halls.get(socket.assigns.shown.id) do
      nil -> push_navigate(socket, to: ~p"/halls")
      hall -> socket |> assign(shown: hall) |> load_show()
    end
  end

  # --- the page ----------------------------------------------------------------

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:halls}
      help={:halls}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      scope={@current_scope}
      title={gettext("Halls")}
    >
      <div class="stack">
        <p :if={@current_scope.open?} id="halls-open" class="note">
          {gettext(
            "This box has no accounts: everybody on the hall's network may do everything, as before. Make the first account on Setup to change that."
          )}
        </p>

        <p :if={@rows == []} id="halls-none" class="note">
          {gettext("Your account is not in any hall yet. Whoever invited you can fix that.")}
        </p>

        <div :if={@rows != []} class="panel flush">
          <div class="table-wrap">
            <table id="halls">
              <thead>
                <tr>
                  <th>{gettext("Hall")}</th>
                  <th>{gettext("Your role")}</th>
                  <th>{gettext("Live boards")}</th>
                  <th>{gettext("Bridges")}</th>
                  <th>{gettext("Attention")}</th>
                  <th><span class="sr-only">{gettext("Actions")}</span></th>
                </tr>
              </thead>

              <tbody>
                <tr :for={row <- @rows} id={"hall-#{row.hall.id}"}>
                  <td>
                    <.link navigate={~p"/halls/#{row.hall.id}"} id={"hall-#{row.hall.id}-open"}>
                      <b>{row.hall.name}</b>
                    </.link>
                  </td>

                  <td id={"hall-#{row.hall.id}-role"}>{Words.role(row.role)}</td>

                  <td id={"hall-#{row.hall.id}-boards"} class="num">
                    {gettext("%{live} of %{count}", live: row.live, count: row.boards)}
                  </td>

                  <td id={"hall-#{row.hall.id}-bridges"} class="num">
                    <%= if row.bridges > 0 do %>
                      {gettext("%{up} of %{count}", up: row.bridges_up, count: row.bridges)}
                    <% else %>
                      <span class="note">{gettext("none")}</span>
                    <% end %>
                  </td>

                  <td>
                    <%= if row.attention != [] do %>
                      <ul id={"hall-#{row.hall.id}-attention"} class="addresses">
                        <li
                          :for={board <- row.attention}
                          id={"hall-#{row.hall.id}-attention-#{board.id}"}
                        >
                          <.state state={board.status} /> <span>{board.name}</span>
                        </li>
                      </ul>
                    <% else %>
                      <span id={"hall-#{row.hall.id}-calm"} class="note">
                        {gettext("Nothing needs an arbiter.")}
                      </span>
                    <% end %>
                  </td>

                  <td class="act">
                    <.button
                      id={"hall-#{row.hall.id}-enter"}
                      small
                      href={~p"/halls/#{row.hall.id}/enter"}
                    >
                      {gettext("To its boards")}
                    </.button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <.panel
          :if={Alnasl.Accounts.Scope.can?(@current_scope, :admin) and not @current_scope.open?}
          id="hall-new"
          title={gettext("A new hall")}
        >
          <.form for={@new_form} id="hall-new-form" phx-submit="create_hall" class="row">
            <.input field={@new_form[:name]} label={gettext("Name")} required />
            <.button id="hall-new-submit" variant="primary" type="submit">{gettext("Make it")}</.button>
          </.form>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:halls}
      help={:halls}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      scope={@current_scope}
      title={@shown.name}
    >
      <:actions>
        <.button id="hall-enter" href={~p"/halls/#{@shown.id}/enter"} icon="boards">
          {gettext("To its boards")}
        </.button>
      </:actions>

      <div class="stack">
        <nav id="hall-tabs" class="seg hall-tabs" aria-label={gettext("Parts of this hall")}>
          <.link
            :for={tab <- tabs(@current_scope, @shown)}
            id={"hall-tab-#{tab}"}
            patch={tab_path(@shown, tab)}
            aria-current={to_string(@tab == tab)}
          >
            {tab_label(tab)}
          </.link>
        </nav>

        <.panel
          :if={@tab == "settings" and @owner? and not @current_scope.open?}
          id="hall-name"
          title={gettext("Name")}
        >
          <.form for={@name_form} id="hall-name-form" phx-submit="rename" class="row">
            <.input field={@name_form[:name]} label={gettext("Name")} required />
            <.button id="hall-name-submit" type="submit">{gettext("Rename")}</.button>
          </.form>
        </.panel>

        <.panel :if={@tab == "people"} id="hall-people" title={gettext("People")}>
          <%= if @current_scope.open? do %>
            <p id="hall-people-open" class="note">
              {gettext(
                "No accounts yet: everybody on the hall's network may do everything. The first account is made on Setup, and becomes this hall's owner."
              )}
            </p>
          <% else %>
            <ul id="hall-members" class="dests">
              <li :for={member <- @members} id={"member-#{member.id}"} class="row">
                <span class="mono">{member.user.email}</span>
                <%= if @owner? do %>
                  <form id={"member-#{member.id}-role"} phx-change="set_role" class="inline">
                    <input type="hidden" name="member" value={member.id} />
                    <.input
                      id={"member-#{member.id}-role-select"}
                      type="select"
                      name="role"
                      value={member.role}
                      options={role_options()}
                    />
                  </form>

                  <.button
                    id={"member-#{member.id}-remove"}
                    small
                    variant="ghost"
                    phx-click="set_role"
                    phx-value-member={member.id}
                    phx-value-role=""
                    data-confirm={gettext("Take this account out of the hall?")}
                  >
                    {gettext("Take out")}
                  </.button>
                <% else %>
                  <span class="note">{Words.role(member.role)}</span>
                <% end %>

                <.button
                  :if={@admin?}
                  id={"member-#{member.id}-temporary"}
                  small
                  variant="ghost"
                  phx-click="temporary_password"
                  phx-value-user={member.user.id}
                  data-confirm={
                    gettext("Give this account a temporary password? Its sessions end now.")
                  }
                >
                  {gettext("Temporary password")}
                </.button>
              </li>
            </ul>

            <p :if={@temporary} id="hall-temporary" class="addresses" role="status">
              {gettext("Temporary password for %{email}:", email: @temporary.email)}
              <b class="mono">{@temporary.password}</b>
              <span class="note">
                {gettext("Shown once. The next sign-in asks for a password of their own.")}
              </span>
            </p>

            <dl class="note">
              <%= for role <- Alnasl.Halls.Member.roles() do %>
                <dt>{Words.role(role)}</dt>

                <dd>{Words.role_means(role)}</dd>
              <% end %>
            </dl>
          <% end %>
        </.panel>

        <.panel
          :if={@tab == "invitations" and @owner? and not @current_scope.open?}
          id="hall-invite"
          title={gettext("Invite")}
        >
          <div class="stack">
            <.form for={@invite_form} id="invite-form" phx-submit="invite" class="row">
              <.input
                field={@invite_form[:email]}
                label={gettext("Email address")}
                autocomplete="off"
                required
              />
              <.input
                field={@invite_form[:role]}
                type="select"
                label={gettext("Role")}
                options={role_options()}
              />
              <.button id="invite-submit" variant="primary" type="submit">
                {gettext("Make an invitation")}
              </.button>
            </.form>

            <div :if={@invite_link} id="invite-made" class="stack">
              <p>
                {gettext("Send this link to %{email}. It works once, for a week:",
                  email: @invite_link.email
                )}
              </p>

              <p id="invite-link" class="addresses mono">{@invite_link.url}</p>
            </div>

            <ul :if={@invitations != []} id="invitations" class="dests">
              <li :for={i <- @invitations} id={"invitation-#{i.id}"} class="row">
                <span class="mono">{i.email}</span> <span class="note">{Words.role(i.role)}</span>
                <span class="note">
                  {gettext("until %{date}", date: Calendar.strftime(i.expires_at, "%Y-%m-%d"))}
                </span>

                <.button
                  id={"invitation-#{i.id}-withdraw"}
                  small
                  variant="ghost"
                  phx-click="withdraw"
                  phx-value-invitation={i.id}
                >
                  {gettext("Withdraw")}
                </.button>
              </li>
            </ul>
          </div>
        </.panel>

        <.panel
          :if={@tab == "settings" and @owner? and not @shown.own and not @current_scope.open?}
          id="hall-delete"
          title={gettext("Delete this hall")}
        >
          <div class="stack">
            <p class="note">
              {gettext(
                "Only a hall with no bridges and no tournaments can be deleted. Its people, invitations and boards go with it."
              )}
            </p>

            <div class="row">
              <.button
                :if={not @deleting}
                id="hall-delete-ask"
                variant="danger"
                phx-click="delete_ask"
              >
                {gettext("Delete hall")}
              </.button>
            </div>

            <div
              :if={@deleting}
              id="hall-delete-confirm"
              class="alarm warn"
              role="alertdialog"
              aria-labelledby="hall-delete-title"
            >
              <.icon name="warning" />
              <div>
                <b id="hall-delete-title">
                  {gettext("Delete %{name}? This cannot be undone.", name: @shown.name)}
                </b>
                <.form
                  for={%{}}
                  as={:delete}
                  id="hall-delete-form"
                  phx-change="delete_typing"
                  phx-submit="delete_hall"
                  class="stack"
                >
                  <.input
                    id="hall-delete-name"
                    name="name"
                    value={@delete_typed}
                    label={
                      gettext("Type the name of the hall to confirm: %{name}", name: @shown.name)
                    }
                    autocomplete="off"
                  />
                  <div class="row">
                    <.button
                      id="hall-delete-submit"
                      type="submit"
                      variant="danger"
                      disabled={String.trim(@delete_typed) != @shown.name}
                    >
                      {gettext("Delete for good")}
                    </.button>
                    <.button id="hall-delete-cancel" type="button" phx-click="delete_cancel">
                      {gettext("Cancel")}
                    </.button>
                  </div>
                </.form>
              </div>
            </div>
          </div>
        </.panel>

        <.panel :if={@tab == "bridges"} id="hall-bridges" title={gettext("Bridges")}>
          <:actions><AlnaslWeb.Components.ManualLink.manual_link topic={:bridges} /></:actions>

          <BridgeComponents.bridges
            bridges={@bridges}
            join={@bridge_join}
            message={@bridge_message}
            owner?={@owner?}
            halls={@all_halls}
          />
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  defp role_options, do: Enum.map(Alnasl.Halls.Member.roles(), &{Words.role(&1), &1})
end
