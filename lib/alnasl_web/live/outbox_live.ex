defmodule AlnaslWeb.OutboxLive do
  @moduledoc """
  The connection to the results server, honestly: connected or not, when it
  last worked, how much is waiting, and why it is not going - in words.

  And the queue itself: what is waiting (oldest first, the order it will be
  sent in), what the server refused and why, and what went out lately.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Destination, Games, Outbox, ResultsSite, Tournaments}
  alias Alnasl.Destination.{LichessBroadcast, OpenPairings}
  alias AlnaslWeb.{DestinationWords, LinkWords, Scope, Status, Words}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Alnasl.Boards.subscribe()

    {:ok, socket |> assign(page_title: gettext("Results"), refresh_due?: false) |> load()}
  end

  defp load(socket) do
    account = socket.assigns.current_scope
    ids = Alnasl.Halls.tournament_ids(account)
    tournaments = Alnasl.Halls.active(account)

    waiting_by = %{
      "openresults" => Outbox.pending_by_tournament(),
      "lichess" => LichessBroadcast.pending_by_tournament(),
      "openpairings" => OpenPairings.pending_by_tournament()
    }

    assign(socket,
      waiting: Outbox.list("pending", 60, ids),
      rejected: Outbox.list("rejected", 30, ids),
      sent: Outbox.list("sent", 30, ids),
      counts: Outbox.counts(ids),
      destinations: Destination.statuses(),
      plans: Map.new(Destination.all(), &{&1.id(), Destination.send_plan(&1)}),
      linked:
        if(account.open?,
          do: Alnasl.Seating.linked(),
          else:
            Alnasl.Halls.here(
              account,
              Enum.filter(Tournaments.list(), &(&1.kind == "linked" and not &1.gone))
            )
        ),
      links: Alnasl.Halls.here(account, Tournaments.links()),
      lichess_refused: LichessBroadcast.refused(),
      pairing_refused: OpenPairings.refused(),
      tournaments: tournaments,
      staying_home: staying_home(tournaments),
      names: Map.new(Tournaments.list(), &{&1.id, Tournaments.title(&1)}),
      many?: length(tournaments) > 1,
      waiting_by: waiting_by,
      why_waiting: Outbox.waiting_report(ids),
      pending_here: Map.new(waiting_by, fn {id, by} -> {id, here_sum(by, ids)} end),
      refresh_due?: false
    )
  end

  # What waits for this hall's tournaments; all of it when there is no hall.
  defp here_sum(by, nil), do: by |> Map.values() |> Enum.sum()
  defp here_sum(by, ids), do: by |> Map.take(ids) |> Map.values() |> Enum.sum()

  # Boards in the round in play that play a game which stays on the box:
  # nothing of it is waiting, and the arbiter is told why.
  defp staying_home(tournaments) do
    for t <- tournaments,
        game <- Games.staying_home(t.id, Tournaments.round_in_play(t.id)) do
      %{tournament: t, game: game}
    end
  end

  @impl true
  # The big button: every destination that has something to do is nudged, and
  # the ones that have not say why - in words, not in silence.
  def handle_event("send_now", _params, socket) do
    plans = Map.new(Destination.all(), &{&1.id(), {&1, Destination.send_plan(&1)}})
    go = for {id, {module, {:go, n}}} <- plans, do: {id, module, n}
    quiet = for {id, {_module, {:quiet, why}}} <- plans, do: {id, why}

    for {_id, module, _n} <- go, do: Destination.send_now(module)
    for {id, _module, n} <- go, do: schedule_report(id, n)

    trying =
      Enum.map_join(go, "; ", fn {id, _m, n} ->
        gettext("%{name}: %{n} waiting, trying now", name: DestinationWords.name(id), n: n)
      end)

    why =
      Enum.map_join(quiet, " ", fn {id, why} ->
        DestinationWords.name(id) <> ": " <> DestinationWords.quiet(why)
      end)

    socket =
      case go do
        [] -> put_flash(socket, :info, gettext("Nothing to send. ") <> why)
        _some -> put_flash(socket, :info, trying)
      end

    {:noreply, socket}
  end

  # One destination's own "send now": the others are left to their pauses.
  def handle_event("dest_send", %{"id" => id}, socket) do
    module = Destination.get(id)

    case module && Destination.send_plan(module) do
      {:go, n} ->
        Destination.send_now(module)
        schedule_report(id, n)

        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("%{name}: %{n} waiting, trying now.", name: DestinationWords.name(id), n: n)
         )}

      {:quiet, why} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           DestinationWords.name(id) <> ": " <> DestinationWords.quiet(why)
         )}

      nil ->
        {:noreply, socket}
    end
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
    # Whatever is held for another hall's tournaments is not this arbiter's to overrule.
    scope = socket.assigns.current_scope

    ids =
      if Alnasl.Accounts.Scope.everything?(scope),
        do: nil,
        else: Alnasl.Halls.tournament_ids(scope)

    count = OpenPairings.force(ids)

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("%{n} game(s) are sent again, to replace what is held.", n: count)
     )
     |> load()}
  end

  # Rows that can go nowhere, thrown away - one tournament's, and only when
  # the arbiter presses the button (there is a confirm). Never by itself.
  def handle_event("discard", %{"id" => id}, socket) do
    tournament_id = String.to_integer(id)

    stuck? =
      Enum.any?(
        socket.assigns.why_waiting,
        &(&1.tournament_id == tournament_id and &1.why in [:gone, :no_page])
      )

    socket =
      with true <- stuck?,
           {:ok, n} <- Outbox.discard(tournament_id) do
        put_flash(socket, :info, gettext("%{n} move(s) discarded.", n: n))
      else
        _no -> put_flash(socket, :error, gettext("Those moves can still be sent, so they stay."))
      end

    {:noreply, load(socket)}
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

  # A board changed (a new game on it, say): what stays on the box may have.
  def handle_info({:board, _id}, socket), do: handle_info(:outbox_changed, socket)

  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  # What came of a nudge: how much went, or why not.
  def handle_info({:report, id, before}, socket) do
    socket = load(socket)
    d = Enum.find(socket.assigns.destinations, &(&1.id == id))
    name = DestinationWords.name(id)

    flash =
      cond do
        d == nil ->
          nil

        d.pending == 0 ->
          {:info, gettext("%{name}: %{n} sent. Nothing is waiting now.", name: name, n: before)}

        d.state in [:offline, :blocked] and d.last_error ->
          {:error,
           gettext("%{name}: not sent (%{n} waiting). %{why}",
             name: name,
             n: d.pending,
             why: DestinationWords.error(d.last_error)
           )}

        true ->
          {:info,
           gettext("%{name}: %{sent} sent, %{n} still waiting.",
             name: name,
             sent: max(before - d.pending, 0),
             n: d.pending
           )}
      end

    case flash do
      nil -> {:noreply, socket}
      {kind, text} -> {:noreply, put_flash(socket, kind, text)}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp waiting_name(%{why: :gone}), do: gettext("A tournament that is gone")
  defp waiting_name(%{title: nil}), do: gettext("The hall's own tournament")
  defp waiting_name(%{title: title}), do: title

  defp schedule_report(id, before), do: Process.send_after(self(), {:report, id, before}, 2_500)

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
      help={:outbox}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      scope={@current_scope}
      path={@current_path}
      title={gettext("Results")}
    >
      <:actions>
        <.button
          id="send-now"
          icon="send"
          variant="primary"
          phx-click="send_now"
          disabled={Enum.all?(@plans, fn {_id, plan} -> match?({:quiet, _}, plan) end)}
        >{gettext("Send now")}</.button>
      </:actions>

      <.panel :if={@linked != []} id="linked-panel" title={gettext("Linked tournaments")}>
        <p class="note">
          {gettext(
            "These are the tournaments in use. Each is reported to OpenPairings, and sent to its results site when it has one and OpenPairings has given Alnasl a relay key for it."
          )}
        </p>

        <ul class="dests">
          <li :for={l <- @links} id={"linked-link-#{l.id}"} class="dest">
            <% {tone, icon, word} = LinkWords.state(l) %>
            <div class="row">
              <b>{LinkWords.about(l)}</b>
              <.badge id={"linked-link-state-#{l.id}"} tone={tone} icon={icon}>{word}</.badge>

              <span class="note">
                {gettext("Last contact: %{t}.",
                  t: if(l.last_ok_at, do: Words.time(l.last_ok_at), else: gettext("never"))
                )}
              </span>
            </div>
          </li>

          <li :for={t <- @linked} id={"linked-#{t.id}"} class="dest">
            <% {rtone, rtext} = Status.results_line(t) %>
            <div class="row">
              <b>{Tournaments.title(t)}</b>
              <.badge
                id={"linked-results-#{t.id}"}
                tone={rtone}
                icon={
                  if rtone == "ok",
                    do: "live",
                    else: if(rtone == "warn", do: "warning", else: "waiting")
                }
              >
                {cond do
                  t.server_url == "" -> gettext("OpenPairings only")
                  t.relay_key == "" -> gettext("No relay key yet")
                  true -> gettext("Results site")
                end}
              </.badge>
            </div>

            <p
              id={"linked-results-line-#{t.id}"}
              class={["dest-line", rtone == "warn" && "warn-text"]}
            >
              {rtext}
            </p>
          </li>
        </ul>
      </.panel>

      <.panel
        id="link-panel"
        title={
          if @linked == [],
            do: gettext("Connection to the results site"),
            else: gettext("Results site")
        }
      >
        <dl class="kv">
          <dt>{gettext("State")}</dt>

          <dd id="link-word">
            <%= if @linked == [] do %>
              <Layouts.link_state link={@link} />
            <% else %>
              <% result = Status.results(@linked, @link, @current_scope) %>
              <%= if result do %>
                <% {tone, icon, text} = result %>
                <.badge tone={tone} icon={icon}>{text}</.badge>
              <% else %>
                <.badge icon="waiting">{gettext("OpenPairings only")}</.badge>
              <% end %>
            <% end %>
          </dd>

          <dt>{gettext("Results site")}</dt>

          <dd id="link-targets">
            <div :for={t <- @tournaments} id={"link-target-#{t.id}"}>
              <b :if={@many?}>{@names[t.id] || gettext("The hall's own tournament")}:</b>
              <%= if t.server_url == "" do %>
                <%= if t.kind == "linked" do %>
                  {gettext("not on a results site (yet)")}
                <% else %>
                  <.link navigate={~p"/setup/results"}>{gettext("not set up yet")}</.link>
                <% end %>
              <% else %>
                <span class="mono">{t.server_url}</span>
                · {t.slug}
                <.site_link
                  :if={ResultsSite.page?(t)}
                  id={"link-target-open-#{t.id}"}
                  href={ResultsSite.tournament_url(t)}
                >
                  {gettext("Open")}
                </.site_link>

                <span :if={t.relay_key == ""} class="note">
                  {gettext("- no relay key yet: nothing is sent there")}
                </span>
              <% end %>
            </div>
          </dd>

          <dt>{gettext("Waiting")}</dt>

          <dd id="waiting-count">{@link.pending}</dd>

          <dt :if={@why_waiting != []}>{gettext("Why")}</dt>

          <dd :if={@why_waiting != []} id="waiting-why">
            <ul class="note">
              <li :for={w <- @why_waiting} id={"waiting-why-#{w.tournament_id}"}>
                {gettext("%{name}: %{n} waiting - %{why}",
                  name: waiting_name(w),
                  n: w.count,
                  why: DestinationWords.waiting_why(w.why)
                )}
                <.button
                  :if={w.why in [:gone, :no_page]}
                  id={"discard-#{w.tournament_id}"}
                  small
                  phx-click="discard"
                  phx-value-id={w.tournament_id}
                  data-confirm={
                    gettext(
                      "Discard these %{n} moves? They will never be sent to the results site. The games themselves stay in Alnasl.",
                      n: w.count
                    )
                  }
                >
                  {gettext("Discard these %{n} moves", n: w.count)}
                </.button>
              </li>
            </ul>
          </dd>

          <dt>{gettext("Last success")}</dt>

          <dd id="last-ok">
            {if @link.last_ok,
              do: Words.time(@link.last_ok),
              else: gettext("none since Alnasl started")}
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

        <p class="note mt-5">
          {gettext(
            "Every move is written down by Alnasl before it is sent, and stays here until the results site has answered for it. Without a connection Alnasl simply keeps them; they go out in order when it is back."
          )}
        </p>
      </.panel>

      <.panel id="destinations" title={gettext("Where the games go")}>
        <p class="note">
          {gettext(
            "Each destination has its own queue and its own patience. One being offline, refused or switched off never holds up another."
          )}
        </p>

        <p id="auto-note" class="note">
          {gettext(
            "Sending is automatic: OpenPairings and the results site start by themselves as soon as there is somewhere to send to, and a game recorded before that goes out in full. Send now only nudges a destination that is waiting out a pause."
          )}
        </p>

        <ul class="dests">
          <li :for={d <- @destinations} id={"dest-#{d.id}"} class="dest">
            <% {tone, icon, word} = DestinationWords.state(d) %>
            <div class="row">
              <b>{DestinationWords.name(d.id)}</b>
              <.badge id={"dest-state-#{d.id}"} tone={tone} icon={icon}>{word}</.badge>

              <span id={"dest-waiting-#{d.id}"} class="note">
                {gettext("%{n} waiting", n: @pending_here[d.id] || 0)}
              </span>
            </div>

            <p class="note">{DestinationWords.about(d.id)}</p>

            <p id={"dest-line-#{d.id}"} class="dest-line">
              {gettext("Last success: %{t}.",
                t:
                  if(d.last_ok,
                    do: Words.time(d.last_ok),
                    else: gettext("none since Alnasl started")
                  )
              )}
              <span :if={d.last_error && d.state in [:offline, :blocked]} id={"dest-error-#{d.id}"}>
                {DestinationWords.error(d.last_error)}
              </span>

              <span :if={d.next_try_at && d.state in [:offline, :blocked]}>
                {gettext("Next try at %{t}.", t: Words.time(d.next_try_at))}
              </span>
            </p>

            <ul :if={d.id == "openresults"} id="dest-sites" class="note dest-sites">
              <li :for={t <- @tournaments} id={"dest-site-#{t.id}"}>
                <b :if={@many?}>{@names[t.id] || gettext("The hall's own tournament")}:</b>
                <%= if ResultsSite.page?(t) do %>
                  {gettext("sends to")}
                  <.site_link id={"dest-site-link-#{t.id}"} href={ResultsSite.tournament_url(t)}>
                    {ResultsSite.display(t)}
                  </.site_link>
                <% else %>
                  {no_site_reason(ResultsSite.why_not(t))}
                <% end %>
              </li>
            </ul>

            <ul :if={@many?} id={"dest-by-#{d.id}"} class="note">
              <li
                :for={t <- @tournaments}
                :if={Map.get(@waiting_by[d.id] || %{}, t.id, 0) > 0}
                id={"dest-by-#{d.id}-#{t.id}"}
              >
                {gettext("%{name}: %{n} waiting",
                  name: @names[t.id] || gettext("The hall's own tournament"),
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
                disabled={!d.enabled? or match?({:quiet, _}, @plans[d.id])}
              >
                {gettext("Send now")}
              </.button>

              <span
                :if={match?({:quiet, _}, @plans[d.id])}
                id={"dest-send-why-#{d.id}"}
                class="note"
              >
                {DestinationWords.quiet(elem(@plans[d.id], 1))}
              </span>

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
                    "OpenPairings holds a newer report of these games than this copy of Alnasl has - from another copy, or from this one before it was set up again. Replace what it holds with what this copy has?"
                  )
                }
              >
                {gettext("Send again, whatever is held")}
              </.button>

              <.link :if={d.state == :unconfigured} navigate={~p"/setup/results"}>
                {gettext("Set it up")}
              </.link>
            </div>
          </li>
        </ul>
      </.panel>

      <.panel id="waiting" title={gettext("Waiting (%{n})", n: @link.pending)} flush>
        <ul :if={@staying_home != []} id="staying-home" class="note">
          <li
            :for={%{tournament: t, game: game} <- @staying_home}
            id={"staying-home-#{t.id}-#{game.board_no}"}
          >
            <b :if={@many?}>{@names[t.id] || gettext("The hall's own tournament")}:</b>
            <.link navigate={Scope.game_path(t.id, game.round, game.board_no)}>
              {gettext("Board %{n} plays a game that stays in Alnasl (game %{g}).",
                n: game.board_no,
                g: game.game_no
              )}
            </.link>
            {gettext("Nothing of it is waiting.")}
          </li>
        </ul>

        <div :if={@waiting == []} id="waiting-empty" class="empty">
          <b>{gettext("Nothing is waiting")}</b>
          <p>
            {gettext(
              "Every move read so far has been sent. Moves that cannot go out at once wait here, in order."
            )}
          </p>
        </div>
        <.entries :if={@waiting != []} id="waiting-table" entries={@waiting} mode={:waiting} />
      </.panel>

      <.panel
        :if={@rejected != []}
        id="rejected"
        title={gettext("Refused on arrival (%{n})", n: @counts["rejected"] || 0)}
        flush
      >
        <.entries id="rejected-table" entries={@rejected} mode={:rejected} />
      </.panel>

      <.panel id="sent" title={gettext("Sent lately")} flush>
        <:actions>
          <.button :if={@sent != []} id="prune" small phx-click="prune">{gettext("Clear the list")}</.button>
        </:actions>

        <div :if={@sent == []} id="sent-empty" class="empty">
          <b>{gettext("Nothing has been sent yet")}</b>
          <p>
            {gettext(
              "Moves are sent as soon as a board plays in a tournament with a results site or OpenPairings behind it. No board playing yet, or no connection? Boards and Setup are where that starts."
            )}
          </p>
        </div>
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
