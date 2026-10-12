defmodule AlnaslWeb.OutboxLive do
  @moduledoc """
  The connection to the results server, honestly: connected or not, when it
  last worked, how much is waiting, and why it is not going - in words.

  And the queue itself: what is waiting (oldest first, the order it will be
  sent in), what the server refused and why, and what went out lately.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Destination, Outbox, Tournaments}
  alias Alnasl.Destination.{LichessBroadcast, OpenPairings}
  alias AlnaslWeb.{DestinationWords, Scope, Words}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: gettext("Outbox"), refresh_due?: false) |> load()}
  end

  defp load(socket) do
    assign(socket,
      waiting: Outbox.list("pending", 60),
      rejected: Outbox.list("rejected", 30),
      sent: Outbox.list("sent", 30),
      counts: Outbox.counts(),
      destinations: Destination.statuses(),
      lichess_refused: LichessBroadcast.refused(),
      pairing_refused: OpenPairings.refused(),
      tournaments: Tournaments.active(),
      names: Map.new(Tournaments.list(), &{&1.id, Tournaments.title(&1)}),
      many?: Tournaments.many?(),
      waiting_by: %{
        "openresults" => Outbox.pending_by_tournament(),
        "lichess" => LichessBroadcast.pending_by_tournament(),
        "openpairings" => OpenPairings.pending_by_tournament()
      },
      refresh_due?: false
    )
  end

  @impl true
  def handle_event("send_now", _params, socket) do
    Outbox.send_now()
    {:noreply, put_flash(socket, :info, gettext("Trying now."))}
  end

  # One destination's own "send now": the others are left to their pauses.
  def handle_event("dest_send", %{"id" => id}, socket) do
    if module = Destination.get(id), do: Destination.send_now(module)

    {:noreply,
     put_flash(socket, :info, gettext("Trying %{name} now.", name: DestinationWords.name(id)))}
  end

  def handle_event("dest_toggle", %{"id" => id}, socket) do
    if module = Destination.get(id) do
      Destination.set_enabled(module, not Destination.enabled?(module))
    end

    {:noreply, load(socket)}
  end

  # The pairing program holds something newer than this box has to say - it
  # was another box, or this one was wiped. The arbiter says: ours.
  def handle_event("force_pairing", _params, socket) do
    count = OpenPairings.force()

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("%{n} game(s) are sent again, to replace what is held.", n: count)
     )
     |> load()}
  end

  def handle_event("prune", _params, socket) do
    removed = Outbox.prune(0)

    {:noreply,
     socket
     |> put_flash(:info, gettext("%{n} delivered message(s) cleared from the list.", n: removed))
     |> load()}
  end

  @impl true
  def handle_info(:outbox_changed, %{assigns: %{refresh_due?: true}} = socket),
    do: {:noreply, socket}

  def handle_info(:outbox_changed, socket) do
    Process.send_after(self(), :refresh, 400)
    {:noreply, assign(socket, refresh_due?: true)}
  end

  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  defp what(entry) do
    body = Jason.decode!(entry.body)
    last = List.last(body["moves"] || [])

    cond do
      body["status"] == "finished" -> gettext("result %{r}", r: body["result"] || "*")
      body["replace"] -> gettext("the whole game again (%{n} moves)", n: entry.plies)
      last -> gettext("up to move %{n} (%{san})", n: entry.plies, san: last)
      true -> gettext("the start of the game")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:outbox}
      link={@link}
      box={@box}
      locale={@locale}
      title={gettext("Outbox")}
    >
      <:actions>
        <.button id="send-now" icon="send" variant="primary" phx-click="send_now">{gettext("Send now")}</.button>
      </:actions>

      <.panel id="link-panel" title={gettext("Connection to the results server")}>
        <dl class="kv">
          <dt>{gettext("State")}</dt>
          <dd id="link-word"><Layouts.link_state link={@link} /></dd>
          <dt>{gettext("Server")}</dt>
          <dd id="link-targets">
            <div :for={t <- @tournaments} id={"link-target-#{t.id}"}>
              <b :if={@many?}>{@names[t.id] || gettext("This box")}:</b>
              <%= if t.server_url == "" do %>
                <%= if t.kind == "linked" do %>
                  {gettext("not on a results site (yet)")}
                <% else %>
                  <.link navigate={~p"/setup"}>{gettext("not set up yet")}</.link>
                <% end %>
              <% else %>
                <span class="mono">{t.server_url}</span>
                · {t.slug}
                <span :if={t.relay_key == ""} class="note">
                  {gettext("- no relay key: nothing is sent there")}
                </span>
              <% end %>
            </div>
          </dd>
          <dt>{gettext("Waiting")}</dt>
          <dd id="waiting-count">{@link.pending}</dd>
          <dt>{gettext("Last success")}</dt>
          <dd id="last-ok">
            {if @link.last_ok,
              do: Words.time(@link.last_ok),
              else: gettext("none since the box started")}
          </dd>
          <dt :if={@link.last_error && @link.state in [:offline, :blocked]}>{gettext("Why not")}</dt>
          <dd :if={@link.last_error && @link.state in [:offline, :blocked]} id="last-error">
            {Words.link_error(@link.last_error)}
          </dd>
          <dt :if={@link.next_try_at && @link.state in [:offline, :blocked]}>
            {gettext("Next try")}
          </dt>
          <dd :if={@link.next_try_at && @link.state in [:offline, :blocked]}>
            {Words.time(@link.next_try_at)}
          </dd>
        </dl>
        <p class="note" style="margin-top:0.8rem">
          {gettext(
            "Every move is written on the box before it is sent, and stays here until the server has answered for it. Without a connection the box simply keeps them; they go out in order when it is back."
          )}
        </p>
      </.panel>

      <.panel id="destinations" title={gettext("Where the games go")}>
        <p class="note">
          {gettext(
            "Each destination has its own queue and its own patience. One being offline, refused or switched off never holds up another."
          )}
        </p>
        <ul class="dests">
          <li :for={d <- @destinations} id={"dest-#{d.id}"} class="dest">
            <% {tone, icon, word} = DestinationWords.state(d) %>
            <div class="row">
              <b>{DestinationWords.name(d.id)}</b>
              <.badge id={"dest-state-#{d.id}"} tone={tone} icon={icon}>{word}</.badge>
              <span id={"dest-waiting-#{d.id}"} class="note">
                {gettext("%{n} waiting", n: d.pending)}
              </span>
            </div>
            <p class="note">{DestinationWords.about(d.id)}</p>
            <p id={"dest-line-#{d.id}"} class="dest-line">
              {gettext("Last success: %{t}.",
                t:
                  if(d.last_ok,
                    do: Words.time(d.last_ok),
                    else: gettext("none since the box started")
                  )
              )}
              <span :if={d.last_error && d.state in [:offline, :blocked]} id={"dest-error-#{d.id}"}>
                {DestinationWords.error(d.last_error)}
              </span>
              <span :if={d.next_try_at && d.state in [:offline, :blocked]}>
                {gettext("Next try at %{t}.", t: Words.time(d.next_try_at))}
              </span>
            </p>
            <ul :if={@many?} id={"dest-by-#{d.id}"} class="note">
              <li
                :for={t <- @tournaments}
                :if={Map.get(@waiting_by[d.id] || %{}, t.id, 0) > 0}
                id={"dest-by-#{d.id}-#{t.id}"}
              >
                {gettext("%{name}: %{n} waiting",
                  name: @names[t.id] || gettext("This box"),
                  n: Map.get(@waiting_by[d.id] || %{}, t.id, 0)
                )}
              </li>
            </ul>
            <ul
              :if={d.id == "openpairings" and @pairing_refused != []}
              id="pairing-refused"
              class="note"
            >
              <li :for={{game, message} <- @pairing_refused} id={"pairing-refused-#{game.id}"}>
                <.link navigate={Scope.game_path(game.tournament_id, game.round, game.board_no)}>
                  {gettext("Round %{r}, board %{n}", r: game.round, n: game.board_no)}
                </.link>
                : {DestinationWords.report_error(message)}
              </li>
            </ul>
            <ul :if={d.id == "lichess" and @lichess_refused != []} id="lichess-refused" class="note">
              <li :for={{game, message} <- @lichess_refused}>
                {gettext("Lichess refused board %{n}: %{message}", n: game.board_no, message: message)}
              </li>
            </ul>
            <div class="row">
              <.button
                id={"dest-send-#{d.id}"}
                small
                icon="send"
                phx-click="dest_send"
                phx-value-id={d.id}
                disabled={!d.enabled?}
              >
                {gettext("Send now")}
              </.button>
              <.button id={"dest-toggle-#{d.id}"} small phx-click="dest_toggle" phx-value-id={d.id}>
                {if d.enabled?, do: gettext("Switch off"), else: gettext("Switch on")}
              </.button>
              <.button
                :if={
                  d.id == "openpairings" and
                    Enum.any?(@pairing_refused, fn {_game, message} -> message == "stale" end)
                }
                id="force-pairing"
                small
                phx-click="force_pairing"
                data-confirm={
                  gettext(
                    "OpenPairings holds a newer report of these games than this box has - from another box, or from this one before it was set up again. Replace what it holds with what this box has?"
                  )
                }
              >
                {gettext("Send again, whatever is held")}
              </.button>
              <.link :if={d.state == :unconfigured} navigate={~p"/setup"}>
                {gettext("Set it up")}
              </.link>
            </div>
          </li>
        </ul>
      </.panel>

      <.panel id="waiting" title={gettext("Waiting (%{n})", n: @link.pending)} flush>
        <div :if={@waiting == []} class="empty">{gettext("Nothing is waiting.")}</div>
        <.entries :if={@waiting != []} id="waiting-table" entries={@waiting} mode={:waiting} />
      </.panel>

      <.panel
        :if={@rejected != []}
        id="rejected"
        title={gettext("Refused by the server (%{n})", n: @counts["rejected"] || 0)}
        flush
      >
        <.entries id="rejected-table" entries={@rejected} mode={:rejected} />
      </.panel>

      <.panel id="sent" title={gettext("Sent lately")} flush>
        <:actions>
          <.button :if={@sent != []} id="prune" small phx-click="prune">{gettext("Clear the list")}</.button>
        </:actions>
        <div :if={@sent == []} class="empty">{gettext("Nothing has been sent yet.")}</div>
        <.entries :if={@sent != []} id="sent-table" entries={@sent} mode={:sent} />
      </.panel>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :entries, :list, required: true
  attr :mode, :atom, required: true

  defp entries(assigns) do
    ~H"""
    <div class="table-wrap">
      <table id={@id}>
        <thead>
          <tr>
            <th>{gettext("Round")}</th>
            <th>{gettext("Board")}</th>
            <th>{gettext("What")}</th>
            <th>{if @mode == :sent, do: gettext("Sent"), else: gettext("Queued")}</th>
            <th :if={@mode != :sent}>{gettext("Tries")}</th>
            <th :if={@mode != :waiting}>{gettext("Note")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={entry <- @entries} id={"#{@id}-#{entry.id}"}>
            <td>{entry.round}</td>
            <td>
              <.link navigate={Scope.game_path(entry.tournament_id, entry.round, entry.board_no)}>{entry.board_no}</.link>
            </td>
            <td>{what(entry)}</td>
            <td>{Words.time(if @mode == :sent, do: entry.sent_at, else: entry.inserted_at)}</td>
            <td :if={@mode != :sent}>{entry.attempts}</td>
            <td :if={@mode != :waiting}>
              {Words.entry_error(entry.error)}
              <span :if={entry.detail} class="note">{entry.detail}</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
