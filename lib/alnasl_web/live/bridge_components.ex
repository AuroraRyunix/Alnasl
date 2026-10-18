defmodule AlnaslWeb.BridgeComponents do
  @moduledoc """
  The Bridges tab of a hall's own page (Setup only links to it): "Add a bridge" (a link and its QR code, good
  for fifteen minutes and one bridge, which joins this hall), and every
  bridge of the hall - connected or not, its ports and boards, and the
  commands it takes.

  The page keeps `bridges`, `bridge_join`, `bridge_message` and `base_url`
  in its assigns; `handle/4` does the panel's events for it.
  """

  use AlnaslWeb, :html

  alias Alnasl.{Bridges, Halls}
  alias AlnaslWeb.Access

  attr :bridges, :list, required: true, doc: "`[%{bridge, live}]`"
  attr :join, :map, default: nil, doc: "`%{url, expires_at, qr}` of the code on show"
  attr :message, :string, default: nil
  attr :owner?, :boolean, default: true, doc: "may add, command and remove (the hall's owner)"

  attr :halls, :list,
    default: [],
    doc: "the halls a bridge can be moved to (an admin's, with more than one hall)"

  def bridges(assigns) do
    ~H"""
    <div id="bridges" class="stack">
      <p class="note">
        {gettext(
          "A bridge is Arkab: a small program on a computer beside the boards (a Raspberry Pi will do) that reads them and sends them here. It dials out; nothing has to be opened for it."
        )}
      </p>

      <%= if @join do %>
        <div id="bridge-join" class="phone-access">
          <div :if={@join.qr} id="bridge-join-qr" class="qr">
            <svg
              viewBox={"0 0 #{@join.qr.size} #{@join.qr.size}"}
              role="img"
              aria-label={gettext("QR code of %{url}", url: @join.url)}
              shape-rendering="crispEdges"
            >
              <rect width={@join.qr.size} height={@join.qr.size} fill="#ffffff" />
              <rect
                :for={{x, y} <- @join.qr.cells}
                x={x}
                y={y}
                width="1"
                height="1"
                fill="#000000"
              />
            </svg>
          </div>
          <div class="stack">
            <ol id="bridge-join-steps" class="join-steps">
              <li>
                {gettext("Install Arkab on the computer beside the boards, and start it.")}
                <.link
                  href={AlnaslWeb.WizardComponents.arkab_releases()}
                  target="_blank"
                  rel="noopener"
                >
                  {gettext("Download Arkab")}
                </.link>
              </li>
              <li>{gettext("Open Arkab's page on that computer (port 4050).")}</li>
              <li>
                {gettext(
                  "Under \"Join a server\", paste this link, or press Scan and point the camera at the code. Then press Join."
                )}
              </li>
            </ol>
            <p id="bridge-join-link" class="addresses mono">{@join.url}</p>
            <p id="bridge-join-expiry" class="note">
              {gettext("Good for one bridge, until %{time} (UTC).",
                time: Calendar.strftime(@join.expires_at, "%H:%M")
              )}
            </p>
          </div>
        </div>
      <% end %>

      <div :if={@owner?}>
        <.button id="bridge-add" phx-click="add_bridge" icon="send">
          {gettext("Add a bridge")}
        </.button>
      </div>

      <p :if={@message} id="bridge-message" class="note" role="status">{@message}</p>

      <ul id="bridge-list" class="dests">
        <li :if={@bridges == []} id="bridge-none" class="empty">
          <b>{gettext("No bridges yet")}</b>
          <p>
            {gettext(
              "A bridge is Arkab on a small computer beside the boards of a hall: it reads them and sends them here. Add a bridge, then paste its link on the bridge's page or scan the code there."
            )}
          </p>
        </li>
        <li :for={%{bridge: b, live: live} <- @bridges} id={"bridge-#{b.id}"} class="stack">
          <div>
            <b>{b.name}</b>
            <.badge :if={live} id={"bridge-#{b.id}-up"} tone="ok" icon="live">
              {gettext("connected")}
            </.badge>
            <.badge :if={!live} id={"bridge-#{b.id}-down"} tone="bad" icon="offline">
              {gettext("not connected")}
            </.badge>
            <span :if={b.software} class="note">{b.software}</span>
          </div>

          <%= if live do %>
            <ul id={"bridge-#{b.id}-ports"} class="addresses">
              <li
                :for={{port, i} <- Enum.with_index(live.ports)}
                id={"bridge-#{b.id}-port-#{i}"}
              >
                <span class="mono">{port["port"]}</span>
                <span :if={port["description"] not in [nil, ""]} class="note">
                  {port["description"]}
                </span>
                <%= if !@owner? do %>
                  <span :if={port["read"]} class="note">{gettext("read")}</span>
                <% else %>
                  <%= if port["read"] do %>
                    <.button
                      id={"bridge-#{b.id}-rescan-#{i}"}
                      small
                      variant="ghost"
                      phx-click="bridge_command"
                      phx-value-id={b.id}
                      phx-value-cmd="rescan"
                      phx-value-port={port["port"]}
                    >
                      {gettext("Read again")}
                    </.button>
                    <.button
                      id={"bridge-#{b.id}-forget-#{i}"}
                      small
                      variant="ghost"
                      phx-click="bridge_command"
                      phx-value-id={b.id}
                      phx-value-cmd="forget_port"
                      phx-value-port={port["port"]}
                      data-confirm={gettext("Stop reading this port on the bridge?")}
                    >
                      {gettext("Forget")}
                    </.button>
                  <% else %>
                    <.button
                      id={"bridge-#{b.id}-read-#{i}"}
                      small
                      phx-click="bridge_command"
                      phx-value-id={b.id}
                      phx-value-cmd="add_port"
                      phx-value-port={port["port"]}
                    >
                      {gettext("Read")}
                    </.button>
                  <% end %>
                <% end %>
              </li>
            </ul>
            <p :if={live.boards != []} id={"bridge-#{b.id}-boards"} class="note">
              {ngettext("%{count} board", "%{count} boards", length(live.boards))}: {Enum.map_join(
                live.boards,
                ", ",
                & &1["id"]
              )}
            </p>
          <% end %>

          <div :if={@owner?} class="row">
            <.button
              :if={live}
              id={"bridge-#{b.id}-resend"}
              small
              variant="ghost"
              phx-click="bridge_command"
              phx-value-id={b.id}
              phx-value-cmd="resend"
            >
              {gettext("Send every board again")}
            </.button>
            <.button
              id={"bridge-#{b.id}-remove"}
              small
              variant="danger"
              phx-click="remove_bridge"
              phx-value-id={b.id}
              data-confirm={gettext("Remove this bridge? Its boards go with it, here and there.")}
            >
              {gettext("Remove")}
            </.button>
            <form
              :if={length(@halls) > 1}
              id={"bridge-#{b.id}-move"}
              phx-change="move_bridge"
              class="inline"
            >
              <input type="hidden" name="bridge" value={b.id} />
              <.input
                id={"bridge-#{b.id}-hall"}
                type="select"
                name="hall"
                label={gettext("Hall")}
                value={b.hall_id}
                options={Enum.map(@halls, &{&1.name, &1.id})}
              />
            </form>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  Where a bridge should be sent: the address the page was opened on, unless
  that is this machine's own name for itself - then the first address in
  the hall's network, which a bridge elsewhere can reach.
  """
  def base_url(%URI{} = uri) do
    if uri.host in ["localhost", "127.0.0.1", "::1"] do
      case Access.info().urls do
        [url | _] -> url
        [] -> origin(uri)
      end
    else
      origin(uri)
    end
  end

  defp origin(uri), do: URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port})

  @doc "The bridges of a hall, each with what it last said when connected."
  def list(hall_id) do
    for b <- Bridges.list(), Halls.of(b) == hall_id, do: %{bridge: b, live: Bridges.live(b.id)}
  end

  @doc """
  The panel's events, for the bridges of `hall_id`. The page has checked
  that the account may (the hall's owner; moving is an admin's). A bridge
  of another hall is left alone.
  """
  def handle("add_bridge", _params, socket, hall_id) do
    {:ok, join} = Bridges.create_join(DateTime.utc_now(:second), hall_id)
    base = socket.assigns.base_url || AlnaslWeb.Endpoint.url()
    assign(socket, bridge_join: join(base, join))
  end

  def handle("bridge_command", %{"id" => id, "cmd" => cmd} = params, socket, hall_id) do
    message =
      with %{} = bridge <- here(id, hall_id),
           {:ok, _id} <- Bridges.command(bridge.id, cmd, Map.take(params, ["port", "board"])) do
        gettext("Sent to the bridge.")
      else
        nil -> gettext("The bridge does not know that.")
        {:error, :offline} -> gettext("The bridge is not connected.")
        {:error, _other} -> gettext("The bridge does not know that.")
      end

    assign(socket, bridge_message: message)
  end

  def handle("remove_bridge", %{"id" => id}, socket, hall_id) do
    with %{} = bridge <- here(id, hall_id), do: Bridges.remove(bridge)
    assign(socket, bridge_message: nil, bridges: list(hall_id))
  end

  def handle("move_bridge", %{"bridge" => id, "hall" => to}, socket, hall_id) do
    with %{} = bridge <- here(id, hall_id),
         {to, ""} <- Integer.parse(to),
         %{} <- Halls.get(to) do
      Bridges.move(bridge, to)
    end

    assign(socket, bridge_message: nil, bridges: list(hall_id))
  end

  defp here(id, hall_id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %{} = bridge <- Bridges.get(id),
         true <- Halls.of(bridge) == hall_id do
      bridge
    else
      _no -> nil
    end
  end

  @doc "`%{url, expires_at, qr}` of a join code."
  def join(base, join) do
    url = base <> "/join/" <> join.code
    %{url: url, expires_at: join.expires_at, qr: Access.qr(url)}
  end
end
