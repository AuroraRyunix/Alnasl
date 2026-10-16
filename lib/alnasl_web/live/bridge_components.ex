defmodule AlnaslWeb.BridgeComponents do
  @moduledoc """
  The Bridges panel of Setup: "Add a bridge" (a link and its QR code, good
  for fifteen minutes and one bridge), and every bridge let in - connected
  or not, its ports and boards, and the commands it takes.
  """

  use AlnaslWeb, :html

  alias AlnaslWeb.Access

  attr :bridges, :list, required: true, doc: "`[%{bridge, live}]`"
  attr :join, :map, default: nil, doc: "`%{url, expires_at, qr}` of the code on show"
  attr :message, :string, default: nil

  def bridges(assigns) do
    ~H"""
    <div id="bridges" class="stack">
      <p class="note">
        {gettext(
          "A bridge is a small program (Arkab) beside boards somewhere else - a Raspberry Pi in another hall - that sends them here. It dials out; nothing has to be opened for it."
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
            <p>
              {gettext(
                "Paste this link in the bridge's \"Join a server\" field, or scan the code there:"
              )}
            </p>
            <p id="bridge-join-link" class="addresses mono">{@join.url}</p>
            <p id="bridge-join-expiry" class="note">
              {gettext("Good for one bridge, until %{time} (UTC).",
                time: Calendar.strftime(@join.expires_at, "%H:%M")
              )}
            </p>
          </div>
        </div>
      <% end %>

      <div>
        <.button id="bridge-add" phx-click="add_bridge" icon="send">
          {gettext("Add a bridge")}
        </.button>
      </div>

      <p :if={@message} id="bridge-message" class="note" role="status">{@message}</p>

      <ul id="bridge-list" class="dests">
        <li :if={@bridges == []} id="bridge-none" class="note">
          {gettext("No bridge yet.")}
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

          <div>
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

  @doc "`%{url, expires_at, qr}` of a join code."
  def join(base, join) do
    url = base <> "/join/" <> join.code
    %{url: url, expires_at: join.expires_at, qr: Access.qr(url)}
  end
end
