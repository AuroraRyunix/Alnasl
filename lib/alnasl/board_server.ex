defmodule Alnasl.BoardServer do
  @moduledoc """
  One physical board, alive: its driver, what it reads, and - when it is
  linked to a game of the round - the tracker for that game.

  Everything a driver delivers passes through here, in this order:

  1. it is written to the capture file, exactly as delivered;
  2. the board is turned round if it is plugged in turned round (and that is
     noticed by itself: a start position that reads upside down);
  3. it is given to the game's session (`Alnasl.Session`: tracker and clock);
  4. what the session reports is applied: the game is saved to the database,
     the PGN rewritten, the update queued for the server (`Alnasl.Outbox`),
     the arbiter's log written;
  5. the site is told the board changed.

  Step 4 is one database write before one queue write: a move the site
  shows is a move that is saved, and a move that is saved is a move that is
  queued.

  ## Time

  The tracker is given time explicitly. For a real board that is the
  machine's monotonic clock. A simulated or replayed board brings its own
  time (`{:at, t, speed, next_t, event}`), possibly running twenty times too fast;
  the session then lives in that time, so the tracker's patience scales with
  the simulation. Between events the process ticks every 100 ms.

  ## The arbiter

  The repair tools of the site are calls on this process (`Alnasl.Boards`
  has the functions). Each is applied to the tracker, saved like any other
  change, sent to the server as a replacement of the game, and logged with
  who did it: the box has no accounts, so "the arbiter at the box".
  """

  use GenServer, restart: :transient

  alias Alnasl.{
    Chess,
    Clock,
    Driver,
    Games,
    Log,
    Outbox,
    Position,
    Recorder,
    Session,
    Settings,
    Tournaments,
    Tracker
  }

  alias Alnasl.Boards.Board

  @tick_ms 100
  # Polls missed in a row before the board counts as not heard.
  @deaf_after 3
  @topic "boards"

  def start_link(%Board{} = board) do
    GenServer.start_link(__MODULE__, board, name: via(board.id))
  end

  def via(id), do: {:via, Registry, {Alnasl.BoardRegistry, id}}

  def whereis(id) do
    case Registry.lookup(Alnasl.BoardRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Alnasl.PubSub, @topic)

  # --- init --------------------------------------------------------------------

  @impl true
  def init(%Board{} = board) do
    Process.flag(:trap_exit, true)
    # The tracker's patience is changed in Setup while boards are playing.
    Settings.subscribe()

    state = %{
      board: board,
      driver: nil,
      raw: nil,
      seen: nil,
      connected?: false,
      last_seen: nil,
      stats: %{positions: 0, polls_ok: 0, polls_missed: 0},
      info: %{},
      # The clock as the board reports it, linked to a game or not: the
      # starting-position check wants it before there is a game.
      clock: Clock.new(),
      game: nil,
      session: nil,
      time: {0, System.monotonic_time(:millisecond), 1.0, nil},
      last_t: 0,
      warning: nil,
      queued_at: nil,
      heartbeat_ms: (Settings.get("clock_heartbeat_s") || 20) * 1000,
      dirty?: false
    }

    state = state |> load_game() |> start_driver()
    Process.send_after(self(), :tick, @tick_ms)
    Process.send_after(self(), :notify, 250)
    {:ok, state}
  end

  defp start_driver(%{board: board} = state) do
    opts = [
      owner: self(),
      id: board.id,
      port: board.port,
      address: board.address,
      options: Board.options(board)
    ]

    case Driver.module(board.driver).start_link(opts) do
      {:ok, pid} ->
        %{state | driver: pid}

      {:error, reason} ->
        Log.add(:error, "board.driver_failed", %{reason: inspect(reason)}, ref(state))
        Process.send_after(self(), :restart_driver, 3_000)
        %{state | driver: nil}
    end
  rescue
    error ->
      Log.add(:error, "board.driver_failed", %{reason: Exception.message(error)}, ref(state))
      Process.send_after(self(), :restart_driver, 3_000)
      %{state | driver: nil}
  end

  # The game this board is linked to, and a session caught up with it.
  defp load_game(%{board: %Board{tournament_id: tournament, round: round, board_no: no}} = state)
       when is_integer(round) and is_integer(no) do
    pairing = Tournaments.board(tournament, round, no)
    game = Games.ensure(tournament, round, no, Games.pairing_attrs(pairing))

    opts =
      Settings.tracker_opts()
      |> Keyword.put(:start_fen, game.start_fen)
      # A second game on a board began on a board that showed the first.
      |> Keyword.put(:late_start, game.game_no == 1)

    session = Session.restore(opts, Games.plies(game))
    Recorder.record(state.board.id, {:cfg, cfg(state.board, game)})
    %{state | game: game, session: session, warning: nil}
  end

  defp load_game(state) do
    Recorder.record(state.board.id, {:cfg, cfg(state.board, nil)})
    %{state | game: nil, session: nil, warning: nil}
  end

  defp cfg(board, game) do
    %{
      driver: board.driver,
      port: board.port,
      address: board.address,
      flipped: board.flipped,
      round: board.round,
      board: board.board_no,
      game: game && game.game_no,
      start_fen: game && game.start_fen
    }
  end

  # --- from the driver ---------------------------------------------------------

  @impl true
  def handle_info({:driver, _id, {:at, t, speed, next, event}}, state) do
    state = %{state | time: {t, System.monotonic_time(:millisecond), speed, next}}
    {:noreply, driver_event(state, event, t)}
  end

  def handle_info({:driver, _id, event}, state),
    do: {:noreply, driver_event(state, event, now(state))}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    t = now(state)
    {:noreply, state |> advance(t) |> heartbeat(t)}
  end

  # Tells the site, at most four times a second.
  def handle_info(:notify, state) do
    Process.send_after(self(), :notify, 250)

    if state.dirty? do
      Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, {:board, state.board.id})
      {:noreply, %{state | dirty?: false}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:restart_driver, %{driver: nil} = state), do: {:noreply, start_driver(state)}
  def handle_info(:restart_driver, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{driver: pid} = state) do
    if reason not in [:normal, :shutdown] do
      Log.add(:error, "board.driver_failed", %{reason: inspect(reason, limit: 5)}, ref(state))
    end

    Process.send_after(self(), :restart_driver, 3_000)
    {:noreply, dirty(%{state | driver: nil, connected?: false})}
  end

  # Setup changed the tracker's settings ("Bullet / fast play", or a number
  # by hand): the game under way goes on with them, from its next reading.
  def handle_info({:setting, "tracker"}, %{session: %{tracker: tracker} = session} = state) do
    opts =
      Tracker.defaults()
      |> Map.merge(Map.new(Settings.tracker_opts()))
      |> Map.put(:late_start, tracker.opts.late_start)

    {:noreply, %{state | session: %{session | tracker: %{tracker | opts: opts}}}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp driver_event(state, {:position, board}, t) do
    Recorder.record(state.board.id, {:position, board})
    # Somebody touched it: "which board is this?" (`Alnasl.Finder`).
    Alnasl.Finder.reading(state.board.id, state.raw, board)

    state = %{
      state
      | raw: board,
        last_seen: DateTime.utc_now(:second),
        stats: Map.update!(state.stats, :positions, &(&1 + 1))
    }

    state = orientation(state)
    seen = if state.board.flipped, do: Position.rotate(board), else: board
    state = %{state | seen: seen}
    state |> feed(t, {:position, seen}) |> dirty()
  end

  defp driver_event(state, {:clock, reading}, t) do
    Recorder.record(state.board.id, {:clock, reading})
    {clock, _pressed?} = Clock.update(state.clock, t, reading)
    state = %{state | clock: clock, info: Map.put(state.info, :clock, true)}
    state |> feed(t, {:clock, reading}) |> dirty()
  end

  # The clock was switched off or unplugged: no clock, so no clock check and
  # no clock alarm, until it reports again.
  defp driver_event(state, {:info, %{clock: false} = info}, t) do
    Recorder.record(state.board.id, {:clock, :off})
    state = %{state | clock: Clock.off(state.clock, t), info: Map.merge(state.info, info)}
    state |> feed(t, {:info, %{clock: false}}) |> dirty()
  end

  defp driver_event(state, :connected, _t) do
    Recorder.record(state.board.id, {:status, :connected})
    unless state.connected?, do: Log.add(:info, "board.connected", %{}, ref(state))
    dirty(%{state | connected?: true, last_seen: DateTime.utc_now(:second)})
  end

  defp driver_event(state, :disconnected, _t) do
    Recorder.record(state.board.id, {:status, :disconnected})
    if state.connected?, do: Log.add(:warn, "board.disconnected", %{}, ref(state))

    # Its clock is not heard either while it is gone (`Tracker.deaf/1`).
    session =
      state.session && %{state.session | tracker: Tracker.deaf(state.session.tracker)}

    dirty(%{state | connected?: false, session: session})
  end

  defp driver_event(state, {:info, info}, _t) do
    state = %{state | info: Map.merge(state.info, info)}

    # A board alone on its port says which number it answers to on a loop:
    # kept with the row, so that it is known again when it is on one.
    alone = if state.board.driver == "dgt_serial", do: info[:bus_address]

    changes =
      %{serial: info[:serial], firmware: info[:firmware], address: alone}
      |> Map.reject(fn {key, value} -> value == nil or Map.get(state.board, key) == value end)
      # A row that has a serial is that board; another serial on its port
      # is another board, not a new name for this one.
      |> Alnasl.Tables.keep_identity(state.board)

    state =
      if changes == %{} do
        state
      else
        %{state | board: state.board |> Board.changeset(changes) |> Alnasl.Repo.update!()}
      end

    # A board that says who it is may be one the box already knows, on
    # another port - or not the board this row is (`Alnasl.Tables.recognise/4`).
    if info[:serial], do: Alnasl.Finder.identified(state.board, info[:serial])

    dirty(state)
  end

  defp driver_event(state, {:poll, :ok}, _t),
    do: %{
      state
      | stats: state.stats |> Map.update!(:polls_ok, &(&1 + 1)) |> Map.put(:missed_run, 0),
        last_seen: DateTime.utc_now(:second)
    }

  # A board on a loop that misses a poll now and then is a noisy line.
  # One that misses several in a row was not heard for that long, and its
  # clock with it: a hole in what the box knows (`Tracker.deaf/1`), which is
  # the one thing that lets the reconstruction consider moves it has no
  # reading for.
  defp driver_event(state, {:poll, :missed}, _t) do
    run = Map.get(state.stats, :missed_run, 0) + 1

    session =
      if run == @deaf_after and state.session,
        do: %{state.session | tracker: Tracker.deaf(state.session.tracker)},
        else: state.session

    stats = state.stats |> Map.update!(:polls_missed, &(&1 + 1)) |> Map.put(:missed_run, run)
    dirty(%{state | stats: stats, session: session})
  end

  defp driver_event(state, {:raw, direction, bytes}, _t) do
    Recorder.record(state.board.id, {:raw, direction, bytes})
    state
  end

  defp driver_event(state, _other, _t), do: state

  # A start position that reads upside down is a board plugged in turned
  # round. Only decided while no move has been made: after that, a board
  # does not turn by itself.
  defp orientation(%{raw: raw, board: board} = state) do
    started? = state.session != nil and state.session.tracker.plies != []
    start = if state.session, do: start_board(state.session.tracker), else: Position.start()

    cond do
      started? or raw == Position.rotate(raw) -> state
      not board.flipped and raw != start and Position.rotate(raw) == start -> flip(state, true)
      board.flipped and raw == start and Position.rotate(raw) != start -> flip(state, false)
      true -> state
    end
  end

  defp start_board(tracker) do
    {:ok, pos} = Chess.parse_fen(tracker.start_fen)
    pos.board
  end

  defp flip(state, flipped?) do
    board = state.board |> Board.changeset(%{flipped: flipped?}) |> Alnasl.Repo.update!()
    Log.add(:info, "board.flipped", %{flipped: flipped?, auto: true}, ref(state))
    Recorder.record(board.id, {:cfg, cfg(board, state.game)})
    %{state | board: board}
  end

  # --- the session -------------------------------------------------------------

  # Time runs on from the last event at the driver's speed - but not past
  # the driver's next event, which has not happened yet.
  defp now(%{time: {t0, mono0, speed, next}, last_t: last}) do
    t = round(t0 + (System.monotonic_time(:millisecond) - mono0) * speed)
    t = if next, do: min(t, next - 1), else: t
    max(t, last)
  end

  defp feed(%{session: nil} = state, _t, _event), do: state

  # The pieces are set up again: the next game, if the box is to begin one
  # by itself (`begin_again?/1`). Otherwise a finished game is finished,
  # whatever the board shows.
  defp feed(state, t, {:position, board} = event) do
    cond do
      set_up_again?(state, board) and begin_again?(state) ->
        state |> new_game(:pieces) |> play(t, event)

      state.game.status == "finished" ->
        state

      true ->
        play(state, t, event)
    end
  end

  defp feed(state, t, event), do: play(state, t, event)

  # The starting position on the board, over a game that is finished - or
  # one that has gone far enough for it to be nothing else: two moves in,
  # the same board is a takeback.
  defp set_up_again?(%{game: game, session: %{tracker: tracker}}, board) do
    board == start_board(tracker) and
      (game.status == "finished" or length(tracker.plies) > tracker.opts.takeback_plies)
  end

  # "Start a new game when the pieces are set up again" (Setup): yes, no,
  # or - the default - only where no pairing says who plays this board in
  # this round. Friends playing game after game want it; a paired round
  # has one game a board, and a board set up early for the next round is
  # not a second game of this one.
  defp begin_again?(%{board: board}) do
    case Settings.get("new_game_on_setup") do
      "always" -> true
      "never" -> false
      _unpaired -> Tournaments.board(board.tournament_id, board.round, board.board_no) == nil
    end
  end

  # A fresh game on this board: the next number, a new tracker, a line in
  # the recording so that a capture can be cut where the games part. A
  # game left unfinished is closed without a result first.
  defp new_game(state, by) do
    state =
      if state.game.status == "finished" do
        state
      else
        Log.add(:info, "result.set", %{result: "*", by: to_string(by)}, ref(state))
        t = now(state)
        enqueue(%{state | game: Games.finish(state.game, "*")}, t, false)
      end

    game = Games.next(state.game)
    Log.add(:info, "game.new", %{game: game.game_no, by: to_string(by)}, ref(state))
    # The board may still show the game before: nothing is read into this
    # one until the starting position has stood on it.
    opts =
      Settings.tracker_opts()
      |> Keyword.put(:start_fen, game.start_fen)
      |> Keyword.put(:late_start, false)

    Recorder.record(state.board.id, {:cfg, cfg(state.board, game)})
    %{state | game: game, session: Session.new(opts), warning: nil, queued_at: nil}
  end

  defp play(state, t, event) do
    state = advance(state, t)
    t = max(t, state.last_t)
    {session, events} = Session.handle(state.session, t, event)
    apply_events(%{state | session: session, last_t: t}, events, t)
  end

  # Ticks the session at each of its own deadlines up to `t`.
  defp advance(%{session: nil} = state, _t), do: state
  defp advance(%{game: %{status: "finished"}} = state, _t), do: state

  defp advance(state, t) do
    case Session.deadline(state.session) do
      due when is_integer(due) and due <= t ->
        due = max(due, state.last_t)
        {session, events} = Session.handle(state.session, due, :tick)
        state = apply_events(%{state | session: session, last_t: due}, events, due)
        if Session.deadline(state.session) == due, do: state, else: advance(state, t)

      _none ->
        state
    end
  end

  # What the session reported becomes: a saved game, a queued update, lines
  # in the log. One queue entry for the lot.
  defp apply_events(state, [], _t), do: state

  defp apply_events(state, events, t) do
    wall = System.os_time(:millisecond)

    {state, queue} =
      Enum.reduce(events, {state, nil}, fn event, {state, queue} ->
        case event do
          {:moves, plies} ->
            {game, _} = Games.apply_event(state.game, event, wall)
            log_moves(state, plies)
            {%{state | game: game}, queue || :append}

          {:correction, keep, plies, reason} ->
            {game, _} = Games.apply_event(state.game, event, wall)

            case {reason, plies} do
              # A move read wrong and put right: said in so many words.
              {:misread, [%{read: read} = first | _]} ->
                Log.add(
                  :warn,
                  "move.rewritten",
                  %{
                    ply: keep + 1,
                    read: read,
                    now: first.san,
                    moves: Enum.map(plies, & &1.san),
                    sure: :recovered in first.flags
                  },
                  ref(state)
                )

              _other ->
                Log.add(
                  :info,
                  "move.corrected",
                  %{reason: reason, keep: keep, moves: Enum.map(plies, & &1.san)},
                  ref(state)
                )
            end

            {%{state | game: game}, :replace}

          {:restart, _fen} ->
            {game, _} = Games.apply_event(state.game, event, wall)
            {%{state | game: game}, :replace}

          {:status, status, detail} ->
            {log_status(state, status, detail), queue}

          {:result_suggestion, result, why} ->
            {suggest(state, result, why), queue}

          {:clock, _reading} ->
            {state, queue}

          {:unseen, pieces} ->
            log_unseen(state, pieces)
            {state, queue}

          {:warning, :move_missing, presses, plies} ->
            Log.add(:warn, "clock.move_missing", %{presses: presses, plies: plies}, ref(state))
            {%{state | warning: :move_missing}, queue}

          {:warning_cleared, :move_missing} ->
            {%{state | warning: nil}, queue}

          # The alarm itself lives in the session (`clock_alarm`); here it
          # is only written down.
          {:warning, :clock_side, side} ->
            Log.add(:error, "clock.wrong_side", %{side: side}, ref(state))
            {state, queue}

          {:warning_cleared, :clock_side} ->
            Log.add(:info, "clock.side_ok", %{}, ref(state))
            {state, queue}

          _other ->
            {state, queue}
        end
      end)

    state = if queue, do: enqueue(state, t, queue == :replace), else: state
    dirty(state)
  end

  defp log_moves(state, plies) do
    flags = plies |> Enum.flat_map(& &1.flags) |> Enum.uniq()
    sans = Enum.map(plies, & &1.san)

    cond do
      :guessed in flags ->
        Log.add(:warn, "move.guessed", %{moves: sans}, ref(state))

      :recovered in flags ->
        Log.add(:warn, "move.recovered", %{moves: sans, long: :long_gap in flags}, ref(state))

      :assumed in flags ->
        Log.add(:warn, "move.assumed", %{moves: sans}, ref(state))

      :arbiter in flags ->
        :ok

      true ->
        :ok
    end
  end

  # A piece went out of sight and the game went on, or it is accounted for
  # again (seen, moved or taken - the moves say which).
  defp log_unseen(state, []), do: Log.add(:info, "piece.accounted", %{}, ref(state))

  defp log_unseen(state, pieces) do
    for %{square: square, piece: {colour, kind}} = entry <- pieces do
      Log.add(
        :warn,
        "piece.unseen",
        %{
          square: Position.square_name(square),
          colour: colour,
          piece: kind,
          read: entry[:ghost] && Position.square_name(entry.ghost)
        },
        ref(state)
      )
    end
  end

  # Writes down that the board went out of sync - by name, when what it
  # shows has one - and that it is back. `alarmed?` remembers the first so
  # that the second is said once, and only after it.
  defp log_status(state, :out_of_sync, detail) do
    case detail do
      {:out_of_turn, move} ->
        Log.add(
          :error,
          "move.out_of_turn",
          %{
            colour: move.colour,
            move: move.san,
            from: Position.square_name(move.from),
            to: Position.square_name(move.to)
          },
          ref(state)
        )

      {:illegal, %{piece: {colour, kind}} = move} ->
        Log.add(
          :error,
          "move.illegal",
          %{
            colour: colour,
            piece: kind,
            from: Position.square_name(move.from),
            to: Position.square_name(move.to),
            why: move.why
          },
          ref(state)
        )

      other ->
        Log.add(:error, "board.out_of_sync", %{why: inspect(other)}, ref(state))
    end

    Map.put(state, :alarmed?, true)
  end

  defp log_status(%{alarmed?: true} = state, status, _detail)
       when status in [:live, :waiting_start] do
    Log.add(:info, "board.resumed", %{}, ref(state))
    %{state | alarmed?: false}
  end

  defp log_status(state, _status, _detail), do: state

  # A result the board suggests. Kept for the arbiter; sent on by itself only
  # for what is a fact of the position, and only when Setup says so.
  defp suggest(state, result, why) do
    if state.game.suggestion == result do
      state
    else
      Log.add(:info, "result.suggested", %{result: result, why: why}, ref(state))
      state = %{state | game: Games.suggest(state.game, result)}

      if why in [:checkmate, :stalemate, :insufficient_material] and
           Settings.get("auto_suggest") == true do
        Log.add(:info, "result.set", %{result: result, by: "board"}, ref(state))
        %{state | game: Games.finish(state.game, result)}
      else
        state
      end
    end
  end

  defp enqueue(state, t, replace?) do
    reading = Clock.read(state.session.clock, t)

    game =
      state.game
      |> Games.remember_clock(reading && Map.put(reading, :running, reading.running))
      |> Outbox.enqueue(reading, replace?)

    %{state | game: game, queued_at: System.monotonic_time(:millisecond)}
  end

  # While a clock runs and nothing else is said, the server is told the time
  # now and then, so a spectator's countdown does not wander.
  defp heartbeat(%{session: nil} = state, _t), do: state
  defp heartbeat(%{game: %{status: "finished"}} = state, _t), do: state

  defp heartbeat(state, t) do
    every = state.heartbeat_ms
    since = state.queued_at && System.monotonic_time(:millisecond) - state.queued_at

    with true <- Clock.present?(state.session.clock),
         %{running: running} when running != :none <- Clock.read(state.session.clock, t),
         true <- state.session.tracker.plies != [],
         true <- since == nil or since >= every do
      enqueue(state, t, false)
    else
      _no -> state
    end
  end

  defp dirty(state), do: %{state | dirty?: true}

  defp ref(%{board: board}),
    do: %{board_id: board.id, round: board.round, board_no: board.board_no}

  # --- calls -------------------------------------------------------------------

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({:reload, %Board{} = board}, _from, state) do
    relink? =
      {board.tournament_id, board.round, board.board_no} !=
        {state.board.tournament_id, state.board.round, state.board.board_no}

    state = %{
      state
      | board: board,
        heartbeat_ms: (Settings.get("clock_heartbeat_s") || 20) * 1000
    }

    state = if relink?, do: state |> load_game() |> refeed(), else: state
    {:reply, :ok, dirty(state)}
  end

  # Somebody else wrote to the game's row - the names, a pairing flag: read
  # it again. The moves are this process's and are in the row already.
  def handle_call(:reload_game, _from, %{game: %{id: id}} = state) do
    case Alnasl.Repo.get(Games.Game, id) do
      nil -> {:reply, :ok, state |> load_game() |> refeed() |> dirty()}
      game -> {:reply, :ok, dirty(%{state | game: game})}
    end
  end

  def handle_call(:reload_game, _from, state), do: {:reply, :ok, state}

  def handle_call({:flip, flipped?}, _from, state) do
    board = state.board |> Board.changeset(%{flipped: flipped?}) |> Alnasl.Repo.update!()
    Log.add(:info, "board.flipped", %{flipped: flipped?, auto: false}, ref(state))
    Recorder.record(board.id, {:cfg, cfg(board, state.game)})
    {:reply, :ok, refeed(%{state | board: board})}
  end

  def handle_call({:driver, :pause}, _from, state),
    do: {:reply, player(state, :pause), dirty(state)}

  def handle_call({:driver, :resume}, _from, state),
    do: {:reply, player(state, :resume), dirty(state)}

  def handle_call({:note, text}, _from, state) do
    Recorder.record(state.board.id, {:note, text})
    {:reply, :ok, state}
  end

  def handle_call({:repair, _op, _args}, _from, %{session: nil} = state),
    do: {:reply, {:error, :not_linked}, state}

  def handle_call({:repair, op, args}, _from, state) do
    {reply, state} = repair(state, op, args, now(state))
    {:reply, reply, dirty(state)}
  end

  defp player(%{driver: pid, board: %{driver: driver}}, action)
       when is_pid(pid) and driver in ["simulator", "replay"] do
    apply(Alnasl.Driver.Player, action, [pid])
  end

  defp player(_state, _action), do: {:error, :not_a_player}

  # After a change of game or orientation, the board as it reads now is
  # looked at afresh.
  defp refeed(%{raw: nil} = state), do: state

  defp refeed(state) do
    seen = if state.board.flipped, do: Position.rotate(state.raw), else: state.raw
    feed(%{state | seen: seen}, now(state), {:position, seen})
  end

  # --- the repair tools --------------------------------------------------------

  defp repair(state, :undo, _args, t) do
    last = List.last(Tracker.sans(state.session.tracker))
    tracked(state, t, &Tracker.undo(&1, t), "repair.undo", %{move: last})
  end

  defp repair(state, :append, sans, t) do
    case Tracker.append(state.session.tracker, t, sans) do
      {:ok, result} -> tracked(state, t, fn _tr -> result end, "repair.append", %{moves: sans})
      {:error, {index, message}} -> {{:error, {index, message}}, state}
    end
  end

  defp repair(state, :edit, {number, san}, t) do
    case Tracker.edit(state.session.tracker, t, number, san) do
      {:ok, result, dropped} ->
        {_reply, state} =
          tracked(state, t, fn _tr -> result end, "repair.edit", %{
            ply: number,
            move: san,
            dropped: dropped
          })

        {{:ok, dropped}, state}

      {:error, message} ->
        {{:error, message}, state}
    end
  end

  defp repair(state, :set_fen, fen, t) do
    case Tracker.set_position(state.session.tracker, t, fen) do
      {:ok, result} -> tracked(state, t, fn _tr -> result end, "repair.set_fen", %{fen: fen})
      {:error, message} -> {{:error, message}, state}
    end
  end

  defp repair(state, :resync, depth, t) do
    {tracker, events, outcome} = Tracker.resync(state.session.tracker, t, depth)

    {word, moves} =
      case outcome do
        {:accepted, sans} -> {"accepted", sans}
        {:guessed, sans, _others} -> {"guessed", sans}
        {:rejected, sans} -> {"rejected", sans}
        other -> {to_string(other), []}
      end

    {_reply, state} =
      tracked(state, t, fn _tr -> {tracker, events} end, "repair.resync", %{
        outcome: word,
        moves: moves
      })

    {{:ok, outcome}, state}
  end

  defp repair(state, :choose, {number, sans}, t) do
    case Tracker.choose(state.session.tracker, t, number, sans) do
      {:ok, result, dropped} ->
        {_reply, state} =
          tracked(state, t, fn _tr -> result end, "repair.choose", %{
            ply: number,
            moves: sans,
            dropped: dropped
          })

        {{:ok, dropped}, state}

      {:error, message} ->
        {{:error, message}, state}
    end
  end

  defp repair(state, :alternatives, number, _t),
    do: {{:ok, Tracker.alternatives(state.session.tracker, number)}, state}

  defp repair(state, :result, result, t) do
    if result in Alnasl.Games.Game.results() do
      Log.add(:info, "result.set", %{result: result, by: "arbiter"}, ref(state))
      state = %{state | game: Games.finish(state.game, result)}
      {:ok, enqueue(state, t, false)}
    else
      {{:error, :bad_result}, state}
    end
  end

  # "New game on this board": the arbiter's word, whatever the board shows.
  defp repair(state, :new_game, _args, _t) do
    state = new_game(state, :arbiter)
    {:ok, refeed(state)}
  end

  # The pairing changed under this game and the arbiter says it is not the
  # new pairing's: it is kept on the box, and the board begins again for
  # whoever is paired here now. The new game is the one that leaves the box,
  # so every destination is told to replace what it holds.
  defp repair(state, :set_aside, _args, t) do
    board = state.board
    pairing = Tournaments.board(board.tournament_id, board.round, board.board_no)
    {_aside, game} = Games.set_aside(state.game, pairing)
    Log.add(:info, "pairing.set_aside", %{game: game.game_no}, ref(state))

    opts =
      Settings.tracker_opts()
      |> Keyword.put(:start_fen, game.start_fen)
      |> Keyword.put(:late_start, false)

    Recorder.record(board.id, {:cfg, cfg(board, game)})
    state = %{state | game: game, session: Session.new(opts), warning: nil, queued_at: nil}
    {:ok, state |> enqueue(t, true) |> refeed()}
  end

  defp repair(state, :reopen, _args, t) do
    Log.add(:info, "result.reopened", %{}, ref(state))
    state = %{state | game: Games.reopen(state.game)}
    {:ok, state |> enqueue(t, true) |> refeed()}
  end

  defp repair(state, :pause, paused?, t) do
    Log.add(:info, if(paused?, do: "repair.paused", else: "repair.resumed"), %{}, ref(state))
    state = %{state | game: Games.pause(state.game, paused?)}
    # Resuming says everything that was held back, in one statement.
    {:ok, if(paused?, do: state, else: enqueue(state, t, true))}
  end

  defp repair(state, _unknown, _args, _t), do: {{:error, :unknown}, state}

  # Applies a tracker operation, saves and queues what it changed (always as
  # a replacement: the arbiter has spoken), and logs who did it.
  defp tracked(state, t, fun, kind, data) do
    {session, events} = Session.with_tracker(state.session, t, fun)
    Log.add(:info, kind, Map.put(data, :by, "arbiter"), ref(state))
    state = %{state | session: session, last_t: max(t, state.last_t)}
    changed? = Enum.any?(events, &(elem(&1, 0) in [:moves, :correction, :restart]))
    state = apply_events_as_arbiter(state, events)
    {:ok, if(changed?, do: enqueue(state, t, true), else: state)}
  end

  defp apply_events_as_arbiter(state, events) do
    wall = System.os_time(:millisecond)

    Enum.reduce(events, state, fn event, state ->
      case event do
        {kind, _} when kind in [:moves, :restart] ->
          {game, _} = Games.apply_event(state.game, event, wall)
          %{state | game: game}

        {:correction, _, _, _} ->
          {game, _} = Games.apply_event(state.game, event, wall)
          %{state | game: game}

        {:status, status, detail} ->
          log_status(state, status, detail)

        {:result_suggestion, result, why} ->
          suggest(state, result, why)

        {:unseen, pieces} ->
          log_unseen(state, pieces)
          state

        _other ->
          state
      end
    end)
  end

  # --- what the site sees ------------------------------------------------------

  defp snapshot(state) do
    board = state.board
    tracker = state.session && state.session.tracker
    t = now(state)

    base = %{
      id: board.id,
      name: board.name,
      driver: board.driver,
      port: board.port,
      address: board.address,
      tournament_id: board.tournament_id,
      round: board.round,
      board_no: board.board_no,
      table_no: board.table_no,
      flipped: board.flipped,
      serial: board.serial,
      firmware: board.firmware,
      running?: true,
      connected?: state.connected?,
      last_seen: state.last_seen,
      stats: state.stats,
      info: state.info,
      raw: state.seen && Position.to_text(state.seen),
      warning: state.warning,
      player:
        if(is_pid(state.driver) and board.driver in ["simulator", "replay"],
          do: Alnasl.Driver.Player.progress(state.driver)
        ),
      linked?: tracker != nil
    }

    if tracker do
      game = state.game
      last = List.last(tracker.plies)

      Map.merge(base, %{
        status: ui_status(state, tracker),
        detail: tracker.detail,
        fen: Tracker.fen(tracker),
        certain: Position.to_text(tracker.pos.board),
        start_fen: tracker.start_fen,
        last_move: last && {last.from, last.to},
        plies: Enum.map(tracker.plies, &Map.take(&1, [:san, :flags, :read])),
        unseen:
          for(
            %{square: sq, piece: piece} = entry <- Tracker.unseen(tracker),
            do: if(entry[:ghost], do: {sq, piece, entry.ghost}, else: {sq, piece})
          ),
        clock: Clock.read(state.session.clock, t),
        clock_check: Session.clock_check(state.session),
        clock_alarm: state.session.clock_alarm,
        white: game.white,
        black: game.black,
        result: game.result,
        suggestion: game.suggestion,
        paused: game.paused,
        game_status: game.status,
        game_id: game.id,
        game_no: game.game_no,
        pairing_flag: game.pairing_flag,
        problems:
          if(tracker.plies == [] and state.seen,
            do: Position.problems(start_board(tracker), state.seen),
            else: []
          )
      })
    else
      Map.merge(base, %{
        status: if(state.connected?, do: :unlinked, else: :no_signal),
        detail: nil,
        plies: [],
        unseen: [],
        clock: nil,
        clock_check: Clock.start_check(state.clock),
        clock_alarm: nil,
        problems: if(state.seen, do: Position.problems(Position.start(), state.seen), else: [])
      })
    end
  end

  # The one word on the tile.
  defp ui_status(state, tracker) do
    cond do
      state.game.status == "finished" -> :finished
      not state.connected? -> :no_signal
      tracker.status == :out_of_sync -> :out_of_sync
      state.session.clock_alarm != nil -> :clock_alarm
      tracker.status == :live and recovered?(tracker) -> :recovered
      true -> tracker.status
    end
  end

  defp recovered?(%{plies: plies}) do
    case List.last(plies) do
      %{flags: flags} -> :recovered in flags or :guessed in flags
      nil -> false
    end
  end
end
