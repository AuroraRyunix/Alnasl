defmodule AlnaslWeb.RoundLive do
  @moduledoc """
  The main screen during play: every board of the round at a glance.

  A tile per board: who plays, the position the box is sure of, the clocks,
  the last move, and the state as a shape and a word. A board that needs the
  arbiter stands out by its frame as well as its colour, and is counted at
  the top. A tile is a link to the board's own page, where the repair tools
  are.

  Only what plays in the hall on show: the tournaments placed in it
  (`Alnasl.Placements`), and of those the boards of this hall and the games
  played here - a tournament split over two halls shows each hall its own
  half. The other tournaments the links bring are one line at the bottom.

  A hall with several tournaments shows them one under the other, each at
  its own round, with its own "start round" and its own "ready or not" -
  and a row of names at the top to look at one of them alone. A hall with
  one tournament has no row of names.

  Two views, kept per browser (a colocated hook and localStorage): tiles,
  or a list with a row per board. From 24 boards a browser that chose
  nothing gets the list. The QR code of the live page is made when Share
  is pressed, not on every redraw.

  A board that moves redraws its own tile: the page collects the boards
  that changed and, at most three times a second, makes their tiles and
  their sections' counts again. A board that changed place, a new board or
  a tournament that changed redraws the page.

  A team event reads like one: the boards stand under their match ("Match
  3: Team A - Team B"), in the match's board order, each tile naming the
  team of each player, and the match carries its score as the boards saw
  it finish - labelled so, because the score that counts is the arbiter's,
  in OpenPairings.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{
    Boards,
    Games,
    Halls,
    OpenPairings,
    Outbox,
    Placements,
    Position,
    ResultsSite,
    Tables,
    Tournaments
  }

  alias AlnaslWeb.{Scope, TableWords, Words}

  # From this many tiles a browser that chose nothing sees the list.
  @list_from 24

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Boards.subscribe()
      Tournaments.subscribe()
    end

    {:ok,
     assign(socket,
       refresh_due?: false,
       dirty: MapSet.new(),
       full?: false,
       snaps: %{},
       view: nil,
       shared: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    round =
      case Integer.parse(params["round"] || "") do
        {n, ""} when n > 0 -> n
        _none -> nil
      end

    # One tournament alone when the address names one, or a round.
    if params["tid"] || round do
      case Scope.tournament(params, socket.assigns.current_scope) do
        nil ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("That tournament is not in one of your halls."))
           |> push_navigate(to: ~p"/")}

        tournament ->
          {:noreply, socket |> assign(only: tournament.id, asked_round: round) |> load()}
      end
    else
      {:noreply, socket |> assign(only: nil, asked_round: round) |> load()}
    end
  end

  defp load(socket) do
    %{only: only, asked_round: asked} = socket.assigns
    account = socket.assigns.current_scope
    hall_id = Alnasl.Accounts.Scope.hall_id(account) || Halls.own_id()

    # The tournaments placed in this hall, and the boards of this hall: a
    # tournament split over two halls is two halves, and this is one.
    # The placements are asked once a load, not once a question.
    all_active = Halls.active(account)
    placed = placed(all_active)

    active =
      Enum.filter(all_active, fn t -> Enum.any?(placed[t.id], &(&1.hall_id == hall_id)) end)

    snapshots = Enum.filter(Boards.snapshots(), &(Halls.of(&1) == hall_id))

    shown =
      cond do
        only == nil -> active
        found = Enum.find(active, &(&1.id == only)) -> [found]
        true -> [Tournaments.get(only) || hd(active ++ [Tournaments.default()])]
      end

    # Only what is on the boards here: a tournament with a board of this hall
    # or a game played in it. One that is asked for by name is shown whatever
    # it has, and a hall with a single tournament keeps it, empty state and all.
    with_games = Games.tournament_ids(Enum.map(active, & &1.id))

    listed =
      if match?([_one], active),
        do: active,
        else: Enum.filter(active, &on_the_boards?(&1, snapshots, hall_id, with_games, placed))

    listed_ids = MapSet.new(listed, & &1.id)

    shown_now =
      if only == nil,
        do: Enum.filter(shown, &MapSet.member?(listed_ids, &1.id)),
        else: shown

    # A hall with one tournament draws every pairing played here, as it
    # always did. A tournament asked for by name may not be active; its
    # placements are asked for it alone.
    ctx = %{
      snapshots: snapshots,
      hall_id: hall_id,
      every?: match?([_one], active),
      arbiter?: Alnasl.Accounts.Scope.can?(socket.assigns.current_scope, :arbiter),
      placed: Map.merge(placed(Enum.reject(shown_now, &is_map_key(placed, &1.id))), placed)
    }

    sections = Enum.map(shown_now, &section(&1, asked || &1.round, ctx))

    title =
      case sections do
        [one] -> gettext("Round %{n}", n: one.round)
        _several -> gettext("Rounds")
      end

    # Every tournament the scope's links bring that is not on the boards
    # here: a line, not a section each.
    others =
      account
      |> Halls.visible(Tournaments.active())
      |> Enum.reject(&MapSet.member?(listed_ids, &1.id))

    socket
    |> assign(
      hall_id: hall_id,
      snaps: Map.new(snapshots, &{&1.id, &1}),
      listed: listed,
      not_here: length(others),
      many?: length(listed) > 1,
      title: title,
      page_title: title,
      configured?: Outbox.configured?() or Alnasl.Halls.here(account, Tournaments.links()) != [],
      dirty: MapSet.new(),
      full?: false,
      refresh_due?: false
    )
    |> put_sections(sections)
  end

  # The sections, and what is counted over all of them.
  defp put_sections(socket, sections) do
    assign(socket,
      sections: sections,
      alarms: sections |> Enum.map(& &1.alarms) |> Enum.sum(),
      tile_count: sections |> Enum.map(&length(&1.tiles)) |> Enum.sum()
    )
  end

  # A board of this hall seated for it, or a game on a board this hall
  # plays. Only a tournament with games at all is asked which boards.
  defp on_the_boards?(tournament, snapshots, hall_id, with_games, placed) do
    Enum.any?(snapshots, &(&1[:tournament_id] == tournament.id and &1.board_no != nil)) or
      (MapSet.member?(with_games, tournament.id) and
         tournament.id
         |> Games.board_numbers()
         |> Enum.any?(&Placements.board_here?(placed[tournament.id], &1, hall_id)))
  end

  # Where the results site shows this tournament: the live boards of the
  # round on the page, the live page (which Share draws as a QR code), and -
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

  # The placements of the tournaments on the page, asked once a load.
  defp placed(tournaments), do: Map.new(tournaments, &{&1.id, Placements.list(&1)})

  defp section(tournament, round, %{snapshots: snapshots, hall_id: hall_id} = ctx) do
    tid = tournament.id
    placements = ctx.placed[tid]
    here_board? = &Placements.board_here?(placements, &1, hall_id)

    here =
      for s <- snapshots,
          s[:tournament_id] == tid,
          s.round == round,
          s.board_no != nil,
          into: %{},
          do: {s.board_no, s}

    # A game counts when it was played here: on a board of this hall, or on
    # a board number this hall's placement holds. The other hall's half of
    # the tournament is the other hall's page.
    games =
      for game <- Games.list(tid, round),
          is_map_key(here, game.board_no) or here_board?.(game.board_no),
          into: %{},
          do: {game.board_no, game}

    histories = Enum.group_by(Games.all(tid, round), & &1.board_no)
    pairings = Map.new(Tournaments.boards(tid, round), &{&1.board, &1})

    # A tile is a board that exists here or has a game. A pairing of this
    # hall with neither is only counted - except in a hall with one
    # tournament, where four hundred tiles were never the problem.
    every =
      if ctx.every?, do: pairings |> Map.keys() |> Enum.filter(here_board?), else: []

    numbers = Enum.uniq(Map.keys(here) ++ Map.keys(games) ++ every) |> Enum.sort()

    unplaced =
      pairings |> Map.keys() |> Enum.count(&(&1 not in numbers and here_board?.(&1)))

    site = site(tournament, round)
    title = Tournaments.title(tournament)

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

    info = Tournaments.info(tid)

    %{
      tournament: tournament,
      tid: tid,
      title: title,
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
      site: site,
      # What a tile needs of its section, and nothing that moves with the
      # other tiles: a tile is redrawn when it changes, not when its
      # neighbour does.
      ctx: %{
        tid: tid,
        round: round,
        title: title,
        site?: site.page != nil,
        arbiter?: ctx.arbiter?,
        # Names of the linked tournaments a board of the box's own plays outside of.
        outside:
          if(tournament.kind == "local",
            do:
              AlnaslWeb.SeatingComponents.few_names(
                Enum.map(Alnasl.Seating.linked(), &(Tournaments.title(&1) || "")),
                3,
                " / "
              )
          )
      },
      pairings: pairings,
      placements: placements,
      unplaced: unplaced,
      team?: Tournaments.team_event?(tournament),
      rounds:
        Enum.uniq(Tournaments.rounds(tid) ++ Games.rounds(tid) ++ [round, tournament.round])
        |> Enum.sort()
    }
    |> put_tiles(tiles, snapshots)
  end

  # The tiles of a section and everything counted from them: the states,
  # the alarms, the matches of a team event, and whether the round is ready.
  defp put_tiles(section, tiles, snapshots) do
    counts = Enum.frequencies_by(tiles, & &1.state)
    checks = Tables.checks(section.tid, section.round, snapshots, section.placements)

    Map.merge(section, %{
      tiles: tiles,
      matches: if(section.team?, do: matches(tiles)),
      counts: counts,
      alarms:
        Map.get(counts, :out_of_sync, 0) + Map.get(counts, :no_signal, 0) +
          Map.get(counts, :clock_alarm, 0),
      flagged: Enum.count(tiles, & &1.pairing_flag),
      ready?: Tables.ready?(checks),
      not_ready: Enum.count(checks, &(&1.level in [:bad, :warn])),
      has_boards?: Enum.any?(snapshots, &(&1[:tournament_id] == section.tid))
    })
  end

  # --- one board changed ------------------------------------------------------

  # A board moved: its tile is made again, and its section's counts, and
  # nothing else. A board that changed place (another tournament, round or
  # board number), or one that is new here, redraws the page.
  defp refresh_tiles(socket, ids) do
    Enum.reduce_while(ids, {:ok, socket}, fn id, {:ok, socket} ->
      case refresh_tile(socket, id) do
        {:ok, socket} -> {:cont, {:ok, socket}}
        :full -> {:halt, :full}
      end
    end)
  end

  defp refresh_tile(socket, id) do
    old = socket.assigns.snaps[id]
    snap = Boards.snapshot(id)
    here? = snap != nil and Halls.of(snap) == socket.assigns.hall_id

    cond do
      not here? and old == nil -> {:ok, socket}
      not here? or old == nil -> :full
      place(old) != place(snap) -> :full
      true -> {:ok, put_tile(socket, snap)}
    end
  end

  defp place(snap), do: {snap[:tournament_id], snap.round, snap.board_no}

  defp put_tile(socket, snap) do
    snaps = Map.put(socket.assigns.snaps, snap.id, snap)
    socket = assign(socket, snaps: snaps)
    index = Enum.find_index(socket.assigns.sections, &(&1.tid == snap[:tournament_id]))
    section = index && Enum.at(socket.assigns.sections, index)

    if section && section.round == snap.round && snap.board_no != nil do
      %{tid: tid, round: round} = section
      no = snap.board_no
      history = Games.history(tid, round, no)

      tile =
        tile(
          tid,
          round,
          no,
          snap,
          List.last(history),
          section.pairings[no] || %{},
          history,
          section.site
        )

      tiles =
        section.tiles
        |> Enum.reject(&(&1.no == no))
        |> Kernel.++([tile])
        |> Enum.sort_by(& &1.no)

      section = put_tiles(section, tiles, Map.values(snaps))
      put_sections(socket, List.replace_at(socket.assigns.sections, index, section))
    else
      socket
    end
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

  # The permit has checked the account may act on it.
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
         gettext("Board %{n}: this game is the one that leaves Alnasl now.", n: no)
       )
       |> load()}
    else
      _nothing -> {:noreply, put_flash(socket, :error, gettext("That could not be done."))}
    end
  end

  # Tiles or a list: this browser's choice, which the page's hook keeps
  # (and tells again when the page opens).
  def handle_event("set_view", %{"view" => view}, socket) when view in ~w(boards list),
    do: {:noreply, assign(socket, view: view)}

  def handle_event("set_view", _params, socket), do: {:noreply, socket}

  # The QR code of a tournament's live page, drawn when asked for.
  def handle_event("share", params, socket) do
    tournament = tournament_of(params)

    case Enum.find(socket.assigns.sections, &(&1.tid == tournament.id)) do
      %{site: %{live: url}} when is_binary(url) ->
        shared =
          if socket.assigns.shared && socket.assigns.shared.tid == tournament.id,
            do: nil,
            else: %{tid: tournament.id, url: url, qr: AlnaslWeb.Access.qr(url)}

        {:noreply, assign(socket, shared: shared)}

      _none ->
        {:noreply, socket}
    end
  end

  def handle_event("unshare", _params, socket), do: {:noreply, assign(socket, shared: nil)}

  def handle_event("make_current", params, socket) do
    tournament = tournament_of(params)
    round = section_round(socket, tournament.id)
    Boards.move_to_round(tournament.id, round)

    {:noreply,
     socket
     |> put_flash(:info, gettext("The boards now follow round %{n}.", n: round))
     |> load()}
  end

  # Boards change several times a second during a move. What changed is
  # collected and, at most three times a second, the tiles of those boards
  # are made again - not the page. A tournament that changed, or a board
  # that moved, still redraws everything.
  @impl true
  def handle_info({:board, id}, socket) when is_integer(id),
    do: socket |> assign(dirty: MapSet.put(socket.assigns.dirty, id)) |> schedule()

  def handle_info({:board, _all}, socket), do: socket |> assign(full?: true) |> schedule()

  # A round started by the pairing program, a tournament that appeared.
  def handle_info({:tournament, _id}, socket), do: socket |> assign(full?: true) |> schedule()

  def handle_info(:refresh, %{assigns: %{full?: true}} = socket), do: {:noreply, load(socket)}

  def handle_info(:refresh, socket) do
    case refresh_tiles(socket, MapSet.to_list(socket.assigns.dirty)) do
      {:ok, socket} -> {:noreply, assign(socket, dirty: MapSet.new(), refresh_due?: false)}
      :full -> {:noreply, load(socket)}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp schedule(%{assigns: %{refresh_due?: true}} = socket), do: {:noreply, socket}

  defp schedule(socket) do
    Process.send_after(self(), :refresh, 300)
    {:noreply, assign(socket, refresh_due?: true)}
  end

  # --- page --------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:round}
      help={:round}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      scope={@current_scope}
      path={@current_path}
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
            :for={t <- @listed}
            id={"filter-#{t.id}"}
            patch={~p"/t/#{t.id}"}
            aria-current={to_string(@only == t.id)}
          >
            {Tournaments.title(t) || gettext("The hall's own tournament")}
          </.link>
        </div>
        <.section_actions
          :if={match?([_one], @sections)}
          section={hd(@sections)}
          may_arbiter={@may_arbiter}
        />
        <div
          :if={@tile_count > 0}
          id="live-view"
          class="seg"
          role="group"
          aria-label={gettext("Show the boards as")}
          phx-hook=".ViewChoice"
        >
          <button
            id="view-boards"
            type="button"
            phx-click="set_view"
            phx-value-view="boards"
            data-view="boards"
            aria-pressed={to_string(shown_view(@view, @tile_count) == "boards")}
          >
            <.icon name="grid" /> {gettext("Boards")}
          </button>
          <button
            id="view-list"
            type="button"
            phx-click="set_view"
            phx-value-view="list"
            data-view="list"
            aria-pressed={to_string(shown_view(@view, @tile_count) == "list")}
          >
            <.icon name="list" /> {gettext("List")}
          </button>
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".ViewChoice">
          // Tiles or a list, remembered in this browser. Storage may be
          // missing or refused (a private window): then the page decides.
          const KEY = "alnasl-live-view"
          export default {
            mounted() {
              let stored = null
              try { stored = localStorage.getItem(KEY) } catch (_e) { stored = null }
              if (stored === "boards" || stored === "list") this.pushEvent("set_view", {view: stored})

              this.el.addEventListener("click", (event) => {
                const button = event.target.closest("[data-view]")
                if (!button) return
                try { localStorage.setItem(KEY, button.dataset.view) } catch (_e) { /* not kept */ }
              })
            }
          }
        </script>
      </:actions>

      <section
        :for={section <- @sections}
        id={sid("round-section", section.tid)}
        class="round-section"
        aria-label={section.title || gettext("The hall's own tournament")}
      >
        <header
          :if={length(@sections) > 1}
          id={sid("round-head", section.tid)}
          class="row spread round-head"
        >
          <h2>
            {section.title || gettext("The hall's own tournament")}
            <span class="note">{gettext("Round %{n}", n: section.round)}</span>
          </h2>

          <div class="row"><.section_actions section={section} may_arbiter={@may_arbiter} /></div>
        </header>

        <p
          :if={section.gone?}
          id={sid("round-gone", section.tid)}
          class="callout warn"
          role="status"
        >
          {gettext(
            "OpenPairings no longer lists this tournament for the connect code: it was removed, archived or taken out of its group there. Nothing is reported to it any more. Its boards keep running; remove the tournament in Setup when you are done with it."
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
          <.button
            :if={@may_arbiter}
            id={sid("follow", section.tid)}
            small
            phx-click="follow"
            phx-value-t={section.tid}
          >
            {gettext("Follow round %{n}", n: section.remote_round)}
          </.button>
        </p>

        <div class="row round-meta">
          <.link
            :if={section.has_boards? and section.current?}
            id={sid("round-ready", section.tid)}
            navigate={~p"/boards"}
            class="row tight"
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

          <.button
            :if={section.site.live}
            id={sid("share", section.tid)}
            small
            icon="share"
            phx-click="share"
            phx-value-t={section.tid}
            aria-expanded={to_string(@shared != nil and @shared.tid == section.tid)}
          >
            {gettext("Share")}
          </.button>

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
          :if={@shared && @shared.tid == section.tid}
          id={sid("share-panel", section.tid)}
          class="share-panel"
        >
          <.qr_code id={sid("site-qr-code", section.tid)} text={@shared.url} code={@shared.qr} />
          <div class="stack">
            <p class="note">
              {gettext("The live page on the results site: point a phone at the code.")}
            </p>
            <p id={sid("site-qr-url", section.tid)} class="note mono">{@shared.url}</p>
            <.button id={sid("share-close", section.tid)} small phx-click="unshare">
              {gettext("Close")}
            </.button>
          </div>
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
            class="row tight"
          >
            <b>{section.counts[state]}</b><.state state={state} />
          </span>
        </div>

        <p
          :if={section.unplaced > 0 and section.tiles != []}
          id={sid("round-unplaced", section.tid)}
          class="note"
        >
          {ngettext(
            "%{count} pairing without a board here",
            "%{count} pairings without a board here",
            section.unplaced
          )}
        </p>

        <div :if={section.tiles == []} id={sid("round-empty", section.tid)} class="panel">
          <div class="empty">
            <b>{gettext("No boards in round %{n} yet", n: section.round)}</b>
            <%= cond do %>
              <% section.unplaced > 0 -> %>
                <p>
                  {gettext(
                    "The pairings of this round have no board here yet. Link a board to a board number, or attach a game from a PGN."
                  )}
                </p>

                <.button
                  id={sid("empty-boards", section.tid)}
                  navigate={~p"/boards"}
                  variant="primary"
                >{gettext("Go to Boards")}</.button>
              <% section.linked? -> %>
                <p>
                  {gettext(
                    "OpenPairings has not paired this round, or Alnasl has not heard of it yet. The boards appear here by themselves when it is."
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
                    "Tell Alnasl which tournament it works for first: a connect code from OpenPairings, or a results page."
                  )}
                </p>

                <.button
                  id={sid("empty-setup", section.tid)}
                  navigate={~p"/setup/connections"}
                  variant="primary"
                >{gettext("Go to Setup")}</.button>
            <% end %>
          </div>
        </div>

        <div
          :if={section.tiles != [] and shown_view(@view, @tile_count) == "list"}
          id={sid("board-list-wrap", section.tid)}
          class="table-wrap"
        >
          <table id={sid("board-list", section.tid)} class="board-list">
            <thead>
              <tr>
                <th scope="col">{gettext("Board")}</th>
                <th scope="col">{gettext("Players")}</th>
                <th scope="col">{gettext("Last move")}</th>
                <th scope="col">{gettext("Clock")}</th>
                <th scope="col">{gettext("State")}</th>
              </tr>
            </thead>
            <tbody>
              <.board_row :for={tile <- section.tiles} :key={tile.dom} tile={tile} ctx={section.ctx} />
            </tbody>
          </table>
        </div>

        <div
          :if={
            section.tiles != [] and section.matches == nil and
              shown_view(@view, @tile_count) == "boards"
          }
          id={sid("tiles", section.tid)}
          class={[
            "tiles",
            length(section.tiles) <= 4 && "few",
            length(section.tiles) > 12 && "many"
          ]}
        >
          <.tile
            :for={tile <- section.tiles}
            :key={tile.dom}
            tile={tile}
            ctx={section.ctx}
            many?={@many?}
          />
        </div>
        <%!-- A team event: the boards under their match, in the match's board order. --%>
        <div
          :if={
            section.tiles != [] and section.matches != nil and
              shown_view(@view, @tile_count) == "boards"
          }
          id={sid("matches", section.tid)}
        >
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
              <.tile
                :for={tile <- group.tiles}
                :key={tile.dom}
                tile={tile}
                ctx={section.ctx}
                many?={@many?}
              />
            </div>
          </section>
        </div>
      </section>

      <div :if={@sections == []} id="live-empty" class="panel">
        <div class="empty">
          <b>{gettext("Nothing is on the boards here yet")}</b>
          <p>
            {gettext("Link a board to a board number, or attach a game from a PGN.")}
          </p>

          <.button id="live-empty-boards" navigate={~p"/boards"} variant="primary">
            {gettext("Go to Boards")}
          </.button>
        </div>
      </div>

      <p :if={@not_here > 0} id="not-on-the-boards" class="note">
        {ngettext(
          "%{count} more tournament is not on the boards here.",
          "%{count} more tournaments are not on the boards here.",
          @not_here
        )}
        <.link id="not-on-the-boards-setup" navigate={~p"/setup/tournaments"}>{gettext("Setup")}</.link>
      </p>
    </Layouts.app>
    """
  end

  # The rounds of one tournament, "ask the pairing program now" and "start
  # the next round": at the top of the page when it shows one tournament,
  # in each tournament's own heading when it shows several.
  attr :section, :map, required: true
  attr :may_arbiter, :boolean, default: false

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
      :if={@may_arbiter and (@section.linked? and not @section.gone?)}
      id={sid("refresh-pairings", @section.tid)}
      small
      phx-click="refresh"
      phx-value-t={@section.tid}
    >{gettext("Ask OpenPairings now")}</.button>
    <.button
      :if={@may_arbiter}
      id={sid("next-round", @section.tid)}
      small
      phx-click="next_round"
      phx-value-t={@section.tid}
      data-confirm={
        if @section.linked?,
          do:
            gettext(
              "Move this tournament's boards to round %{n} by hand? Normally Alnasl does this by itself when OpenPairings pairs the round. The games of this round stay as they are.",
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

  # Tiles or a list: what this browser chose, else the list from
  # @list_from tiles on - a hall of forty boards does not fit in tiles.
  defp shown_view(view, _count) when view in ["boards", "list"], do: view
  defp shown_view(_none, count) when count >= @list_from, do: "list"
  defp shown_view(_none, _count), do: "boards"

  # One board as a row of the list: table, players, last move, clock, state.
  # The board number opens the board's page, as a tile does.
  attr :tile, :map, required: true
  attr :ctx, :map, required: true

  defp board_row(assigns) do
    ~H"""
    <tr id={"row-#{@tile.dom}"} class={["board-row", tone(@tile.state)]}>
      <td class="row-board">
        <.link
          id={"row-link-#{@tile.dom}"}
          navigate={Scope.game_path(@ctx.tid, @ctx.round, @tile.no)}
          aria-label={gettext("Board %{n}: %{state}", n: @tile.no, state: state_word(@tile.state))}
        >
          {@tile.no}
        </.link>
        <span :if={@tile.label} class="note">{gettext("table %{label}", label: @tile.label)}</span>
        <span :if={@tile.match} class="note">
          {gettext("match %{match}, board %{place}",
            match: @tile.match.number,
            place: @tile.match.board
          )}
        </span>
      </td>
      <td class="row-players">
        <span class="row-player">
          <span class="dot white"></span>{@tile.white || gettext("White")}
        </span>
        <span class="row-player">
          <span class="dot black"></span>{@tile.black || gettext("Black")}
        </span>
      </td>
      <td class="row-move">
        <%= cond do %>
          <% @tile.result -> %>
            <b>{@tile.result}</b>
          <% @tile.last_san -> %>
            {div(@tile.count + 1, 2)}{if rem(@tile.count, 2) == 1, do: ".", else: "..."}
            <.figurine san={@tile.last_san} />
          <% true -> %>
            <span class="note">{gettext("No moves")}</span>
        <% end %>
      </td>
      <td class="row-clock">
        <%= if @tile.clock do %>
          <.clock ms={@tile.clock.white_ms} running={@tile.clock.running == :white} />
          <.clock ms={@tile.clock.black_ms} running={@tile.clock.running == :black} />
        <% else %>
          <span class="note">-</span>
        <% end %>
      </td>
      <td class="row-state">
        <.state state={@tile.state} />
        <span :if={@tile.alarm} id={"row-alarm-#{@tile.dom}"} class="note">{@tile.alarm}</span>
        <span :if={@tile.pairing_flag} class="note">
          {gettext("Pairing changed in OpenPairings")}
        </span>
      </td>
    </tr>
    """
  end

  # One board of the round: the tile, its menu, and what stays on the box.
  attr :tile, :map, required: true
  attr :ctx, :map, required: true, doc: "the section's `ctx`: what a tile needs of it"
  attr :many?, :boolean, default: false

  defp tile(assigns) do
    ~H"""
    <div id={"tile-wrap-#{@tile.dom}"} class="tile-wrap">
      <.link
        id={"tile-#{@tile.dom}"}
        navigate={Scope.game_path(@ctx.tid, @ctx.round, @tile.no)}
        class={["tile", tone(@tile.state), @tile.pairing_flag && "flagged"]}
        aria-label={gettext("Board %{n}: %{state}", n: @tile.no, state: state_word(@tile.state))}
      >
        <div class="tile-head">
          <span class="tile-no">{@tile.no}</span>
          <span
            :if={@many? and @ctx.title}
            id={"tile-tournament-#{@tile.dom}"}
            class="flag plain"
          >{@ctx.title}</span>
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
          >{gettext("Stays in Alnasl")}</span>
          <span :if={@tile.warning} class="flag">{gettext("Move missing?")}</span>
          <span :for={piece <- @tile.unseen} id={"tile-unseen-#{@tile.dom}"} class="flag">{AlnaslWeb.Words.unseen(
            piece
          )}</span> <.state state={@tile.state} />
        </div>

        <div
          :if={@ctx.outside not in [nil, ""] and @tile.board_name}
          id={"tile-outside-#{@tile.dom}"}
          class="tile-note"
        >
          <.icon name="warning" />{gettext("Not playing in %{tournament}",
            tournament: @ctx.outside
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
            :if={@ctx.arbiter? and !@tile.finished?}
            id={"tile-result-#{@tile.dom}-#{String.replace(result, "/", "")}"}
            small
            phx-click="result"
            phx-value-t={@ctx.tid}
            phx-value-board={@tile.no}
            phx-value-result={result}
          >{result}</.button>
          <.button
            :if={@ctx.arbiter? and !@tile.finished?}
            id={"tile-result-#{@tile.dom}-none"}
            small
            phx-click="result"
            phx-value-t={@ctx.tid}
            phx-value-board={@tile.no}
            phx-value-result="*"
            data-confirm={gettext("Close this game without a result?")}
          >{gettext("No result")}</.button>
          <.button
            :if={@ctx.arbiter?}
            id={"tile-new-game-#{@tile.dom}"}
            small
            variant={if @tile.finished? and @tile.new_kind == :replace, do: "primary"}
            phx-click="new_game"
            phx-value-t={@ctx.tid}
            phx-value-board={@tile.no}
            phx-value-kind={@tile.new_kind}
            data-confirm={Words.new_game_confirm(@tile.new_kind, @tile.finished?)}
          >
            {if @tile.new_kind == :replace,
              do: gettext("New game"),
              else: gettext("An extra game: it stays in Alnasl")}
          </.button>

          <.button
            :if={@ctx.arbiter? and (@tile.new_kind == :extra and @tile.paired?)}
            id={"tile-new-game-replace-#{@tile.dom}"}
            small
            phx-click="new_game"
            phx-value-t={@ctx.tid}
            phx-value-board={@tile.no}
            phx-value-kind="replace"
            data-confirm={Words.new_game_confirm(:replace_decided, @tile.finished?)}
          >{gettext("It replaces the game of the pairing")}</.button>
        </div>
      </details>

      <div
        :if={@ctx.site? && @tile.site_url}
        id={"tile-site-#{@tile.dom}"}
        class="tile-site"
      >
        <.site_link id={"tile-site-link-#{@tile.dom}"} href={@tile.site_url}>
          {gettext("Live page")}
        </.site_link>
      </div>

      <div :if={@tile.stays_home?} id={"tile-local-#{@tile.dom}"} class="tile-local">
        <span>
          {gettext("This game stays in Alnasl: it is game %{n} on this board.",
            n: @tile.game_no
          )}
        </span>

        <.button
          :if={@ctx.arbiter?}
          id={"tile-send-this-#{@tile.dom}"}
          small
          phx-click="send_this"
          phx-value-t={@ctx.tid}
          phx-value-board={@tile.no}
          data-confirm={Words.send_this_confirm()}
        >{gettext("Send this one instead")}</.button>
      </div>
    </div>
    """
  end
end
