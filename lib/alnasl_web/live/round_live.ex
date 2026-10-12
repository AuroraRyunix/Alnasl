defmodule AlnaslWeb.RoundLive do
  @moduledoc """
  The main screen during play: every board of the round at a glance.

  A tile per board: who plays, the position the box is sure of, the clocks,
  the last move, and the state as a shape and a word. A board that needs the
  arbiter stands out by its frame as well as its colour, and is counted at
  the top. A tile is a link to the board's own page, where the repair tools
  are.

  A box that serves several tournaments shows them one under the other,
  each at its own round, with its own "start round" and its own "ready or
  not" - and a row of names at the top to look at one of them alone. A box
  with one tournament looks as it always did.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Boards, Games, OpenPairings, Outbox, Position, Tables, Tournaments}
  alias AlnaslWeb.{Scope, TableWords}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Boards.subscribe()
      Tournaments.subscribe()
    end

    {:ok, assign(socket, refresh_due?: false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    round =
      case Integer.parse(params["round"] || "") do
        {n, ""} when n > 0 -> n
        _none -> nil
      end

    # One tournament alone when the address names one, or a round.
    only = if params["tid"] || round, do: Scope.tournament(params).id

    {:noreply, socket |> assign(only: only, asked_round: round) |> load()}
  end

  defp load(socket) do
    %{only: only, asked_round: asked} = socket.assigns
    active = Tournaments.active()
    snapshots = Boards.snapshots()

    shown =
      cond do
        only == nil -> active
        found = Enum.find(active, &(&1.id == only)) -> [found]
        true -> [Tournaments.get(only) || Tournaments.default()]
      end

    sections = Enum.map(shown, &section(&1, asked || &1.round, snapshots))
    alarms = sections |> Enum.map(& &1.alarms) |> Enum.sum()

    title =
      case sections do
        [one] -> gettext("Round %{n}", n: one.round)
        _several -> gettext("Rounds")
      end

    assign(socket,
      sections: sections,
      active: active,
      many?: length(active) > 1,
      alarms: alarms,
      title: title,
      page_title: title,
      configured?: Outbox.configured?() or Tournaments.links() != [],
      refresh_due?: false
    )
  end

  defp section(tournament, round, snapshots) do
    tid = tournament.id

    here =
      for s <- snapshots,
          s[:tournament_id] == tid,
          s.round == round,
          s.board_no != nil,
          into: %{},
          do: {s.board_no, s}

    games = Map.new(Games.list(tid, round), &{&1.board_no, &1})
    pairings = Map.new(Tournaments.boards(tid, round), &{&1.board, &1})

    numbers =
      Enum.uniq(Map.keys(pairings) ++ Map.keys(here) ++ Map.keys(games)) |> Enum.sort()

    tiles = for no <- numbers, do: tile(tid, no, here[no], games[no], pairings[no] || %{})
    counts = Enum.frequencies_by(tiles, & &1.state)
    checks = Tables.checks(tid, round, snapshots)
    info = Tournaments.info(tid)

    %{
      tournament: tournament,
      tid: tid,
      title: Tournaments.title(tournament),
      linked?: Tournaments.linked?(tournament),
      round: round,
      current?: round == tournament.round,
      # The round the pairing program says is on, when the box looks elsewhere.
      remote_round:
        if(tournament.remote_round && tournament.remote_round != tournament.round,
          do: tournament.remote_round
        ),
      gone?: tournament.gone,
      time_control: info.time_control,
      tiles: tiles,
      counts: counts,
      alarms:
        Map.get(counts, :out_of_sync, 0) + Map.get(counts, :no_signal, 0) +
          Map.get(counts, :clock_alarm, 0),
      flagged: Enum.count(tiles, & &1.pairing_flag),
      rounds:
        Enum.uniq(Tournaments.rounds(tid) ++ Games.rounds(tid) ++ [round, tournament.round])
        |> Enum.sort(),
      ready?: Tables.ready?(checks),
      not_ready: Enum.count(checks, &(&1.level in [:bad, :warn])),
      has_boards?: Enum.any?(snapshots, &(&1[:tournament_id] == tid))
    }
  end

  defp tile(tid, no, snap, game, pairing) do
    {fen, last} =
      cond do
        snap && snap[:fen] -> {snap.fen, snap[:last_move]}
        game -> Games.position(game)
        true -> {nil, nil}
      end

    plies = (snap && snap.plies) || (game && Games.plies(game)) || []
    state = tile_state(snap, game)

    %{
      no: no,
      dom: Scope.dom(tid, no),
      path: Scope.game_path(tid, (snap && snap.round) || (game && game.round) || 1, no),
      white: (snap && snap[:white]) || (game && game.white) || pairing[:white],
      black: (snap && snap[:black]) || (game && game.black) || pairing[:black],
      white_rating: pairing[:white_rating],
      black_rating: pairing[:black_rating],
      label: if(pairing[:label] not in [nil, "", to_string(no)], do: pairing[:label]),
      state: state,
      position: fen && fen |> Position.from_fen() |> then(&(&1 && Position.to_text(&1))),
      last: last,
      clock: snap && snap[:clock],
      count: length(plies),
      last_san: plies |> List.last() |> then(&(&1 && &1.san)),
      result: (game && game.result) || (snap && snap[:result]),
      finished?: state == :finished,
      suggestion: snap && snap[:suggestion],
      paused: (snap && snap[:paused]) || (game && game.paused) || false,
      warning: snap && snap[:warning],
      unseen: (snap && snap[:unseen]) || [],
      # An alarm that has a name: a move out of turn, a move that is not one.
      alarm: snap && snap[:status] == :out_of_sync && AlnaslWeb.Words.alarm(snap[:detail]),
      reconstructed: Enum.count(plies, &(:recovered in &1.flags)),
      guessed: Enum.count(plies, &(:guessed in &1.flags)),
      # The pairing changed under a game that had begun: the arbiter's to settle.
      pairing_flag: game && game.pairing_flag,
      # The clock's part of the start check, while no move has been made.
      clock_problem:
        if(snap && plies == [], do: AlnaslWeb.Words.clock_problem(snap[:clock_check])),
      board_name: snap && snap.name,
      # Small, under the big board number: which physical board feeds it.
      sticker: snap && TableWords.sticker(snap),
      published: pairing[:result]
    }
  end

  defp tile_state(nil, nil), do: :unlinked
  defp tile_state(nil, %{status: "finished"}), do: :finished
  defp tile_state(nil, _game), do: :unlinked
  defp tile_state(snap, _game), do: snap.status

  # The id of something that exists once per tournament: as it always was
  # for the box's own, with the tournament in it for another.
  defp sid(base, tid) do
    if tid == Tournaments.default_id(), do: base, else: "#{base}-t#{tid}"
  end

  defp tournament_of(%{"t" => text}) do
    case Integer.parse(text || "") do
      {id, ""} -> Tournaments.get(id) || Tournaments.default()
      _none -> Tournaments.default()
    end
  end

  defp tournament_of(_params), do: Tournaments.default()

  defp section_round(socket, tid) do
    case Enum.find(socket.assigns.sections, &(&1.tid == tid)) do
      nil -> Tournaments.round_in_play(tid)
      section -> section.round
    end
  end

  # --- events ------------------------------------------------------------------

  @impl true
  # "Ask now": what the pairing program has for this tournament, without
  # waiting for the next poll.
  def handle_event("refresh", params, socket) do
    tournament = tournament_of(params)

    case Tournaments.link_of(tournament) do
      nil ->
        {:noreply, socket}

      link ->
        case OpenPairings.poll(link, force: true) do
          {:ok, _link} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("OpenPairings was asked: this is what it has."))
             |> load()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, AlnaslWeb.LinkWords.error(reason))}
        end
    end
  end

  def handle_event("next_round", params, socket) do
    tournament = tournament_of(params)
    next = section_round(socket, tournament.id) + 1
    Boards.start_round(tournament.id, next)

    socket = put_flash(socket, :info, gettext("The boards now follow round %{n}.", n: next))

    if match?([_one], socket.assigns.sections),
      do: {:noreply, push_patch(socket, to: Scope.round_path(tournament.id, next))},
      else: {:noreply, load(socket)}
  end

  # The pairing program is on another round than the box shows: follow it.
  def handle_event("follow", params, socket) do
    tournament = tournament_of(params)

    case tournament.remote_round do
      round when is_integer(round) ->
        Boards.start_round(tournament.id, round)

        socket = put_flash(socket, :info, gettext("The boards now follow round %{n}.", n: round))

        if match?([_one], socket.assigns.sections),
          do: {:noreply, push_patch(socket, to: Scope.round_path(tournament.id, round))},
          else: {:noreply, load(socket)}

      _none ->
        {:noreply, socket}
    end
  end

  # The tile's own menu: a result, or the next game, without opening the board.
  def handle_event("result", %{"board" => no, "result" => result} = params, socket) do
    tournament = tournament_of(params)
    round = section_round(socket, tournament.id)

    case Boards.set_game_result(tournament.id, round, String.to_integer(no), result) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           if(result == "*",
             do: gettext("Board %{n}: closed without a result.", n: no),
             else: gettext("Board %{n}: %{r}", n: no, r: result)
           )
         )
         |> load()}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("The result could not be set."))}
    end
  end

  def handle_event("new_game", %{"board" => no} = params, socket) do
    tournament = tournament_of(params)
    round = section_round(socket, tournament.id)
    no = String.to_integer(no)

    board =
      Enum.find(
        Boards.list(),
        &(&1.tournament_id == tournament.id and &1.round == round and &1.board_no == no)
      )

    case board && Boards.new_game(board.id) do
      :ok ->
        {:noreply,
         socket |> put_flash(:info, gettext("Board %{n}: a new game.", n: no)) |> load()}

      _not_running ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("No connected board is linked to board %{n}.", n: no)
         )}
    end
  end

  def handle_event("make_current", params, socket) do
    tournament = tournament_of(params)
    round = section_round(socket, tournament.id)
    Boards.move_to_round(tournament.id, round)

    {:noreply,
     socket
     |> put_flash(:info, gettext("The boards now follow round %{n}.", n: round))
     |> load()}
  end

  # Boards change several times a second during a move; the grid is redrawn
  # at most three times a second.
  @impl true
  def handle_info({:board, _id}, %{assigns: %{refresh_due?: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:board, _id}, socket) do
    Process.send_after(self(), :refresh, 300)
    {:noreply, assign(socket, refresh_due?: true)}
  end

  # A round started by the pairing program, a tournament that appeared.
  def handle_info({:tournament, _id}, socket), do: handle_info({:board, nil}, socket)

  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  # --- page --------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:round}
      link={@link}
      update={@update}
      box={@box}
      locale={@locale}
      alarms={@alarms}
      title={@title}
      subtitle={
        case @sections do
          [one] -> one.title
          _several -> nil
        end
      }
    >
      <:actions>
        <div
          :if={@many?}
          id="tournament-filter"
          class="seg"
          role="group"
          aria-label={gettext("Tournaments")}
        >
          <.link id="filter-all" patch={~p"/"} aria-current={to_string(@only == nil)}>
            {gettext("All")}
          </.link>
          <.link
            :for={t <- @active}
            id={"filter-#{t.id}"}
            patch={~p"/t/#{t.id}"}
            aria-current={to_string(@only == t.id)}
          >
            {Tournaments.title(t) || gettext("This box")}
          </.link>
        </div>
        <.section_actions :if={match?([_one], @sections)} section={hd(@sections)} />
      </:actions>

      <section
        :for={section <- @sections}
        id={sid("round-section", section.tid)}
        class="round-section"
        aria-label={section.title || gettext("This box")}
      >
        <header
          :if={length(@sections) > 1}
          id={sid("round-head", section.tid)}
          class="row spread round-head"
        >
          <h2>
            {section.title || gettext("This box")}
            <span class="note">{gettext("Round %{n}", n: section.round)}</span>
          </h2>
          <div class="row"><.section_actions section={section} /></div>
        </header>

        <p
          :if={section.gone?}
          id={sid("round-gone", section.tid)}
          class="callout warn"
          role="status"
        >
          {gettext(
            "OpenPairings no longer lists this tournament for the box's connect code: it was removed, archived or taken out of its group there. Nothing is reported to it any more. Its boards keep running; remove the tournament in Setup when you are done with it."
          )}
        </p>

        <p
          :if={section.remote_round && section.current?}
          id={sid("round-behind", section.tid)}
          class="callout"
          role="status"
        >
          {gettext("OpenPairings is on round %{n}; the boards follow round %{here}.",
            n: section.remote_round,
            here: section.round
          )}
          <.button id={sid("follow", section.tid)} small phx-click="follow" phx-value-t={section.tid}>
            {gettext("Follow round %{n}", n: section.remote_round)}
          </.button>
        </p>

        <div class="row round-meta">
          <.link
            :if={section.has_boards? and section.current?}
            id={sid("round-ready", section.tid)}
            navigate={~p"/boards"}
            class="row"
            style="gap:0.3rem"
          >
            <.badge :if={section.ready?} tone="ok" icon="ok">
              {gettext("Ready for round %{n}", n: section.round)}
            </.badge>
            <.badge :if={!section.ready?} tone="warn" icon="warning">
              {gettext("Round %{n}: %{count} thing(s) to look at",
                n: section.round,
                count: section.not_ready
              )}
            </.badge>
          </.link>
          <span :if={section.time_control} id={sid("round-tc", section.tid)} class="note">
            {section.time_control}
          </span>
          <.badge
            :if={section.flagged > 0}
            id={sid("round-flagged", section.tid)}
            tone="bad"
            icon="warning"
          >
            {gettext("%{count} board(s): pairing changed", count: section.flagged)}
          </.badge>
        </div>

        <div
          :if={section.tiles != []}
          id={sid("round-summary", section.tid)}
          class="summary"
          aria-label={gettext("Boards by state")}
        >
          <span
            :for={
              state <- [
                :out_of_sync,
                :no_signal,
                :clock_alarm,
                :recovered,
                :live,
                :settling,
                :waiting_start,
                :finished,
                :unlinked
              ]
            }
            :if={section.counts[state]}
            class="row"
            style="gap:0.3rem"
          >
            <b>{section.counts[state]}</b><.state state={state} />
          </span>
        </div>

        <div :if={section.tiles == []} id={sid("round-empty", section.tid)} class="panel">
          <div class="empty">
            <b>{gettext("No boards in round %{n} yet", n: section.round)}</b>
            <%= cond do %>
              <% section.linked? -> %>
                <p>
                  {gettext(
                    "OpenPairings has not paired this round, or the box has not heard of it yet. The boards appear here by themselves when it is."
                  )}
                </p>
              <% @configured? or section.has_boards? -> %>
                <p>
                  {gettext("Link a board to a board number, or attach a game from a PGN.")}
                </p>
                <.button
                  id={sid("empty-boards", section.tid)}
                  navigate={~p"/boards"}
                  variant="primary"
                >{gettext("Go to Boards")}</.button>
              <% true -> %>
                <p>
                  {gettext(
                    "Tell the box which tournament it works for first: a connect code from OpenPairings, or a results page."
                  )}
                </p>
                <.button
                  id={sid("empty-setup", section.tid)}
                  navigate={~p"/setup"}
                  variant="primary"
                >{gettext("Go to Setup")}</.button>
            <% end %>
          </div>
        </div>

        <div
          :if={section.tiles != []}
          id={sid("tiles", section.tid)}
          class={[
            "tiles",
            length(section.tiles) <= 4 && "few",
            length(section.tiles) > 12 && "many"
          ]}
        >
          <div :for={tile <- section.tiles} id={"tile-wrap-#{tile.dom}"} class="tile-wrap">
            <.link
              id={"tile-#{tile.dom}"}
              navigate={Scope.game_path(section.tid, section.round, tile.no)}
              class={["tile", tone(tile.state), tile.pairing_flag && "flagged"]}
              aria-label={gettext("Board %{n}: %{state}", n: tile.no, state: state_word(tile.state))}
            >
              <div class="tile-head">
                <span class="tile-no">{tile.no}</span>
                <span
                  :if={@many? and section.title}
                  id={"tile-tournament-#{tile.dom}"}
                  class="flag plain"
                >{section.title}</span>
                <span :if={tile.label} id={"tile-label-#{tile.dom}"} class="flag plain">
                  {gettext("table %{label}", label: tile.label)}
                </span>
                <span :if={tile.paused} class="flag plain">{gettext("Not sending")}</span>
                <span :if={tile.warning} class="flag">{gettext("Move missing?")}</span>
                <span :for={piece <- tile.unseen} id={"tile-unseen-#{tile.dom}"} class="flag">{AlnaslWeb.Words.unseen(
                  piece
                )}</span>
                <.state state={tile.state} />
              </div>
              <div :if={tile.pairing_flag} id={"tile-pairing-#{tile.dom}"} class="tile-note">
                <.icon name="warning" />{gettext("Pairing changed in OpenPairings")}
              </div>
              <div :if={tile.alarm} id={"tile-alarm-#{tile.dom}"} class="tile-note tile-alarm">
                <.icon name="error" />{tile.alarm}
              </div>
              <div :if={tile.reconstructed + tile.guessed > 0} class="tile-marks">
                <span :if={tile.guessed > 0} id={"tile-guessed-#{tile.dom}"} class="flag guess">
                  {AlnaslWeb.Words.marks(:guessed, tile.guessed)}
                </span>
                <span
                  :if={tile.reconstructed > 0}
                  id={"tile-reconstructed-#{tile.dom}"}
                  class="flag rec"
                >
                  {AlnaslWeb.Words.marks(:recovered, tile.reconstructed)}
                </span>
              </div>
              <div class="side">
                <span class="dot black"></span>
                <span id={"tile-black-#{tile.dom}"} class="name">
                  {tile.black || gettext("Black")}
                  <span :if={tile.black_rating} class="rating">{tile.black_rating}</span>
                </span>
                <.clock
                  :if={tile.clock}
                  ms={tile.clock.black_ms}
                  running={tile.clock.running == :black}
                />
              </div>
              <div class="tile-board">
                <.board
                  position={tile.position}
                  last={tile.last}
                  label={gettext("Position on board %{n}", n: tile.no)}
                />
              </div>
              <div class="side">
                <span class="dot white"></span>
                <span id={"tile-white-#{tile.dom}"} class="name">
                  {tile.white || gettext("White")}
                  <span :if={tile.white_rating} class="rating">{tile.white_rating}</span>
                </span>
                <.clock
                  :if={tile.clock}
                  ms={tile.clock.white_ms}
                  running={tile.clock.running == :white}
                />
              </div>
              <div
                :if={tile.clock_problem && tile.state != :clock_alarm}
                id={"tile-clock-#{tile.dom}"}
                class="tile-note"
              >
                <.icon name="warning" />{tile.clock_problem}
              </div>
              <div class="tile-foot">
                <%= cond do %>
                  <% tile.result -> %>
                    <span class="last">{tile.result}</span>
                  <% tile.last_san -> %>
                    <span>{div(tile.count + 1, 2)}{if rem(tile.count, 2) == 1, do: ".", else: "..."}</span>
                    <span class="last"><.figurine san={tile.last_san} /></span>
                  <% true -> %>
                    <span>{gettext("No moves")}</span>
                <% end %>
                <span :if={tile.suggestion && !tile.result} class="flag">{gettext("Result? %{r}",
                  r: tile.suggestion
                )}</span>
                <span
                  :if={tile.board_name}
                  id={"tile-sticker-#{tile.dom}"}
                  class="right"
                  title={tile.board_name}
                >{tile.sticker}</span>
              </div>
            </.link>
            <details
              :if={tile.state != :unlinked or tile.count > 0}
              id={"tile-menu-#{tile.dom}"}
              class="tile-menu"
            >
              <summary>
                {if tile.finished?, do: gettext("Next game"), else: gettext("Finish game")}
              </summary>
              <div class="row">
                <.button
                  :for={result <- ["1-0", "1/2-1/2", "0-1"]}
                  :if={!tile.finished?}
                  id={"tile-result-#{tile.dom}-#{String.replace(result, "/", "")}"}
                  small
                  phx-click="result"
                  phx-value-t={section.tid}
                  phx-value-board={tile.no}
                  phx-value-result={result}
                >{result}</.button>
                <.button
                  :if={!tile.finished?}
                  id={"tile-result-#{tile.dom}-none"}
                  small
                  phx-click="result"
                  phx-value-t={section.tid}
                  phx-value-board={tile.no}
                  phx-value-result="*"
                  data-confirm={gettext("Close this game without a result?")}
                >{gettext("No result")}</.button>
                <.button
                  id={"tile-new-game-#{tile.dom}"}
                  small
                  variant={if tile.finished?, do: "primary"}
                  phx-click="new_game"
                  phx-value-t={section.tid}
                  phx-value-board={tile.no}
                  data-confirm={
                    if !tile.finished?,
                      do:
                        gettext("Close this game without a result and start a new one on this board?")
                  }
                >{gettext("New game")}</.button>
              </div>
            </details>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # The rounds of one tournament, "ask the pairing program now" and "start
  # the next round": at the top of the page when it shows one tournament,
  # in each tournament's own heading when it shows several.
  attr :section, :map, required: true

  defp section_actions(assigns) do
    ~H"""
    <div class="seg" role="group" aria-label={gettext("Rounds")}>
      <.link
        :for={n <- @section.rounds}
        id={sid("round", @section.tid) <> "-#{n}"}
        patch={Scope.round_path(@section.tid, n)}
        aria-current={to_string(n == @section.round)}
      >
        {n}
      </.link>
    </div>
    <.button
      :if={@section.linked? and not @section.gone?}
      id={sid("refresh-pairings", @section.tid)}
      small
      phx-click="refresh"
      phx-value-t={@section.tid}
    >{gettext("Ask OpenPairings now")}</.button>
    <.button
      id={sid("next-round", @section.tid)}
      small
      phx-click="next_round"
      phx-value-t={@section.tid}
      data-confirm={
        if @section.linked?,
          do:
            gettext(
              "Move this tournament's boards to round %{n} by hand? Normally the box does this by itself when OpenPairings pairs the round. The games of this round stay as they are.",
              n: @section.round + 1
            ),
          else:
            gettext(
              "Move every linked board to round %{n}? The games of this round stay as they are.",
              n: @section.round + 1
            )
      }
    >
      {gettext("Start round %{n}", n: @section.round + 1)}
    </.button>
    """
  end
end
