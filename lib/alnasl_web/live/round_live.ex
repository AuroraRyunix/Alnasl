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

  A team event reads like one: the boards stand under their match ("Match
  3: Team A - Team B"), in the match's board order, each tile naming the
  team of each player, and the match carries its score as the boards saw
  it finish - labelled so, because the score that counts is the arbiter's,
  in OpenPairings.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Boards, Games, OpenPairings, Outbox, Position, ResultsSite, Tables, Tournaments}
  alias AlnaslWeb.{Scope, TableWords, Words}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Boards.subscribe()
      Tournaments.subscribe()
    end

    {:ok, assign(socket, refresh_due?: false, qr_cache: %{})}
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

    # The same address is drawn once, not three times a second.
    cache =
      for %{site: %{live: url}} <- sections, url != nil, into: %{} do
        {url, socket.assigns.qr_cache[url] || AlnaslWeb.Access.qr(url)}
      end

    sections = Enum.map(sections, &put_qr(&1, cache))
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
      qr_cache: cache,
      refresh_due?: false
    )
  end

  defp put_qr(%{site: %{live: url} = site} = section, cache) when url != nil,
    do: %{section | site: Map.put(site, :qr, cache[url])}

  defp put_qr(section, _cache), do: section

  # Where the results site shows this tournament: the live boards of the
  # round on the page, the live page (which the QR code leads to), and -
  # when there is nothing to link to - why.
  defp site(tournament, round) do
    case ResultsSite.why_not(tournament) do
      nil ->
        %{
          tournament: tournament,
          page: ResultsSite.tournament_url(tournament),
          live: ResultsSite.live_url(tournament),
          round_url: ResultsSite.round_url(tournament, round),
          why: nil
        }

      why ->
        %{tournament: tournament, page: nil, live: nil, round_url: nil, why: why}
    end
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
    histories = Enum.group_by(Games.all(tid, round), & &1.board_no)
    pairings = Map.new(Tournaments.boards(tid, round), &{&1.board, &1})

    numbers =
      Enum.uniq(Map.keys(pairings) ++ Map.keys(here) ++ Map.keys(games)) |> Enum.sort()

    site = site(tournament, round)

    tiles =
      for no <- numbers,
          do:
            tile(
              tid,
              round,
              no,
              here[no],
              games[no],
              pairings[no] || %{},
              histories[no] || [],
              site
            )

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
      # Names of the linked tournaments a board of the box's own plays outside of.
      outside_titles:
        if(tournament.kind == "local",
          do: Enum.map(Alnasl.Seating.linked(), &(Tournaments.title(&1) || "")),
          else: []
        ),
      time_control: info.time_control,
      site: site,
      tiles: tiles,
      matches: if(Tournaments.team_event?(tournament), do: matches(tiles)),
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

  defp tile(tid, round, no, snap, game, pairing, history, site) do
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
      # A team event: the board's match, and the team each player plays for.
      match: pairing[:match],
      white_team: pairing[:white_team],
      black_team: pairing[:black_team],
      # The result that counts for the match as the boards saw it: a game the
      # box saw finish with a result, not the arbiter's.
      seen: if(game != nil and game.status == "finished" and not game.local, do: game.result),
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
      published: pairing[:result],
      # A game that stays on the box (an extra one, or one set aside) while
      # it is being played: the arbiter is told, never left to find out.
      stays_home?: game != nil and game.local and game.status == "live",
      game_no: game && game.game_no,
      # What "New game" would be: the game of the pairing, or an extra one.
      paired?: pairing != %{},
      new_kind: Games.kind_for(history, pairing != %{}),
      site_url: site.page && ResultsSite.board_url(site.tournament, round, no)
    }
  end

  # The tiles of a team event under their matches: `[%{key, match, score,
  # tiles}]`, matches in order and each match's boards in its board order.
  # Boards no match names (a game on a board nobody paired) come last.
  defp matches(tiles) do
    {in_match, loose} = Enum.split_with(tiles, & &1.match)

    groups =
      in_match
      |> Enum.group_by(& &1.match.number)
      |> Enum.sort()
      |> Enum.map(fn {number, tiles} ->
        tiles = Enum.sort_by(tiles, & &1.match.board)
        match = hd(tiles).match
        %{key: number, match: match, score: score(match, tiles), tiles: tiles}
      end)

    if loose == [], do: groups, else: groups ++ [%{key: 0, match: nil, score: nil, tiles: loose}]
  end

  # The match as the boards saw it: points for each team from the games the
  # box saw finish. Not the official score - that is the arbiter's.
  defp score(match, tiles) do
    finished = Enum.filter(tiles, &(&1.seen in ["1-0", "0-1", "1/2-1/2"]))

    {a, b} =
      Enum.reduce(finished, {0, 0}, fn tile, {a, b} ->
        {white, black} =
          case tile.seen do
            "1-0" -> {2, 0}
            "0-1" -> {0, 2}
            _draw -> {1, 1}
          end

        a = a + if(tile.white_team == match.team_a, do: white, else: 0)
        a = a + if(tile.black_team == match.team_a, do: black, else: 0)
        b = b + if(tile.white_team == match.team_b, do: white, else: 0)
        b = b + if(tile.black_team == match.team_b, do: black, else: 0)
        {a, b}
      end)

    if finished == [],
      do: nil,
      else: %{a: a, b: b, done: length(finished), of: length(tiles)}
  end

  # Half points, counted in halves: 5 is 2½.
  defp points(halves) do
    whole = div(halves, 2)

    cond do
      rem(halves, 2) == 0 -> Integer.to_string(whole)
      whole == 0 -> "½"
      true -> "#{whole}½"
    end
  end

  defp match_title(nil), do: gettext("Boards outside the matches")

  defp match_title(match) do
    gettext("Match %{n}: %{a} - %{b}",
      n: match.number,
      a: match.team_a || "?",
      b: match.team_b || "?"
    )
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

    kind =
      case params["kind"] do
        "replace" -> :replace
        "extra" -> :extra
        _auto -> :auto
      end

    case board && Boards.new_game(board.id, kind) do
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

  # "Send this one instead": the game on the board is the one that leaves
  # the box, the one before it stays.
  def handle_event("send_this", %{"board" => no} = params, socket) do
    tournament = tournament_of(params)
    round = section_round(socket, tournament.id)
    no = String.to_integer(no)

    with %Games.Game{} = game <- Games.current(tournament.id, round, no),
         :ok <- Boards.send_this(game) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("Board %{n}: this game is the one that leaves the box now.", n: no)
       )
       |> load()}
    else
      _nothing -> {:noreply, put_flash(socket, :error, gettext("That could not be done."))}
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
      hall={@hall}
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
          <.button
            :if={section.site.round_url}
            id={sid("site-open", section.tid)}
            small
            icon="external"
            href={section.site.round_url}
            target="_blank"
            rel="noopener"
          >
            {gettext("Open the results site")}
          </.button>
          <details
            :if={section.site.live}
            id={sid("site-qr", section.tid)}
            class="site-qr"
          >
            <summary aria-label={gettext("QR code of the live page")}>QR</summary>
            <.qr_code
              id={sid("site-qr-code", section.tid)}
              text={section.site.live}
              code={section.site[:qr]}
            />
            <p id={sid("site-qr-url", section.tid)} class="note mono">{section.site.live}</p>
          </details>
          <span
            :if={section.site.why}
            id={sid("site-none", section.tid)}
            class="note"
          >
            {no_site_reason(section.site.why)}
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
          :if={section.tiles != [] and section.matches == nil}
          id={sid("tiles", section.tid)}
          class={[
            "tiles",
            length(section.tiles) <= 4 && "few",
            length(section.tiles) > 12 && "many"
          ]}
        >
          <.tile :for={tile <- section.tiles} tile={tile} section={section} many?={@many?} />
        </div>

        <%!-- A team event: the boards under their match, in the match's board order. --%>
        <div :if={section.tiles != [] and section.matches} id={sid("matches", section.tid)}>
          <section
            :for={group <- section.matches}
            id={sid("match", section.tid) <> "-#{group.key}"}
            class="match-group"
            aria-label={match_title(group.match)}
          >
            <h3 class="match-head">
              <span id={sid("match-title", section.tid) <> "-#{group.key}"}>
                {match_title(group.match)}
              </span>
              <span
                :if={group.score}
                id={sid("match-score", section.tid) <> "-#{group.key}"}
                class="match-score"
                title={
                  gettext(
                    "What the boards saw finish. The match's score is the arbiter's, in OpenPairings."
                  )
                }
              >
                {gettext("As the boards saw it: %{a} - %{b}",
                  a: points(group.score.a),
                  b: points(group.score.b)
                )}
                <span class="note">
                  {gettext("(%{done} of %{of} finished)",
                    done: group.score.done,
                    of: group.score.of
                  )}
                </span>
              </span>
            </h3>
            <div class={["tiles", length(group.tiles) <= 4 && "few"]}>
              <.tile :for={tile <- group.tiles} tile={tile} section={section} many?={@many?} />
            </div>
          </section>
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

  # One board of the round: the tile, its menu, and what stays on the box.
  attr :tile, :map, required: true
  attr :section, :map, required: true
  attr :many?, :boolean, default: false

  defp tile(assigns) do
    ~H"""
    <div id={"tile-wrap-#{@tile.dom}"} class="tile-wrap">
      <.link
        id={"tile-#{@tile.dom}"}
        navigate={Scope.game_path(@section.tid, @section.round, @tile.no)}
        class={["tile", tone(@tile.state), @tile.pairing_flag && "flagged"]}
        aria-label={gettext("Board %{n}: %{state}", n: @tile.no, state: state_word(@tile.state))}
      >
        <div class="tile-head">
          <span class="tile-no">{@tile.no}</span>
          <span
            :if={@many? and @section.title}
            id={"tile-tournament-#{@tile.dom}"}
            class="flag plain"
          >{@section.title}</span>
          <span :if={@tile.label} id={"tile-label-#{@tile.dom}"} class="flag plain">
            {gettext("table %{label}", label: @tile.label)}
          </span>
          <span :if={@tile.match} id={"tile-match-#{@tile.dom}"} class="flag plain">
            {gettext("match %{match}, board %{place}",
              match: @tile.match.number,
              place: @tile.match.board
            )}
          </span>
          <span :if={@tile.paused} class="flag plain">{gettext("Not sending")}</span>
          <span
            :if={@tile.stays_home?}
            id={"tile-local-flag-#{@tile.dom}"}
            class="flag"
          >{gettext("Stays on the box")}</span>
          <span :if={@tile.warning} class="flag">{gettext("Move missing?")}</span>
          <span :for={piece <- @tile.unseen} id={"tile-unseen-#{@tile.dom}"} class="flag">{AlnaslWeb.Words.unseen(
            piece
          )}</span>
          <.state state={@tile.state} />
        </div>
        <div
          :if={@section.outside_titles != [] and @tile.board_name}
          id={"tile-outside-#{@tile.dom}"}
          class="tile-note"
        >
          <.icon name="warning" />{gettext("Not playing in %{tournament}",
            tournament: Enum.join(@section.outside_titles, " / ")
          )}
        </div>
        <div :if={@tile.pairing_flag} id={"tile-pairing-#{@tile.dom}"} class="tile-note">
          <.icon name="warning" />{gettext("Pairing changed in OpenPairings")}
        </div>
        <div :if={@tile.alarm} id={"tile-alarm-#{@tile.dom}"} class="tile-note tile-alarm">
          <.icon name="error" />{@tile.alarm}
        </div>
        <div :if={@tile.reconstructed + @tile.guessed > 0} class="tile-marks">
          <span :if={@tile.guessed > 0} id={"tile-guessed-#{@tile.dom}"} class="flag guess">
            {AlnaslWeb.Words.marks(:guessed, @tile.guessed)}
          </span>
          <span
            :if={@tile.reconstructed > 0}
            id={"tile-reconstructed-#{@tile.dom}"}
            class="flag rec"
          >
            {AlnaslWeb.Words.marks(:recovered, @tile.reconstructed)}
          </span>
        </div>
        <div class="side">
          <span class="dot black"></span>
          <span
            id={"tile-black-#{@tile.dom}"}
            class="name"
            title={@tile.black_team && "#{@tile.black} (#{@tile.black_team})"}
          >
            {@tile.black || gettext("Black")}
            <span :if={@tile.black_rating} class="rating">{@tile.black_rating}</span>
            <span
              :if={@tile.black_team}
              id={"tile-black-team-#{@tile.dom}"}
              class="team"
            >{@tile.black_team}</span>
          </span>
          <.clock
            :if={@tile.clock}
            ms={@tile.clock.black_ms}
            running={@tile.clock.running == :black}
          />
        </div>
        <div class="tile-board">
          <.board
            position={@tile.position}
            last={@tile.last}
            label={gettext("Position on board %{n}", n: @tile.no)}
          />
        </div>
        <div class="side">
          <span class="dot white"></span>
          <span
            id={"tile-white-#{@tile.dom}"}
            class="name"
            title={@tile.white_team && "#{@tile.white} (#{@tile.white_team})"}
          >
            {@tile.white || gettext("White")}
            <span :if={@tile.white_rating} class="rating">{@tile.white_rating}</span>
            <span
              :if={@tile.white_team}
              id={"tile-white-team-#{@tile.dom}"}
              class="team"
            >{@tile.white_team}</span>
          </span>
          <.clock
            :if={@tile.clock}
            ms={@tile.clock.white_ms}
            running={@tile.clock.running == :white}
          />
        </div>
        <div
          :if={@tile.clock_problem && @tile.state != :clock_alarm}
          id={"tile-clock-#{@tile.dom}"}
          class="tile-note"
        >
          <.icon name="warning" />{@tile.clock_problem}
        </div>
        <div class="tile-foot">
          <%= cond do %>
            <% @tile.result -> %>
              <span class="last">{@tile.result}</span>
            <% @tile.last_san -> %>
              <span>{div(@tile.count + 1, 2)}{if rem(@tile.count, 2) == 1, do: ".", else: "..."}</span>
              <span class="last"><.figurine san={@tile.last_san} /></span>
            <% true -> %>
              <span>{gettext("No moves")}</span>
          <% end %>
          <span :if={@tile.suggestion && !@tile.result} class="flag">{gettext("Result? %{r}",
            r: @tile.suggestion
          )}</span>
          <span
            :if={@tile.board_name}
            id={"tile-sticker-#{@tile.dom}"}
            class="right"
            title={@tile.board_name}
          >{@tile.sticker}</span>
        </div>
      </.link>
      <details
        :if={@tile.state != :unlinked or @tile.count > 0}
        id={"tile-menu-#{@tile.dom}"}
        class="tile-menu"
      >
        <summary>
          {if @tile.finished?, do: gettext("Next game"), else: gettext("Finish game")}
        </summary>
        <div class="row">
          <.button
            :for={result <- ["1-0", "1/2-1/2", "0-1"]}
            :if={!@tile.finished?}
            id={"tile-result-#{@tile.dom}-#{String.replace(result, "/", "")}"}
            small
            phx-click="result"
            phx-value-t={@section.tid}
            phx-value-board={@tile.no}
            phx-value-result={result}
          >{result}</.button>
          <.button
            :if={!@tile.finished?}
            id={"tile-result-#{@tile.dom}-none"}
            small
            phx-click="result"
            phx-value-t={@section.tid}
            phx-value-board={@tile.no}
            phx-value-result="*"
            data-confirm={gettext("Close this game without a result?")}
          >{gettext("No result")}</.button>
          <.button
            id={"tile-new-game-#{@tile.dom}"}
            small
            variant={if @tile.finished? and @tile.new_kind == :replace, do: "primary"}
            phx-click="new_game"
            phx-value-t={@section.tid}
            phx-value-board={@tile.no}
            phx-value-kind={@tile.new_kind}
            data-confirm={Words.new_game_confirm(@tile.new_kind, @tile.finished?)}
          >
            {if @tile.new_kind == :replace,
              do: gettext("New game"),
              else: gettext("An extra game: it stays on this box")}
          </.button>
          <.button
            :if={@tile.new_kind == :extra and @tile.paired?}
            id={"tile-new-game-replace-#{@tile.dom}"}
            small
            phx-click="new_game"
            phx-value-t={@section.tid}
            phx-value-board={@tile.no}
            phx-value-kind="replace"
            data-confirm={Words.new_game_confirm(:replace_decided, @tile.finished?)}
          >{gettext("It replaces the game of the pairing")}</.button>
        </div>
      </details>
      <div
        :if={@section.site.page && @tile.site_url}
        id={"tile-site-#{@tile.dom}"}
        class="tile-site"
      >
        <.site_link id={"tile-site-link-#{@tile.dom}"} href={@tile.site_url}>
          {gettext("Live page")}
        </.site_link>
      </div>
      <div :if={@tile.stays_home?} id={"tile-local-#{@tile.dom}"} class="tile-local">
        <span>
          {gettext("This game stays on the box: it is game %{n} on this board.",
            n: @tile.game_no
          )}
        </span>
        <.button
          id={"tile-send-this-#{@tile.dom}"}
          small
          phx-click="send_this"
          phx-value-t={@section.tid}
          phx-value-board={@tile.no}
          data-confirm={Words.send_this_confirm()}
        >{gettext("Send this one instead")}</.button>
      </div>
    </div>
    """
  end
end
