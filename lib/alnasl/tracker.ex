defmodule Alnasl.Tracker do
  @moduledoc """
  Turns what a board reports - where the pieces are - into the moves of a game.

  A pure state machine: no process, no clock of its own. Every call takes the
  time `t` (milliseconds, any monotonic origin) and returns the new state and
  the events that follow, so a test can play a five-hour game in a
  millisecond and the board's process can drive the same code in real time.

  ## What it holds

  - the **certain** position and move list: only what has been explained by
    legal moves;
  - `phys`, what the sensors should read for that position (the position's
    own board, except where a pawn was left standing on its promotion square);
  - `raw`, the last board reported, and since when it has read like that;
    `before`, the board it read before that.

  ## What it does with a board

  In this order, the first that fits (see `docs/design.md` for the reasons):

  1. the board is the certain one - in sync;
  2. it is one legal move away - accepted once it has stood for `settle_ms`
     (longer when it could be half a castle or a pawn waiting for its queen),
     or at once on a clock press;
  3. it is an earlier certain position - a takeback;
  4. it is one move away from the position before the last move - the last
     move is replaced (a rook sliding through a square, a hand that let go
     and took hold again);
  5. it is two or more legal moves away - the moves are looked for
     (`reconstruct/4`, `Alnasl.Tracker.Search`), taken, and marked: one line
     `:recovered`, one of several `:guessed`. The board keeps up; the mark
     says how sure that is;
  6. the reading before this one was one legal move, and now one or two
     other pieces are in the air - the next hand is already on the board.
     The move is accepted at once: in fast play nothing stands still for
     `settle_ms`;
  7. none of these - a hand, a knocked piece, half a capture. Nothing is
     emitted. Only when it stays unexplained for `transient_ms`
     (`lifted_ms` when it is just a piece or two in the air) does the status
     become `:out_of_sync`, and the tracker keeps watching: the moment the
     board is explained again it carries on by itself.

  ## Events

  - `{:moves, [ply]}` - appended to the game;
  - `{:correction, keep, [ply], reason}` - the game is now its first `keep`
    plies followed by these; `reason` is `:takeback | :revised | :promotion |
    :misread | :arbiter`;
  - `{:restart, fen}` - the game starts over from this position;
  - `{:status, status, detail}` - `:waiting_start | :live | :settling |
    :out_of_sync`. The detail of `:out_of_sync` is why: `:unexplained`,
    `:piece_missing`, `:search_gave_up`, or what the board plainly shows -
    `{:out_of_turn, move}` and `{:illegal, move}` (`named/1`);
  - `{:unseen, [%{square, piece}]}` - the pieces taken to stand where the
    board does not show them, whenever that list changes;
  - `{:result_suggestion, result, why}` - mate, stalemate, bare kings, or the
    kings set in the centre. A suggestion: the arbiter decides.

  A ply is `%{san, from, to, promo, flags, at, fen}`; `flags` may hold
  `:recovered` (reconstructed: not seen, and one line of moves fits),
  `:guessed` (not seen, and one of several lines was taken), `:long_gap`
  (found across a hole in what the box knows: the board was gone), `:assumed` (promotion piece not seen), `:unseen`
  (made while a piece was out of sight), `:arbiter` (entered by hand),
  `:rewritten` (first read as another move of the same piece, to the
  square beside this one: the ply then also has `read`, the SAN it was read
  as, and `span`, how many plies the rewrite covered), `:alone` (a guess
  because the one line found cannot be vouched for).
  """

  alias Alnasl.{Chess, Position}
  alias Alnasl.Tracker.Search

  @defaults %{
    # Long enough for a knight that touches down on its way (the real
    # board's capture has one resting 224 ms on d4), short enough for the
    # last minute of a game: at 400 a time scramble went by half unseen.
    settle_ms: 250,
    deep_settle_ms: 5_000,
    castle_hold_ms: 2_500,
    promotion_hold_ms: 4_000,
    takeback: true,
    takeback_plies: 2,
    takeback_settle_ms: 1_500,
    # How many plies the box may reconstruct by itself when the board has
    # run ahead of the game: `search_depth` guided by the squares that were
    # seen to change, `blind_depth` when nothing was seen of them (and more
    # than two of those only once the board has stood for `deep_settle_ms`).
    # Nothing found this way is silent: one path is marked `:recovered`,
    # one of several `:guessed`.
    search_depth: 8,
    blind_depth: 4,
    # More clock presses than moves: look for a longer path than the
    # shortest (`pressed_for/3`).
    press_count: true,
    # A move that makes no sense of the board may be an earlier move misread
    # (`rewrites/1`): a piece set down between two squares.
    misread: true,
    max_nodes: 4_000,
    max_ms: 500,
    transient_ms: 8_000,
    lifted_ms: 60_000,
    promotion_default: :q,
    result_gesture: true,
    # A piece that left its square and stayed away while the game went on
    # is taken to be standing there unseen (see "A piece not seen"). A move
    # that would make it so must stand this long, or be pressed on the clock.
    unseen_piece: true,
    unseen_hold_ms: 2_000,
    # A board plugged in a move or two into its game is caught up from the
    # starting position. Not a game begun on a board that still shows the
    # last one ("New game on this board"): that one waits for the pieces
    # to be set up.
    late_start: true
  }

  # How many pieces may be unseen at once. One: a second piece gone is more
  # likely an exchange nobody saw than a second player with a pocket.
  @unseen_max 1

  # How many readings are remembered for the reconstruction: which squares
  # changed since a position, and in what order.
  @trail 400

  # How many plies back a misread move is looked for: a piece left crooked
  # for two moves each, and the "move" that was somebody straightening it.
  @misread_back 6

  defstruct opts: @defaults,
            start_fen: nil,
            pos: nil,
            phys: nil,
            plies: [],
            history: [],
            raw: nil,
            raw_since: 0,
            before: nil,
            ready?: false,
            begun?: false,
            at: 0,
            status: :waiting_start,
            detail: nil,
            trail: [],
            presses: nil,
            debt: 0,
            pressed_at: nil,
            accepted_at: nil,
            deaf?: false,
            as_read: nil,
            rejected: nil,
            memo: nil,
            gesture: nil,
            held: nil,
            unseen: [],
            absent: nil,
            stats: %{searches: 0, max_nodes: 0, max_us: 0, budget_hits: 0}

  @type t :: %__MODULE__{}
  @type event :: tuple()

  # What fast play changes. A move stands for a blink, so less is asked of
  # it; and nobody takes a move back with ten seconds on the clock - what
  # looks like a takeback at that speed is a piece going to and fro, and is
  # read as moves. The two belong together: over 690 simulated bullet games
  # with slams, knocks and missed plies, either alone left 9 and 19 games
  # in an alarm, both together 3 (and the defaults 25).
  #
  # Not in it, on purpose: the waits for a rook that may be castling and
  # for a pawn's piece. Shortening them saved one game in 690 and showed a
  # rook move that became a castle a moment later 57 times.
  @bullet %{settle_ms: 150, takeback: false}

  @doc "The settings and their defaults."
  def defaults, do: @defaults

  @doc """
  A named set of settings, as the map of what it changes from the defaults:
  `:bullet` is "Bullet / fast play" on the Setup page, anything else the
  defaults (an empty map). The search depth is not part of it: how many
  unseen moves the box may work out by itself is a matter of trust, not of
  speed.
  """
  def preset(:bullet), do: @bullet
  def preset(_classical), do: %{}

  @doc "A tracker for a game that starts from `:start_fen` (the standard position)."
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)
    fen = Map.get(opts, :start_fen) || Chess.start_fen()
    {:ok, pos} = Chess.parse_fen(fen)

    %__MODULE__{
      opts: Map.merge(@defaults, Map.take(opts, Map.keys(@defaults))),
      start_fen: fen,
      pos: pos,
      phys: pos.board
    }
  end

  @doc "Rebuilds a tracker from a stored game: the start position and its SAN moves."
  @spec restore(keyword() | map(), [map() | String.t()]) :: t()
  def restore(opts, plies) do
    tr = new(opts)

    Enum.reduce(plies, tr, fn ply, tr ->
      san = if is_binary(ply), do: ply, else: ply.san
      {:ok, move} = Chess.parse_san(tr.pos, san)
      flags = if is_map(ply), do: Map.get(ply, :flags, []), else: []
      at = if is_map(ply), do: Map.get(ply, :at, 0), else: 0
      {tr, _plies} = push(tr, [{move, flags}], [], at, nil)
      if is_map(ply) and ply[:read], do: noted(tr, length(tr.plies) - 1, ply), else: tr
    end)
    |> then(&%{&1 | status: if(&1.plies == [], do: :waiting_start, else: :live)})
  end

  @doc "The moves so far, as SAN."
  def sans(%__MODULE__{plies: plies}), do: Enum.map(plies, & &1.san)

  @doc "The FEN of the certain position."
  def fen(%__MODULE__{pos: pos}), do: Chess.to_fen(pos)

  @doc """
  The pieces taken to stand where the board does not see them:
  `[%{square, piece}]`, `piece` as `{colour, kind}`. An entry with `ghost`
  is a piece the board reads on that square instead: set down between the
  two, and found out by a later move (`rewrites/1`).
  """
  def unseen(%__MODULE__{unseen: unseen}), do: unseen

  @doc """
  The next time at which `tick/2` could change anything, or `nil` when the
  tracker is waiting for the board.
  """
  def deadline(%__MODULE__{raw: nil}), do: nil

  def deadline(%__MODULE__{} = tr) do
    o = tr.opts

    marks =
      [
        o.settle_ms,
        o.deep_settle_ms,
        o.castle_hold_ms,
        o.promotion_hold_ms,
        o.takeback_settle_ms,
        o.transient_ms,
        o.lifted_ms,
        o.unseen_hold_ms
      ]
      |> Enum.map(&(tr.raw_since + &1))

    if tr.raw == tr.phys or (tr.held != nil and tr.held == tr.raw),
      do: nil,
      else: marks |> Enum.filter(&(&1 > tr.at)) |> Enum.min(fn -> nil end)
  end

  # --- what comes in -----------------------------------------------------------

  @doc "The board reads `board` at time `t`."
  @spec observe(t(), integer(), tuple()) :: {t(), [event()]}
  def observe(%__MODULE__{} = tr, t, board) when is_tuple(board) do
    was = tr

    tr =
      if board == tr.raw,
        do: tr,
        else: %{
          unpressed(tr)
          | raw: board,
            raw_since: t,
            before: tr.raw,
            trail: Enum.take([{length(tr.plies), board} | tr.trail], @trail)
        }

    tr |> evaluate(t, false) |> noting(was)
  end

  @doc "A clock was pressed at `t`: a move that is waiting to settle is accepted now."
  @spec press(t(), integer()) :: {t(), [event()]}
  def press(%__MODULE__{} = tr, t), do: tr |> evaluate(t, true) |> noting(tr)

  @doc "Time passed. Call it at `deadline/1`, or every 100 ms."
  @spec tick(t(), integer()) :: {t(), [event()]}
  def tick(%__MODULE__{} = tr, t), do: tr |> evaluate(t, false) |> noting(tr)

  # --- the arbiter -------------------------------------------------------------

  @doc """
  Takes back the last `n` plies. The board, which usually still shows them,
  is not read again until it changes: the arbiter has just said what it
  shows is not the game, and re-reading it at once would put the move back.

  Nor are they found again later. The moves taken back are remembered as
  `rejected` for the position they were taken back to, and no search from
  there - the tracker's own, or "The board is right" - returns exactly
  them: an arbiter who takes six moves back and asks what the board shows
  wants another answer, not the same six. Any move accepted, by the board
  or by hand, ends that - and so does the game going on: those moves with
  another played on top are found like any others.
  """
  def undo(%__MODULE__{} = tr, t, n \\ 1) do
    keep = max(length(tr.plies) - n, 0)
    was = tr
    undone = tr.plies |> Enum.drop(keep) |> Enum.map(& &1.san)

    earlier =
      case tr.rejected do
        %{count: count, sans: sans} when count == length(tr.plies) -> sans
        _other -> []
      end

    {tr, events} = correct(tr, t, keep, [], :arbiter)
    tr = %{tr | held: tr.raw, rejected: %{count: keep, sans: undone ++ earlier}}
    noting({tr, events}, was)
  end

  @doc "Adds moves typed in SAN. `{:error, {index, message}}` names the first that is not legal."
  def append(%__MODULE__{} = tr, t, sans) do
    with {:ok, steps} <- parse_sans(tr.pos, sans) do
      was = tr
      {tr, plies} = push(tr, steps, [:arbiter], t, nil)
      tr = %{tr | memo: nil, rejected: nil}
      {:ok, {tr, [{:moves, plies}]} |> and_then(&evaluate(&1, t, false)) |> noting(was)}
    end
  end

  @doc """
  Replaces ply `number` (1-based) by `san` and replays the moves after it as
  far as they are still legal. `{:ok, {tracker, events}, dropped}` where
  `dropped` is how many later moves no longer fit.
  """
  def edit(%__MODULE__{} = tr, t, number, san)
      when number >= 1 and number <= length(tr.plies) do
    before = Enum.at(tr.history, length(tr.plies) - number)
    later = tr.plies |> Enum.drop(number) |> Enum.map(& &1.san)

    with {:ok, move} <- Chess.parse_san(before.pos, san) do
      first = {move, [:arbiter]}
      {rest, dropped} = replay_while_legal(Chess.apply_move(before.pos, move), later, [])
      was = tr
      {tr, events} = correct(tr, t, number - 1, [first | rest], :arbiter)
      # As with `undo/3`: the board is looked at again when it next changes.
      {:ok, noting({%{tr | held: tr.raw}, events}, was), dropped}
    end
  end

  def edit(_tr, _t, _number, _san), do: {:error, "there is no such move"}

  @doc "Starts the game over from `fen`: a resumed or adjourned game, or a last resort."
  def set_position(%__MODULE__{} = tr, t, fen) do
    case Chess.parse_fen(fen) do
      {:ok, pos} ->
        fen = Chess.to_fen(pos)
        fresh = %{new(Map.put(tr.opts, :start_fen, fen)) | raw: tr.raw, raw_since: tr.raw_since}
        {:ok, {fresh, [{:restart, fen}]} |> and_then(&evaluate(&1, t, false)) |> noting(tr)}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  How often the clock has been pressed in this game, as far as anybody
  knows. More presses than moves means the board has run ahead by at least
  that many plies, which the reconstruction is told (`reconstruct/4`).

  And more moves than presses means the box has made up moves. `debt` is
  how far the game has ever been ahead of the clock at the moment of a
  press - players who forget the lever run up a debt and keep it - and a
  line that would put the game further ahead than that, by more than the
  one press that may still be on its way, is not taken (`fits?/2`).
  """
  def presses(tr, count, t \\ nil)

  # No clock (any more): nothing is known, and nothing is held against a line.
  def presses(%__MODULE__{} = tr, nil, _t), do: %{tr | presses: nil}

  def presses(%__MODULE__{} = tr, count, t) do
    pressed? = tr.presses != nil and count > tr.presses

    %{
      tr
      | presses: count,
        # Measured when a press arrives: between presses the game is
        # always a move ahead of the clock.
        debt: if(pressed?, do: max(tr.debt, length(tr.plies) - count), else: tr.debt),
        pressed_at: if(pressed?, do: t || tr.at, else: tr.pressed_at)
    }
  end

  @doc """
  The board was not heard for a while (the cable was out). Its clock was
  not heard either, so the next line found is not measured against the
  presses: whatever it adds to the game becomes debt.
  """
  def deaf(%__MODULE__{} = tr), do: %{tr | deaf?: true}

  @doc """
  "The board is right": search for the moves that lead from the game as it
  stands to the board as it reads now, deeper and for longer than the
  tracker does by itself (`depth` plies even where nothing was seen of
  them). `{tracker, events, outcome}` with `outcome` one of
  `{:accepted, sans}` (one path), `{:guessed, sans, others}` (one of
  several, taken; `others` is how many more), `{:rejected, sans}` (nothing
  explains the board but the moves the arbiter has just taken back),
  `:none`, `:budget`.
  """
  def resync(%__MODULE__{raw: nil} = tr, _t, _depth), do: {tr, [], :none}

  def resync(%__MODULE__{} = tr, t, depth) do
    o = tr.opts

    # The arbiter says the board is a game: not pieces being set up.
    wide = %{
      tr
      | memo: nil,
        begun?: true,
        opts: %{
          o
          | search_depth: max(depth, o.search_depth),
            blind_depth: depth,
            # The arbiter asked and is waiting: seconds, not a fraction of one.
            max_nodes: o.max_nodes * 100,
            max_ms: o.max_ms && o.max_ms * 10
        }
    }

    {found, sure?, hit?, wide} = paths(wide, here(wide), o.deep_settle_ms, :all, 1)

    # The arbiter asked: lines with more moves than presses are not held
    # back, and a piece going out and back is still the last thing offered.
    found =
      Enum.sort_by(found, &null_trip?(Enum.map(&1.steps, fn {move, _flags} -> move end)))

    case found do
      [] ->
        # Nothing - or nothing but the moves that were just taken back.
        {again, _sure?, _hit?, _wide} =
          paths(%{wide | rejected: nil}, here(wide), o.deep_settle_ms, :all, 1)

        outcome =
          cond do
            again != [] -> {:rejected, tr.rejected.sans}
            hit? -> :budget
            true -> :none
          end

        {tr, [], outcome}

      [best | rest] ->
        flags =
          cond do
            rest == [] and sure? -> [:recovered, :arbiter]
            rest == [] -> [:guessed, :alone]
            true -> [:guessed]
          end

        {done, events} = wide |> accept(t, best.steps, flags) |> noting(tr)
        sans = done.plies |> Enum.drop(length(tr.plies)) |> Enum.map(& &1.san)
        done = %{done | opts: o, memo: nil, begun?: tr.begun?}

        {done, events,
         if(:guessed in flags, do: {:guessed, sans, length(rest)}, else: {:accepted, sans})}
    end
  end

  @doc """
  The other ways the marked moves around ply `number` (1-based) can have
  gone - what a person comparing with a scoresheet would consider:

  - every legal line of the same length, or shorter, from the position
    before those moves to the position after them;
  - an earlier move misread (`rewrites/1`): one of the few moves before
    them going to a neighbouring square instead, with the moves read since
    replayed and as few new ones as it takes. Such an option begins at the
    misread move, and so then do all the others;
  - for a move that was itself rewritten, the move as it was read.

  Ranked as the tracker ranks (`worth/2`): no piece going out and straight
  back while another line does without, fewer moves first. Lines with more
  moves than the clock was pressed for are left out. At most 64: they are
  asked about a move at a time, not read.

  `%{from: first_ply, to: last_ply, fen: fen_before, current: [san],
  options: [[san]], read: {ply, san} | nil}` - `current` is among
  `options`, wherever it ranks - or `nil` when that ply is not a marked one.
  """
  def alternatives(%__MODULE__{} = tr, number) do
    with {first, last} <- run(tr, number) do
      count = length(tr.plies)
      state = fn ply -> Enum.at(tr.history, count - ply) end
      target = if last == count, do: tr.phys, else: Enum.at(tr.history, count - last - 1).phys
      run = Enum.slice(tr.plies, (first - 1)..(last - 1))
      before = state.(first)
      o = tr.opts

      # The squares the readings saw change are not kept with the game;
      # the squares the board differs on and the ones these moves used are
      # what is left of them. Every legal move is tried only for moves
      # found across a hole in contact, which the mark `:long_gap` says.
      seen = Position.diff(before.phys, target) ++ Enum.flat_map(run, &[&1.from, &1.to])
      wide = if Enum.any?(run, &(:long_gap in &1.flags)), do: [], else: [evidence: seen]

      forward =
        for {min, max, limits} <- [
              {1, length(run), [touch: seen]},
              {length(run), length(run), [touch: seen]},
              {1, min(length(run), o.blind_depth), wide}
            ],
            {:ok, found, _nodes} <- [
              Search.find(
                before.pos,
                before.phys,
                target,
                [
                  min_depth: min,
                  max_depth: max,
                  max_nodes: o.max_nodes,
                  max_ms: o.max_ms,
                  promotion_default: o.promotion_default,
                  unseen: Enum.map(before.unseen, & &1.square)
                ] ++ limits
              )
            ],
            one <- found,
            do: {first, Enum.map(one.steps, &elem(&1, 0))}

      # An earlier move misread: the option starts there.
      earlier =
        for back <- 1..min(@misread_back, first - 1)//1,
            start = first - back,
            ply = Enum.at(tr.plies, start - 1),
            :arbiter not in ply.flags,
            from = state.(start),
            from.unseen == [],
            move <- nearby(from.pos, ply),
            {between, _dropped} =
              straight(ply, move, Enum.slice(tr.plies, start..(first - 2)//1)),
            line <- rewritten(tr, from, move, between, target, ply),
            line[:ghost] == nil,
            do: {start, Enum.map(line.steps, &elem(&1, 0))}

      # The move as it was read, when this run is a rewrite.
      as_read =
        case hd(run) do
          %{read: read, span: span} when is_binary(read) ->
            {:ok, move} = Chess.parse_san(before.pos, read)
            # Only the moves that were read, not the ones found to fit them.
            read_since = run |> Enum.drop(1) |> Enum.reject(&marked?/1) |> Enum.take(span)
            [{board, _} | _] = Search.outcomes(before.phys, move, before.pos.turn, nil)
            pos = Chess.apply_move(before.pos, move)
            specs = Enum.map(read_since, &{&1.from, &1.to, &1.promo, &1.flags})

            case replay_specs(pos, board, specs, []) do
              {:ok, steps, phys} ->
                done = Enum.reduce(steps, pos, fn {m, _}, p -> Chess.apply_move(p, m) end)
                stem = [move | Enum.map(steps, &elem(&1, 0))]

                tails =
                  for one <- complete(tr, done, phys, target, 4),
                      tail = Enum.map(one, &elem(&1, 0)),
                      not null_trip?(tail),
                      do: tail

                for tail <- if(tails == [], do: [[]], else: tails), do: {first, stem ++ tail}

              :error ->
                []
            end

          _plain ->
            []
        end

      from = Enum.min([first | Enum.map(earlier, &elem(&1, 0))])
      origin = state.(from)

      # The moves of the game from `from` up to where an option starts.
      lead = fn start ->
        tr.plies |> Enum.drop(from - 1) |> Enum.take(start - from) |> Enum.map(& &1.san)
      end

      current = lead.(first) ++ Enum.map(run, & &1.san)

      # The move as it was read with nothing after it does not reach the
      # board: it is there for the arbiter who knows better, last.
      short =
        for {_start, moves} <- as_read, length(moves) < length(run), into: MapSet.new(), do: moves

      options =
        (forward ++ earlier ++ as_read)
        |> Enum.map(fn {start, moves} ->
          {moves, lead.(start) ++ sans_of(state.(start).pos, Enum.map(moves, &{&1, []}))}
        end)
        |> Enum.uniq_by(&elem(&1, 1))
        |> Enum.reject(fn {_moves, sans} -> sans == current end)
        |> Enum.filter(fn {_moves, sans} ->
          fits?(tr, count - (last - from + 1) + length(sans))
        end)

      # A line that goes out and straight back is offered only when it is
      # all there is.
      {plain, null} = Enum.split_with(options, fn {moves, _sans} -> not null_trip?(moves) end)
      mine = Enum.map(run, &move_of(tr, &1))
      offered = if plain == [] and not null_trip?(mine), do: null, else: plain

      ranked =
        [{mine, current} | offered]
        |> Enum.sort_by(fn {moves, sans} ->
          {null_trip?(moves), MapSet.member?(short, moves) and as_read != [], length(sans),
           sans != current, sans}
        end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.take(64)

      %{
        from: from,
        to: last,
        fen: Chess.to_fen(origin.pos),
        current: current,
        options: if(current in ranked, do: ranked, else: ranked ++ [current]),
        read:
          case hd(run) do
            %{read: read} when is_binary(read) -> {first, read}
            _plain -> nil
          end
      }
    else
      _none -> nil
    end
  end

  # A stored ply as the squares of its move: enough to see a round trip.
  defp move_of(_tr, ply), do: %{from: ply.from, to: ply.to, capture: nil, kind: :normal}

  defp marked?(ply), do: :recovered in ply.flags or :guessed in ply.flags

  @doc """
  The arbiter says the reconstructed moves around ply `number` were `sans`
  (one of `alternatives/2`). The game is rewritten from there; the moves
  after them are kept as far as they are still legal.
  `{:ok, {tracker, events}, dropped}` or `{:error, message}`.
  """
  def choose(%__MODULE__{} = tr, t, number, sans) do
    with %{from: first, to: last, options: options} <- alternatives(tr, number),
         true <- sans in options do
      before = Enum.at(tr.history, length(tr.plies) - first)
      later = tr.plies |> Enum.drop(last) |> Enum.map(& &1.san)
      {:ok, steps} = parse_sans(before.pos, sans)
      steps = Enum.map(steps, fn {move, _flags} -> {move, [:arbiter]} end)

      after_them =
        Enum.reduce(steps, before.pos, fn {move, _}, pos -> Chess.apply_move(pos, move) end)

      {rest, dropped} = replay_while_legal(after_them, later, [])
      was = tr
      {tr, events} = correct(tr, t, first - 1, steps ++ rest, :arbiter)
      # As with `undo/3`: the board is looked at again when it next changes.
      {:ok, noting({%{tr | held: tr.raw}, events}, was), dropped}
    else
      _no -> {:error, "that is not one of the ways those moves can have gone"}
    end
  end

  # The marked plies that ply `number` belongs with, as `{first, last}`
  # (1-based): the rewritten move it follows together with everything that
  # rewrite covered (the moves read since, which are not marked, and the
  # new ones), or else the run of reconstructed or guessed plies it is in.
  defp run(tr, number) do
    marked? = fn ply -> ply != nil and marked?(ply) end
    at = fn n -> if n >= 1, do: Enum.at(tr.plies, n - 1) end

    rewrite =
      tr.plies
      |> Enum.with_index(1)
      |> Enum.find(fn {ply, index} ->
        is_binary(ply[:read]) and marked?(ply) and number >= index and
          number <= index + (ply[:span] || 1) - 1
      end)

    cond do
      rewrite != nil ->
        {ply, index} = rewrite
        {index, min(index + (ply[:span] || 1) - 1, length(tr.plies))}

      marked?.(at.(number)) ->
        first = Enum.find(number..1//-1, &(not marked?.(at.(&1 - 1))))
        last = Enum.find(number..length(tr.plies), &(not marked?.(at.(&1 + 1))))
        {first, last}

      true ->
        nil
    end
  end

  defp sans_of(pos, steps) do
    {sans, _pos} =
      Enum.map_reduce(steps, pos, fn {move, _flags}, pos ->
        {Chess.san(pos, move), Chess.apply_move(pos, move)}
      end)

    sans
  end

  # --- the decision ------------------------------------------------------------

  defp evaluate(%__MODULE__{raw: nil} = tr, t, _force), do: {%{tr | at: t}, []}

  # The arbiter changed the game by hand and the board has not moved since:
  # it is left alone until it does.
  defp evaluate(%__MODULE__{held: held, raw: raw} = tr, t, _force)
       when held != nil and held == raw,
       do: {%{tr | at: t}, []}

  defp evaluate(%__MODULE__{} = tr, t, force) do
    tr = %{tr | at: t, held: nil}
    stable = t - tr.raw_since

    # A clock pressed over a board that stood in the starting position, has
    # left it, and of which no move was understood: the game has begun, and the box did
    # not see how. From here an unexplained board is an alarm like any
    # other, not pieces still being set up (`unexplained/3`).
    tr =
      if force and tr.ready? and tr.plies == [] and tr.raw != tr.phys and
           not Position.in_hand?(tr.phys, tr.raw),
         do: %{tr | begun?: true},
         else: tr

    tr = tr |> seen_again() |> absent()

    cond do
      # A move was rewritten to make the next one legal - and the board is
      # back to what it read before that next one. Then the "next move"
      # was a piece put somewhere it could not go and taken back, and the
      # move as it was read stands.
      tr.as_read != nil and tr.raw == tr.as_read.tracker.phys ->
        unrewrite(tr, t)

      tr.raw == tr.phys ->
        in_sync(tr)

      normal?(tr) ->
        in_sync(%{tr | phys: tr.raw})

      true ->
        explain(tr, t, stable, force)
    end
  end

  # A piece that was not seen stands on its square again: it was there all
  # along, as assumed. Whatever else the board shows is looked at after.
  defp seen_again(%{unseen: []} = tr), do: tr

  defp seen_again(tr) do
    Enum.reduce(tr.unseen, tr, fn %{square: square, piece: piece} = entry, tr ->
      if elem(tr.raw, square) == piece do
        phys = put_elem(tr.phys, square, piece)

        # A piece that was read on the square beside its own has been
        # straightened: it reads where it stands, and not where it did.
        phys =
          case entry[:ghost] do
            nil -> phys
            ghost -> if elem(tr.raw, ghost) == nil, do: put_elem(phys, ghost, nil), else: phys
          end

        %{tr | phys: phys, unseen: tr.unseen -- [entry]}
      else
        tr
      end
    end)
  end

  # The one piece that is missing while nothing else differs - and stays
  # the piece to wonder about for as long as its square stays empty,
  # whatever else is lifted meanwhile. A hand holding the piece it is about
  # to move looks exactly like this, which is why this alone means nothing.
  defp absent(tr) do
    gone? = fn square -> elem(tr.raw, square) == nil and elem(tr.phys, square) != nil end

    square =
      case Position.diff(tr.phys, tr.raw) do
        [square] -> if gone?.(square), do: square
        _other -> if tr.absent && gone?.(tr.absent), do: tr.absent
      end

    %{tr | absent: square}
  end

  # The tracker as it would be if the absent piece were taken to stand on
  # its square unseen - or `nil` when that may not be supposed: the rule is
  # off, a piece is unseen already, or it is a king (nobody parks a king
  # beside the board; a king in the air is castling).
  defp supposing(%{opts: %{unseen_piece: false}}), do: nil
  defp supposing(%{absent: nil}), do: nil
  defp supposing(%{unseen: unseen}) when length(unseen) >= @unseen_max, do: nil

  defp supposing(%{absent: square} = tr) do
    case elem(tr.phys, square) do
      {_colour, :k} ->
        nil

      piece ->
        if elem(tr.pos.board, square) == piece,
          do: %{
            tr
            | phys: put_elem(tr.phys, square, nil),
              unseen: [%{square: square, piece: piece} | tr.unseen],
              absent: nil
          }
    end
  end

  # One legal move by another piece explains the board, if the absent piece
  # is still where it was. (A move that takes the absent piece, or is the
  # absent piece's own, needs no supposing: the board shows those whole.)
  defp unseen_move(tr) do
    with %{} = supposed <- supposing(tr),
         [{move, flags}] <- one_ply(supposed),
         true <- move.from != tr.absent and move.to != tr.absent do
      {supposed, move, flags}
    else
      _no -> nil
    end
  end

  # Moves were accepted on the supposition; what the game goes back to when
  # they are undone is the board as it was before it: the piece on its
  # square, seen.
  defp since({tr, events}, was) do
    back = length(tr.plies) - length(was.plies)

    history =
      List.update_at(tr.history, back - 1, &%{&1 | phys: was.phys, unseen: was.unseen})

    {%{tr | history: history}, events}
  end

  defp unseen_under_hand(tr) do
    with %{} = supposed <- supposing(tr),
         {move, _board} = step <- move_under_hand(supposed),
         true <- move.from != tr.absent and move.to != tr.absent do
      {supposed, step}
    else
      _no -> nil
    end
  end

  defp unrewrite(%{as_read: %{tracker: was, keep: keep}} = tr, t) do
    back = %{
      was
      | raw: tr.raw,
        raw_since: tr.raw_since,
        before: tr.before,
        at: t,
        trail: tr.trail,
        presses: tr.presses,
        debt: tr.debt,
        pressed_at: tr.pressed_at,
        stats: tr.stats,
        memo: nil,
        as_read: nil,
        # So that the status below is said, whatever it was then.
        status: tr.status,
        detail: tr.detail
    }

    {back, status} = set_status(back, :live, nil)
    {back, [{:correction, keep, Enum.drop(back.plies, keep), :revised}] ++ status}
  end

  defp in_sync(tr) do
    tr = %{
      tr
      | gesture: nil,
        # Back, and nothing happened meanwhile: no hole to reason across.
        deaf?: false,
        begun?: false,
        ready?: tr.ready? or tr.plies == []
    }

    if tr.plies == [],
      do: set_status(tr, :waiting_start, :ready),
      else: set_status(tr, :live, nil)
  end

  # The board differs from what the sensors were expected to read, but only
  # where it now shows what the position really holds: the pawn that stood in
  # for a queen has been swapped for one.
  defp normal?(tr) do
    tr.phys != tr.pos.board and
      Enum.all?(Position.diff(tr.phys, tr.raw), &(elem(tr.raw, &1) == elem(tr.pos.board, &1)))
  end

  defp explain(tr, t, stable, force) do
    o = tr.opts

    case one_ply(tr) do
      [{move, flags}] ->
        if force or stable >= hold(tr, move, flags),
          do: accept(tr, t, [{move, flags}], []),
          else: set_status(tr, :settling, :move)

      _none ->
        cond do
          (step = move_under_hand(tr)) != nil ->
            accept_under_hand(tr, t, step)

          # The same, with a piece that is not on the board any more.
          (found = unseen_under_hand(tr)) != nil ->
            {supposed, step} = found
            supposed |> accept_under_hand(t, step) |> since(tr)

          (found = unseen_move(tr)) != nil ->
            {supposed, move, flags} = found

            if force or stable >= max(hold(tr, move, flags), o.unseen_hold_ms),
              do: supposed |> accept(t, [{move, flags}], []) |> since(tr),
              else: set_status(tr, :settling, :move)

          stable < o.settle_ms ->
            set_status(tr, :settling, :moving)

          (k = takeback(tr)) != nil and not replayable?(tr, k) ->
            cond do
              stable < o.takeback_settle_ms ->
                set_status(tr, :settling, :takeback)

              (lines = straightened(tr, k)) != [] ->
                rewrite(tr, t, lines)

              true ->
                correct(tr, t, length(tr.plies) - k, [], :takeback)
            end

          (fix = promotion_fix(tr)) != nil ->
            {keep, steps} = fix
            correct(tr, t, keep, steps, :promotion)

          (step = revision(tr)) != nil ->
            correct(tr, t, length(tr.plies) - 1, [step], :revised)

          true ->
            deeper(tr, t, stable)
        end
    end
  end

  # A board with a piece or two missing and nothing else changed is a hand.
  # It is not searched: the only "moves" that explain it are a capture by a
  # piece that then went home, and believing those costs more than waiting.
  # Only when it has been so for as long as the alarm waits is it asked
  # whether moves that were SEEN explain it - and if not, the alarm.
  defp deeper(tr, t, stable) do
    cond do
      Position.in_hand?(tr.phys, tr.raw) and not exchange?(tr, stable) ->
        if stable >= tr.opts.lifted_ms,
          do: reconstruct(tr, t, stable, :guided),
          else: unexplained(tr, stable, :unexplained)

      # The same hand, over the position of a move ago: a move being taken
      # back with a piece still in the air. A king that steps aside, lets a
      # queen take its place and takes her, leaves the same board - so this
      # one is searched after all, but only once it has stood still.
      stable < tr.opts.deep_settle_ms and tr.opts.takeback and
          tr.history
          |> Enum.take(tr.opts.takeback_plies)
          |> Enum.any?(&Position.in_hand?(&1.phys, tr.raw)) ->
        unexplained(tr, stable, :unexplained)

      true ->
        reconstruct(tr, t, stable, :all)
    end
  end

  # Two pieces gone, one of each colour, and the one cannot take the other:
  # not a capture half made. It is what a capture and its recapture by a
  # piece of the same kind leave behind when neither was seen (hxg6 hxg6: a
  # pawn stands on g6 as before, and both h-pawns are gone), and that is
  # worth a search - a third move on top of it is out of reach of a search
  # two plies deep.
  defp exchange?(tr, stable) do
    us = tr.pos.turn

    # Not when one of the two was already gone by itself before the other
    # was lifted: that is a piece out of sight and a hand, and the hand is
    # about to say which move it was.
    with true <- stable >= tr.opts.settle_ms,
         nil <- supposing(tr),
         [a, b] <- Position.diff(tr.phys, tr.raw),
         {colour_a, _} <- elem(tr.phys, a),
         {colour_b, _} <- elem(tr.phys, b),
         true <- colour_a != colour_b do
      {mine, theirs} = if colour_a == us, do: {a, b}, else: {b, a}

      not Enum.any?(Chess.legal_moves(tr.pos), fn move ->
        move.from == mine and (move.to == theirs or move.kind == :ep)
      end)
    else
      _no -> false
    end
  end

  # --- the reconstruction ------------------------------------------------------
  #
  # The board is a position, and not one the game as it stands leads to by
  # any rule above. Rather than stop, find the moves:
  #
  # 1. from the game as it stands, over the squares that were seen to
  #    change (`Search`, `:touch`), up to `search_depth` plies;
  # 2. the same without that guide, for moves nobody saw anything of: two
  #    plies, `blind_depth` once the board has stood for `deep_settle_ms`;
  # 3. with the absent piece taken to be unseen (two plies);
  # 4. once the board has stood unexplained for `transient_ms`: from before
  #    the last moves that were themselves reconstructed. They explained
  #    the board then, and do not explain this one.
  #
  # One path is accepted and marked `:recovered`. Of several, the first by
  # `rank/3` is accepted and marked `:guessed`; `alternatives/2` lists the
  # others for the arbiter. None: the alarm, as before.
  defp reconstruct(tr, t, stable, scope) do
    from = here(tr)
    {found, sure?, hit?, tr} = paths(tr, from, stable, scope, 2)
    why = if hit?, do: :search_gave_up, else: :unexplained

    found =
      if stable >= tr.opts.deep_settle_ms or not in_hand?(tr, found), do: found, else: []

    found = usable(tr, from, found)

    misread =
      cond do
        scope != :all -> []
        stable >= tr.opts.deep_settle_ms -> rewrites(tr)
        hand?(tr) -> []
        # A move read since that turns out to have taken the piece, though
        # nobody saw anything taken: possible (the piece is lifted off
        # afterwards), but so is a king put on a bishop's square for a
        # second while the two are being swapped back. It waits.
        true -> Enum.reject(rewrites(tr), & &1.takes?)
      end

    # And a move that is legal only if a piece stands beside where it still
    # reads must itself stand a while: a queen resting on b6 on her way,
    # with her king in check, is not proof that the checking queen is on
    # another square.
    misread =
      if stable >= tr.opts.unseen_hold_ms,
        do: misread,
        else: Enum.reject(misread, &(&1[:ghost] != nil))

    cond do
      # An earlier move misread explains the board with fewer changes to
      # the game than new moves would: one move rewritten and one added
      # beats four made up.
      misread != [] and (found == [] or hd(misread).edits < length(hd(found).steps)) ->
        rewrite(tr, t, misread)

      found != [] ->
        accept(tr, t, hd(found).steps, mark(found, sure?))

      (result = unseen_search(tr, t, stable)) != nil ->
        result

      # Only when the alarm is next: a king on g8 with its rook still on h8
      # is half a castle for a second, and a king's walk if one insists.
      (anchor = stable >= tr.opts.transient_ms && anchor(tr)) not in [nil, false] ->
        {found, sure?, _hit?, tr} = paths(tr, anchor, stable, :guided, 1)

        case usable(tr, anchor, found) do
          [] ->
            unexplained(tr, stable, why)

          [best | _] = found ->
            correct(
              tr,
              t,
              anchor.count,
              marked(best.steps, mark(found, sure?), tr.deaf?),
              :revised
            )
        end

      true ->
        unexplained(tr, stable, why)
    end
  end

  # The board is the game as it stands, or one plain move on, with one
  # piece missing: a hand. (A knocked-over queen beside a bishop that went
  # to f4 reads exactly like "the queen was on f4 all along, and the bishop
  # took her there".)
  defp hand?(tr) do
    gone = for sq <- Position.diff(tr.phys, tr.raw), elem(tr.raw, sq) == nil, do: sq

    Enum.any?(gone, fn sq ->
      board = put_elem(tr.raw, sq, elem(tr.phys, sq))
      board == tr.phys or one_ply(tr.pos, tr.phys, board, tr.opts.promotion_default, []) != []
    end)
  end

  # The lines the box may take by itself, best first.
  #
  # Not one that needs more moves than the clock was pressed for (`fits?/2`):
  # that is the box making up moves, and it is the alarm instead - the
  # arbiter can still ask for it ("the board is right").
  #
  # And a line in which a piece goes out and straight back - a bishop to a3
  # and home again, to make two pawn moves fit where one was misread - is
  # the least likely thing a chess player does. It is never taken while
  # another line exists, and without a clock to say that the moves were
  # made, not at all.
  defp usable(tr, from, found),
    do: Enum.filter(found, &fits?(tr, from.count + length(&1.steps)))

  # The board changes again and the clock has not been pressed since the
  # last move was accepted: that press is not on its way, it was forgotten
  # or lost (a clock that misses one press shows the same side running
  # after the next, and so misses two). The game is that much ahead.
  defp unpressed(%{presses: presses, accepted_at: accepted} = tr)
       when is_integer(presses) and presses > 0 and accepted != nil do
    if tr.pressed_at == nil or tr.pressed_at < accepted,
      do: %{tr | debt: max(tr.debt, length(tr.plies) - presses)},
      else: tr
  end

  defp unpressed(tr), do: tr

  # Would a game of `count` plies be more than the clock was pressed for?
  # Allowed over the presses: the debt the game already has, and two - one
  # for the press of the move on the board, which may still be on its way
  # (a clock tells a second late), and one for a press forgotten or lost
  # with the move it belonged to.
  defp fits?(%{presses: presses}, _count) when presses in [nil, 0], do: true
  defp fits?(%{deaf?: true}, _count), do: true
  defp fits?(tr, count), do: count - tr.presses <= tr.debt + 2

  # One side moves a piece from A to B and, with its very next move, from B
  # back to A, taking nothing either way: two tempi spent on nothing.
  defp null_trip?(moves) do
    moves
    |> Enum.with_index()
    |> Enum.any?(fn {move, index} ->
      case Enum.at(moves, index + 2) do
        %{from: from, to: to} = back ->
          from == move.to and to == move.from and move[:capture] == nil and
            back[:capture] == nil

        nil ->
          false
      end
    end)
  end

  # --- a move misread ----------------------------------------------------------
  #
  # A pawn set down between d3 and d4 reads as d3. Nothing is wrong until
  # it takes on e5, which from d3 it cannot. Rather than invent moves to
  # get it to d4, ask whether one of the last few moves went to a
  # neighbouring square instead: the same piece, the square next to the one
  # read (one short or one long on its line, or beside it), the moves read
  # since replayed, and then nothing more, one move, or two.
  #
  # Each candidate is `%{keep, read, steps, new, edits}`: the game's first
  # `keep` plies stand, the move read as `read` is replaced by the first of
  # `steps`, the last `new` of which are new. Fewest edits first (one for
  # the rewrite, one a new move), then the most recent move, then by name.
  defp rewrites(%{opts: %{misread: false}}), do: []

  # A piece out of sight leaves the game too uncertain to second-guess.
  # A ghost does not: it is a piece whose square is known to within one,
  # and its own move may be asked about again (`shown_at/2`).
  defp rewrites(%{unseen: unseen} = tr) do
    if Enum.all?(unseen, &(&1[:ghost] != nil)), do: misreads(tr), else: []
  end

  # The board is back to what it was before the last move: a takeback, by
  # every rule above - unless the clock was pressed for that move. Then
  # the "move" was a piece set down between two squares being straightened
  # (the rook read on h6 that stood on h5 all along, nudged home), and
  # what came back is the player's next move, taking it to h6 for real.
  # The board cannot tell those apart; the press can. A move taken back
  # was never pressed for, and a move made always is.
  #
  # Only the one line `rewrites/1` already allows, in which the last ply
  # is the one that is not a move. Without a clock, or with one the box
  # did not hear, it stays a takeback. And a press is only this move's when
  # it came after the move was read and makes the presses as many as the
  # moves: the debt (`fits?/2`) forgives the clock, it does not count for it.
  defp straightened(tr, 1) do
    count = length(tr.plies)
    last = List.last(tr.plies)

    pressed? =
      not tr.deaf? and is_integer(tr.presses) and tr.presses >= count and
        tr.pressed_at != nil and tr.pressed_at >= last.at

    if pressed?,
      do: Enum.filter(rewrites(tr), &(&1.straightened == count - 1)),
      else: []
  end

  defp straightened(_tr, _k), do: []

  defp misreads(tr) do
    count = length(tr.plies)

    for back <- 1..min(@misread_back, count)//1,
        keep = count - back,
        ply = Enum.at(tr.plies, keep),
        :arbiter not in ply.flags and :imported not in ply.flags,
        before = Enum.at(tr.history, back - 1),
        before.unseen == [],
        later = Enum.drop(tr.plies, keep + 1),
        shown = shown_at(tr, ply),
        move <- nearby(before.pos, ply, shown),
        {kept, dropped} = straight(ply, move, later, shown),
        line <- rewritten(tr, before, move, kept, tr.raw, ply, shown, dropped != nil),
        fits?(tr, keep + length(line.steps)) do
      Map.merge(line, %{
        keep: keep,
        # A move rewritten twice was still read only once.
        read: ply[:read] || ply.san,
        edits: 1 + line.new,
        back: back,
        straightened: dropped && keep + 1 + dropped
      })
    end
    |> Enum.sort_by(&{&1.edits, &1.back, sans_of(Enum.at(tr.history, &1.back - 1).pos, &1.steps)})
  end

  # The piece `ply` put on its square.
  defp moved(pos, ply) do
    {colour, kind} = elem(pos.board, ply.from)
    {colour, ply.promo || kind}
  end

  # The moves read after a misread one, without the "move" that was only
  # somebody straightening the piece: from the square it was read on to the
  # square it had been on all along.
  #
  # Returns `{moves, index}`: the moves kept, and where among `later` the
  # straightening was (`nil` when there was none).
  defp straight(ply, move, later, shown \\ nil) do
    shown = shown || ply.to

    case Enum.split_while(later, &(not (&1.from == shown and &1.to == move.to))) do
      {before, [_straightened | rest]} -> {before ++ rest, length(before)}
      {all, []} -> {all, nil}
    end
  end

  # Where the piece of `ply` was last read: its own square, unless it is a
  # ghost - a move already rewritten once, its piece carried as standing
  # beside the square it reads on. Then the reading is the evidence, and
  # the square it was taken to stand on only the first guess. A ghost that
  # is straightened onto a third square says the guess was the wrong
  # neighbour, and the move is asked about again around the reading.
  defp shown_at(tr, ply) do
    Enum.find_value(tr.unseen, ply.to, fn entry ->
      if entry[:ghost] != nil and entry.square == ply.to and :rewritten in ply.flags,
        do: entry.ghost
    end)
  end

  # The other legal moves of the piece that made `ply`, to a square next to
  # the one it was read on.
  defp nearby(pos, ply, shown \\ nil) do
    shown = shown || ply.to

    # Not a castle: nobody sets a king down between g1 and f1, and a king
    # and rook swapped back by mistake read just like it.
    castle? = String.starts_with?(ply.san, "O-O")

    for move <- if(castle?, do: [], else: Chess.legal_moves(pos)),
        move.from == ply.from and move.to not in [ply.to, shown] and move.promo == ply.promo,
        move.kind not in [:castle_k, :castle_q],
        abs(rem(move.to, 8) - rem(shown, 8)) <= 1 and abs(div(move.to, 8) - div(shown, 8)) <= 1,
        do: move
  end

  # `move` instead of the move that was read, the moves `later` read after
  # it played again where they still can be, and what it then takes to
  # reach `target`. No line at all when a later move no longer fits.
  #
  # Two ways the board can agree with that. The piece is no longer where
  # it was read - it moved on, was taken, was straightened - and the board
  # is simply the rewritten game's. Or it still reads there (`ghost`): the
  # board is the rewritten game's but for that one piece, which is then
  # carried as "read on d3, standing on d4" until it is read where it
  # stands, moves, or is taken.
  defp rewritten(tr, before, move, later, target, ply, shown \\ nil, straightened? \\ false) do
    shown = shown || ply.to
    [{board, _} | _] = Search.outcomes(before.phys, move, before.pos.turn, nil)
    pos = Chess.apply_move(before.pos, move)
    specs = Enum.map(later, &{&1.from, &1.to, &1.promo, &1.flags})

    case replay_specs(pos, board, specs, []) do
      {:ok, steps, phys} ->
        pos =
          Enum.reduce(steps, pos, fn {played, _flags}, pos -> Chess.apply_move(pos, played) end)

        # Nothing more, or one move: two would be rope enough to explain
        # any hand over the board.
        takes? =
          steps
          |> Enum.zip(later)
          |> Enum.any?(fn {{played, _flags}, ply} ->
            played.capture != nil and not String.contains?(ply.san, "x")
          end)

        piece = moved(before.pos, ply)

        # Not when it was seen straightened since: a piece read on its own
        # square is not crooked any more, and is back on the square beside
        # by a move.
        crooked? =
          not straightened? and elem(target, shown) == piece and elem(target, move.to) == nil and
            elem(phys, move.to) == piece and elem(phys, shown) == nil

        if crooked? do
          entry = %{square: move.to, piece: piece, ghost: shown}
          read = phys |> put_elem(move.to, nil) |> put_elem(shown, piece)

          # A new move there must be, or nothing was wrong with the reading.
          for [_ | _] = new <- complete(tr, pos, read, target, 1, [entry]),
              do: %{
                steps: [{move, []}] ++ steps ++ new,
                new: length(new),
                takes?: takes?,
                ghost: entry
              }
        else
          for new <- complete(tr, pos, phys, target, 1),
              do: %{steps: [{move, []}] ++ steps ++ new, new: length(new), takes?: takes?}
        end

      :error ->
        []
    end
  end

  # The ways from `pos` (the sensors reading `phys`) to `target`, as lists
  # of steps: none needed, one move, or up to `depth` found by the search.
  defp complete(tr, pos, phys, target, depth, unseen \\ [])
  defp complete(_tr, _pos, phys, target, _depth, _unseen) when phys == target, do: [[]]

  defp complete(tr, pos, phys, target, depth, unseen) do
    o = tr.opts

    case one_ply(pos, phys, target, o.promotion_default, unseen) do
      [] when depth < 2 ->
        []

      [] ->
        case Search.find(pos, phys, target,
               min_depth: 2,
               max_depth: depth,
               max_nodes: o.max_nodes,
               max_ms: o.max_ms,
               promotion_default: o.promotion_default
             ) do
          {:ok, found, _nodes} -> Enum.map(found, & &1.steps)
          {:budget, _nodes} -> []
        end

      singles ->
        Enum.map(singles, &[&1])
    end
  end

  # Takes the best of `lines` (as `rewrites/1` gives them). Orange when it
  # is the only one of its cost and the game then has as many moves as the
  # clock was pressed for (one press may be on its way); red otherwise.
  defp rewrite(tr, t, [best | rest] = lines) do
    alone? = not Enum.any?(rest, &(&1.edits == best.edits))
    count = best.keep + length(best.steps)

    # Not across a hole in contact: nothing found there is vouched for.
    told? =
      not tr.deaf? and tr.presses not in [nil, 0] and (count - tr.presses - tr.debt) in 0..1

    mark =
      cond do
        alone? and told? -> [:recovered]
        length(lines) == 1 -> [:guessed, :alone]
        true -> [:guessed]
      end

    last = length(best.steps) - 1

    steps =
      best.steps
      |> Enum.with_index()
      |> Enum.map(fn {{move, flags}, index} ->
        cond do
          index == 0 -> {move, Enum.uniq(flags ++ [:rewritten | mark])}
          index > last - best.new -> {move, Enum.uniq(flags ++ mark)}
          true -> {move, flags}
        end
      end)

    note = %{read: best.read, span: length(steps)}
    was = tr
    {tr, events} = correct(tr, t, best.keep, steps, :misread)
    tr = noted(tr, best.keep, note)
    # Kept until the game goes on: see `unrewrite/2`.
    tr = %{tr | as_read: %{tracker: %{was | as_read: nil, memo: nil}, keep: best.keep}}
    # Still read on the square beside its own: carried like a piece not seen.
    tr = if best[:ghost], do: %{tr | unseen: [best.ghost]}, else: tr

    events =
      Enum.map(events, fn
        {:correction, keep, [first | others], :misread} ->
          {:correction, keep, [Map.merge(first, note) | others], :misread}

        other ->
          other
      end)

    {tr, events}
  end

  # What a rewritten ply was read as, and how many plies its rewrite covers.
  defp noted(tr, index, %{read: read} = note) do
    plies = List.update_at(tr.plies, index, &Map.merge(&1, %{read: read, span: note[:span] || 1}))
    %{tr | plies: plies}
  end

  # The paths take a piece - and the same board with one missing piece put
  # back is explained by fewer moves (or by none). Then it is that, and a
  # piece in a hand: a queen lifted off d3 beside a rook that went to e3
  # unseen reads exactly like "the rook went to e3, the queen came to e3
  # by way of e4, and was taken there". Hands are over the board a hundred
  # times a game and queens are lost that way never, so such paths are
  # believed only of a board that has stood for `deep_settle_ms`.
  defp in_hand?(_tr, []), do: false

  defp in_hand?(tr, [one | _]) do
    from = here(tr)
    gone = for sq <- Position.diff(from.phys, tr.raw), elem(tr.raw, sq) == nil, do: sq
    takes? = Position.count(tr.raw) < Position.count(from.phys)

    takes? and
      Enum.any?(gone, fn sq ->
        board = put_elem(tr.raw, sq, elem(from.phys, sq))

        board == from.phys or
          match?(
            {:ok, [_ | _], _nodes},
            Search.find(from.pos, from.phys, board,
              min_depth: 1,
              max_depth: length(one.steps) - 1,
              max_nodes: tr.opts.max_nodes,
              max_ms: tr.opts.max_ms,
              promotion_default: tr.opts.promotion_default,
              unseen: Enum.map(from.unseen, & &1.square),
              touch: touched(tr, from)
            )
          )
      end)
  end

  # One path, and a search of every move (not only the ones that were
  # seen) agrees it is the only one: orange. Anything less sure: red.
  defp mark([_one], true), do: [:recovered]
  # `:alone`: a guess because the one line found cannot be vouched for, not
  # because there were several.
  defp mark([_one], false), do: [:guessed, :alone]
  defp mark(_found, _sure?), do: [:guessed]

  defp marked(steps, flags, gap?) do
    flags = if gap?, do: flags ++ [:long_gap], else: flags
    Enum.map(steps, fn {move, own} -> {move, Enum.uniq(own ++ flags)} end)
  end

  defp here(tr),
    do: %{pos: tr.pos, phys: tr.phys, unseen: tr.unseen, count: length(tr.plies)}

  # The position before the last run of reconstructed moves, when that run
  # is recent enough to search across again and the arbiter has not put
  # his name to it.
  defp anchor(tr) do
    marked? = &(:recovered in &1.flags or :guessed in &1.flags)
    recent = tr.plies |> Enum.reverse() |> Enum.take(tr.opts.search_depth - 1)
    {after_run, from_run} = Enum.split_while(recent, &(not marked?.(&1)))
    run = Enum.take_while(from_run, marked?)
    back = length(after_run) + length(run)

    if run != [] and not Enum.any?(run, &(:arbiter in &1.flags)) and
         back <= length(tr.history) do
      before = Enum.at(tr.history, back - 1)
      %{pos: before.pos, phys: before.phys, unseen: before.unseen, count: length(tr.plies) - back}
    end
  end

  # The paths from `from` to the board, best first: `{found, sure?,
  # budget_hit?, tr}`.
  #
  # Three searches, and which of them depends on what the box knows:
  #
  # - guided: moves both of whose squares were read differently;
  # - by evidence: moves by pieces that were seen to leave their squares
  #   (`Search`, "Evidence"). The widest search of a board the box was
  #   connected to: a piece that stood on its square in every reading did
  #   not move, however much a move of it would help. `sure?` when what was
  #   found is all that this search finds: one path is then the one path
  #   the readings allow;
  # - blind, every legal move: only across a hole in what the box knows
  #   (`deaf?`: the driver said the board was gone). Nothing found across
  #   a hole is `sure?`.
  defp paths(tr, from, stable, scope, min) do
    o = tr.opts
    wide = if tr.deaf?, do: :blind, else: :evidence

    # Before the first move a board is pieces being set up, and a board
    # half set up is not to be read as an opening: two plies, as a board
    # that was plugged in late has always been caught up, and no more -
    # until the clock says a game is on.
    far =
      cond do
        tr.plies != [] or tr.begun? -> o.search_depth
        o.late_start or tr.ready? -> min(o.search_depth, 2)
        true -> 0
      end

    reach = min(far, if(stable >= o.deep_settle_ms, do: o.blind_depth, else: 2))
    {guided, tr} = search(tr, from, min, far, :guided)

    {found, sure?, hit?, tr} =
      case guided do
        {:ok, [one | _] = found} ->
          depth = length(one.steps)

          if depth <= o.blind_depth do
            case search(tr, from, min, depth, wide) do
              {{:ok, more}, tr} -> {found ++ more, true, false, tr}
              {:budget, tr} -> {found, false, true, tr}
            end
          else
            {found, false, false, tr}
          end

        guided when scope == :guided ->
          {[], false, guided == :budget, tr}

        guided ->
          case search(tr, from, min, reach, wide) do
            {{:ok, found}, tr} -> {found, true, guided == :budget, tr}
            {:budget, tr} -> {[], false, true, tr}
          end
      end

    {found, tr} = pressed_for(tr, from, distinct(found))
    {sure?, tr} = alone?(tr, from, found, sure? and not tr.deaf?, wide)
    {rank(tr, from, allowed(tr, from, found)), sure?, hit?, tr}
  end

  # One line found, and nothing else the search finds: but the search does
  # not return a piece going out and straight back, and games have those -
  # a king stepping out of a check and back into the corner, move after
  # move. Such a line is not taken; that it exists means the one that was
  # found is not the only way, and is a guess.
  defp alone?(tr, from, [one], true, wide) do
    depth = length(one.steps)
    with_returns = if wide == :blind, do: :blind_with_returns, else: :evidence_with_returns

    case search(tr, from, min(depth, 2), depth, with_returns) do
      {{:ok, all}, tr} -> {length(distinct(all)) <= 1, tr}
      {:budget, tr} -> {false, tr}
    end
  end

  defp alone?(tr, _from, _found, sure?, _wide), do: {sure?, tr}

  # Not the moves the arbiter has just taken back from this position
  # (`undo/3`). Those moves and another on top are a different matter: the
  # game has gone on over them, and the board keeps up.
  defp allowed(%{rejected: %{count: count, sans: sans}}, %{count: count} = from, found),
    do: Enum.reject(found, &(sans_of(from.pos, &1.steps) == sans))

  defp allowed(_tr, _from, found), do: found

  # The clock has been pressed more often than these paths have moves: they
  # are too short to be the whole story. Longer ones are looked for, and
  # go first. (A press tells late, never early: fewer presses than moves
  # proves nothing, more does.)
  defp pressed_for(tr, _from, [] = found), do: {found, tr}
  defp pressed_for(%{presses: nil} = tr, _from, found), do: {found, tr}
  defp pressed_for(%{opts: %{press_count: false}} = tr, _from, found), do: {found, tr}

  defp pressed_for(tr, from, [one | _] = found) do
    have = length(one.steps)
    # One press is allowed for: the lever that started the clock is a
    # press too on some clocks, and "Move missing?" waits for two as well.
    want = tr.presses - 1 - from.count

    if want > have and have < tr.opts.search_depth do
      o = tr.opts
      {guided, tr} = search(tr, from, have + 1, min(want + 1, o.search_depth), :guided)
      # The presses say moves were made; the readings still say by which pieces.
      wide = if tr.deaf?, do: :blind, else: :evidence
      {more, tr} = search(tr, from, have + 1, min(want + 1, o.blind_depth), wide)
      longer = for {:ok, found} <- [guided, more], one <- found, do: one
      {distinct(longer) ++ found, tr}
    else
      {found, tr}
    end
  end

  # Every square that has read differently from `from` at any moment since.
  defp touched(tr, from) do
    seen = for {count, board} <- tr.trail, count >= from.count, do: board

    [tr.raw | seen]
    |> Enum.flat_map(&Position.diff(from.phys, &1))
    |> Enum.concat(Enum.map(from.unseen, & &1.square))
    |> Enum.uniq()
  end

  # Which of several paths to take. In this order: the longer ones the
  # clock asked for stay ahead of the shorter (the sort is stable and they
  # came first); then the one whose moves the readings show in that order
  # (`out_of_order/3`); then the one that assumes least about a promotion,
  # and a queen before any other piece nobody saw; then by the moves' names, so that the same board always gives the same
  # game.
  defp rank(_tr, _from, [] = found), do: found
  defp rank(_tr, _from, [_one] = found), do: found

  defp rank(tr, from, found) do
    boards =
      Enum.reverse([tr.raw | for({count, board} <- tr.trail, count >= from.count, do: board)])

    longest = found |> Enum.map(&length(&1.steps)) |> Enum.max()

    Enum.sort_by(found, fn one ->
      {longest - length(one.steps), out_of_order(from, one.steps, boards),
       Enum.count(one.steps, fn {_move, flags} -> :assumed in flags end),
       Enum.count(one.steps, fn {move, _flags} -> move.promo not in [nil, :q] end),
       sans_of(from.pos, one.steps)}
    end)
  end

  # How many of the moves the readings show in another order than the path
  # has them. Each move is first shown by some reading - both its squares
  # reading as the move leaves them - and a move first shown before the
  # move that the path plays ahead of it is out of order. A game played
  # move by move in front of the board scores 0 for the order it was
  # played in and more for the same moves in another; moves nobody read
  # one by one are all first shown by the same reading, and score 0
  # whatever their order.
  defp out_of_order(from, steps, boards) do
    indexed = Enum.with_index(boards)

    {_phys, _pos, _last, wrong} =
      Enum.reduce(steps, {from.phys, from.pos, 0, 0}, fn {move, flags},
                                                         {phys, pos, last, wrong} ->
        {board, _} =
          phys
          |> Search.outcomes(move, pos.turn, tr_default(flags))
          |> Enum.find(fn {_board, f} -> :assumed in f == :assumed in flags end)

        shown =
          Enum.find_value(indexed, length(boards), fn {seen, index} ->
            if elem(seen, move.from) == elem(board, move.from) and
                 elem(seen, move.to) == elem(board, move.to),
               do: index
          end)

        next = Chess.apply_move(pos, move)
        if shown < last, do: {board, next, last, wrong + 1}, else: {board, next, shown, wrong}
      end)

    wrong
  end

  # A step flagged `:assumed` was found with the promotion default in
  # force; any other step has one outcome whatever the default.
  defp tr_default(flags), do: if(:assumed in flags, do: :q, else: nil)

  # Nothing explains the board as it is. Two moves do, if the absent piece
  # is still on its square: the move that would have said so went by
  # before it had stood long enough to be believed.
  defp unseen_search(tr, t, stable) do
    with %{} = supposed <- supposing(tr),
         true <- stable >= tr.opts.unseen_hold_ms,
         {{:ok, found}, supposed} <- search(supposed, here(supposed), 2, 2, :evidence),
         [one] <- distinct(found) do
      # A supposition on top of a search: red, not orange.
      supposed |> accept(t, one.steps, [:guessed]) |> since(tr)
    else
      _no -> nil
    end
  end

  defp unexplained(tr, stable, why) do
    o = tr.opts
    gesture = if o.result_gesture and tr.plies != [], do: gesture(tr)
    # What the board does show, when it shows one thing and that thing has
    # a name. It must stand like any other claim about a piece.
    named = if tr.plies != [] and gesture == nil and stable >= o.unseen_hold_ms, do: named(tr)

    cond do
      # Before the first move a board that is not the starting position is
      # pieces being set up - unless the clock has been pressed since.
      tr.plies == [] and not (tr.begun? and stable >= o.transient_ms) ->
        set_status(tr, :waiting_start, :not_start)

      tr.plies == [] ->
        set_status(tr, :out_of_sync, why)

      gesture != nil ->
        {tr, events} = set_status(tr, :settling, {:gesture, gesture})

        if tr.gesture == gesture,
          do: {tr, events},
          else: {%{tr | gesture: gesture}, events ++ [{:result_suggestion, gesture, :gesture}]}

      named != nil ->
        set_status(tr, :out_of_sync, named)

      Position.in_hand?(tr.phys, tr.raw) ->
        if stable >= o.lifted_ms,
          do: set_status(tr, :out_of_sync, :piece_missing),
          else: set_status(tr, :settling, :in_hand)

      stable >= o.transient_ms ->
        set_status(tr, :out_of_sync, why)

      true ->
        set_status(tr, :settling, :unexplained)
    end
  end

  # The two things a board says plainly and a search must not explain away:
  #
  # - `{:out_of_turn, %{colour, san, piece, from, to}}`: the board is the
  #   game plus one legal move - by the side that is not to move. Somebody
  #   moved twice, or moved before the other side's move was made;
  # - `{:illegal, %{piece, from, to, why}}`: one piece went from one square
  #   to another, and that is not a move it has. `why` is `:blocked`
  #   (something stands in the way), `:shape` (that piece does not move like
  #   that), `:own_piece` (onto a piece of its own side) or `:check` (it
  #   leaves its own king in check).
  #
  # Neither adds anything to the game. Both are gone the moment the piece
  # is back, as any unexplained board is.
  defp named(tr) do
    them = if tr.pos.turn == :w, do: :b, else: :w
    theirs = %{tr.pos | turn: them, ep: nil}

    case one_ply(theirs, tr.phys, tr.raw, tr.opts.promotion_default, tr.unseen) do
      [{move, _flags} | _] ->
        {:out_of_turn,
         %{
           colour: them,
           san: Chess.san(theirs, move),
           piece: move.piece,
           from: move.from,
           to: move.to
         }}

      [] ->
        illegal(tr)
    end
  end

  defp illegal(tr) do
    with [a, b] <- Position.diff(tr.phys, tr.raw),
         {from, to} <- carried(tr.phys, tr.raw, a, b) do
      {colour, kind} = piece = elem(tr.phys, from)
      as_mover = %{tr.pos | turn: colour}

      why =
        cond do
          match?({^colour, _}, elem(tr.phys, to)) ->
            :own_piece

          Enum.any?(Chess.moves_from(as_mover, [from]), &(&1.to == to)) ->
            :check

          Enum.any?(Chess.moves_from(alone(as_mover, from, piece), [from]), &(&1.to == to)) ->
            :blocked

          # A pawn that takes where there is nothing to take, or goes two
          # from the wrong rank, moves like a pawn; anything else does not
          # move like the piece it is.
          true ->
            :shape
        end

      {:illegal, %{piece: {colour, kind}, from: from, to: to, why: why}}
    else
      _other -> nil
    end
  end

  # One square emptied and its piece standing on the other.
  defp carried(phys, raw, a, b) do
    cond do
      elem(raw, a) == nil and elem(phys, a) != nil and elem(raw, b) == elem(phys, a) -> {a, b}
      elem(raw, b) == nil and elem(phys, b) != nil and elem(raw, a) == elem(phys, b) -> {b, a}
      true -> nil
    end
  end

  # The position with nothing on the board but that piece: where it could
  # go if nothing were in its way.
  defp alone(pos, square, piece) do
    board = nil |> Tuple.duplicate(64) |> put_elem(square, piece)
    %{pos | board: board, castling: [], ep: nil}
  end

  # Two paths that are the same moves are one path: a promotion read as a
  # queen and the same promotion read as a pawn left standing, once the
  # piece has been taken, are the same game.
  defp distinct(found) do
    found
    |> Enum.sort_by(fn f -> Enum.count(f.steps, fn {_move, flags} -> :assumed in flags end) end)
    |> Enum.uniq_by(fn f -> {Enum.map(f.steps, &elem(&1, 0)), f.phys} end)
  end

  # --- the pieces of the decision ----------------------------------------------

  defp one_ply(tr),
    do: one_ply(tr.pos, tr.phys, tr.raw, tr.opts.promotion_default, tr.unseen)

  # `unseen`: a piece the board does not show can still move, and its
  # square will not be among those that changed.
  defp one_ply(pos, phys, raw, default, unseen) do
    squares = Position.diff(phys, raw)

    if length(squares) > 4 do
      []
    else
      from = squares ++ for(%{square: sq} <- unseen, elem(phys, sq) == nil, do: sq)

      for move <- Chess.moves_from(pos, Enum.uniq(from)),
          {board, flags} <- Search.outcomes(phys, move, pos.turn, default),
          shown(board, move, unseen) == raw,
          Chess.legal?(pos, move),
          do: {move, flags}
    end
  end

  # A piece that is read on the square beside its own (`ghost`) is read
  # there no longer once it moves, or is taken where it really stands.
  defp shown(board, move, unseen) do
    Enum.reduce(unseen, board, fn
      %{square: square, ghost: ghost, piece: piece}, board
      when move.from == square or move.to == square ->
        if elem(board, ghost) == piece, do: put_elem(board, ghost, nil), else: board

      _entry, board ->
        board
    end)
  end

  # A legal move stood on the board, and in the very next reading somebody
  # has picked up another piece: the next hand is on the board, so the move
  # is made. In fast play this is the only notice a move gets - it never
  # stands still for `settle_ms`, and the clock says so a second late.
  #
  # Believed at once, but only when it can be nothing else: the reading
  # before this one was that move and nothing but that move (so pieces
  # that were already off the board do not count as a hand); the piece it
  # moved still stands where it landed (a piece lifted from its landing
  # square is a rook on its way further, a move being taken back, or the
  # recapture - all of which read the same and are waited for); the
  # mover's king is not the piece in the air (castling, rook first); and
  # nothing was assumed about a promotion.
  defp move_under_hand(%{before: nil}), do: nil

  defp move_under_hand(%{before: before} = tr) do
    us = tr.pos.turn

    with true <- Position.in_hand?(before, tr.raw),
         [{move, []}] <-
           one_ply(tr.pos, tr.phys, before, tr.opts.promotion_default, tr.unseen),
         true <- elem(tr.raw, move.to) != nil,
         true <- Enum.all?(Position.diff(before, tr.raw), &(elem(before, &1) != {us, :k})),
         false <- half_castle?(tr.pos, move) do
      {move, before}
    else
      _no -> nil
    end
  end

  defp accept_under_hand(tr, t, {move, board}) do
    {tr, plies} = push(tr, [{move, []}], [], t, board)
    tr = %{tr | memo: nil, rejected: nil}
    {tr, [{:moves, plies}] ++ suggestion(tr)} |> and_then(&evaluate(&1, t, false))
  end

  # How long a one-move board must stand before it is believed.
  defp hold(tr, move, flags) do
    o = tr.opts

    cond do
      :assumed in flags -> o.promotion_hold_ms
      half_castle?(tr.pos, move) -> o.castle_hold_ms
      true -> o.settle_ms
    end
  end

  # A rook going from its corner to the square it lands on when castling,
  # while castling that side is legal: the king may be about to follow.
  defp half_castle?(pos, %{piece: :r, from: from, to: to}) do
    Enum.any?(Chess.legal_moves(pos), fn
      %{kind: :castle_k, to: king} -> from == king + 1 and to == king - 1
      %{kind: :castle_q, to: king} -> from == king - 2 and to == king + 1
      _other -> false
    end)
  end

  defp half_castle?(_pos, _move), do: false

  defp takeback(%{opts: %{takeback: false}}), do: nil

  defp takeback(tr) do
    tr.history
    |> Enum.take(tr.opts.takeback_plies)
    # Not back to where a piece was out of sight that has been seen since:
    # a takeback puts pieces back on squares, it does not make one vanish.
    |> Enum.find_index(&(&1.phys == tr.raw and &1.unseen -- tr.unseen == []))
    |> case do
      nil -> nil
      index -> index + 1
    end
  end

  # The board reads as it did two plies ago. Taken back - or played back: a
  # queen that checked from f1 and f2 in turn does this for a living. When
  # legal moves explain the board, they are believed before a takeback of
  # more than one ply is; `docs/design.md` says what that costs.
  defp replayable?(_tr, 1), do: false

  defp replayable?(tr, k) do
    match?(
      {:ok, [_ | _], _nodes},
      Search.find(tr.pos, tr.phys, tr.raw,
        min_depth: 2,
        max_depth: k,
        max_nodes: tr.opts.max_nodes,
        promotion_default: tr.opts.promotion_default
      )
    )
  end

  defp revision(%{history: []}), do: nil

  defp revision(%{history: [before | _]} = tr) do
    case one_ply(before.pos, before.phys, tr.raw, tr.opts.promotion_default, before.unseen) do
      [step] -> step
      _other -> nil
    end
  end

  # A pawn was left on its last rank and counted as the default piece; now a
  # different piece stands there. The promotion is rewritten and the moves
  # after it replayed - if they still fit.
  defp promotion_fix(tr) do
    with [square] <- Position.diff(tr.phys, tr.raw),
         {colour, :p} <- elem(tr.phys, square),
         {^colour, kind} when kind in [:q, :r, :b, :n] <- elem(tr.raw, square),
         index when index != nil <-
           Enum.find_index(Enum.reverse(tr.plies), &(:assumed in &1.flags)) do
      number = length(tr.plies) - index
      before = Enum.at(tr.history, index)
      ply = Enum.at(tr.plies, number - 1)

      specs =
        [{ply.from, ply.to, kind, ply.flags -- [:assumed]}] ++
          (tr.plies |> Enum.drop(number) |> Enum.map(&{&1.from, &1.to, &1.promo, &1.flags}))

      case replay_specs(before.pos, before.phys, specs, []) do
        {:ok, steps, phys} when phys == tr.raw -> {number - 1, steps}
        _other -> nil
      end
    else
      _no -> nil
    end
  end

  defp replay_specs(_pos, phys, [], acc), do: {:ok, Enum.reverse(acc), phys}

  defp replay_specs(pos, phys, [{from, to, promo, flags} | rest], acc) do
    case Enum.find(
           Chess.legal_moves(pos),
           &(&1.from == from and &1.to == to and &1.promo == promo)
         ) do
      nil ->
        :error

      move ->
        [{board, _} | _] = Search.outcomes(phys, move, pos.turn, nil)
        replay_specs(Chess.apply_move(pos, move), board, rest, [{move, flags} | acc])
    end
  end

  # The kings set on the four centre squares is how players tell the board
  # the result. ASSUMED from DGT LiveChess usage, not from a published
  # protocol: both kings on light squares (e4, d5) = White won, both on dark
  # squares (d4, e5) = Black won, one on each = draw. It is only ever a
  # suggestion to the arbiter.
  @light [36, 27]
  @dark [35, 28]
  defp gesture(tr) do
    squares = Tuple.to_list(tr.raw)
    white = Enum.find_index(squares, &(&1 == {:w, :k}))
    black = Enum.find_index(squares, &(&1 == {:b, :k}))

    cond do
      white == nil or black == nil -> nil
      white in @light and black in @light -> "1-0"
      white in @dark and black in @dark -> "0-1"
      white in (@light ++ @dark) and black in (@light ++ @dark) -> "1/2-1/2"
      true -> nil
    end
  end

  # One search, remembered for as long as the board and the game stay as
  # they are: the same question is asked at every tick.
  defp search(tr, from, min, max, mode) do
    stamp = {tr.raw, length(tr.plies), tr.unseen}
    key = {from.count, min, max, mode}

    limits =
      case mode do
        :guided -> [touch: touched(tr, from)]
        :evidence -> [evidence: touched(tr, from)]
        :evidence_with_returns -> [evidence: touched(tr, from), out_and_back: true]
        :blind -> []
        :blind_with_returns -> [out_and_back: true]
      end

    known =
      case tr.memo do
        {^stamp, known} -> known
        _stale -> %{}
      end

    case known do
      %{^key => result} ->
        {result, %{tr | memo: {stamp, known}}}

      _new when min > max ->
        {{:ok, []}, tr}

      _new ->
        started = System.monotonic_time(:microsecond)

        found =
          Search.find(
            from.pos,
            from.phys,
            tr.raw,
            [
              min_depth: min,
              max_depth: max,
              max_nodes: tr.opts.max_nodes,
              max_ms: tr.opts.max_ms,
              promotion_default: tr.opts.promotion_default,
              unseen: Enum.map(from.unseen, & &1.square)
            ] ++ limits
          )

        us = System.monotonic_time(:microsecond) - started

        {result, nodes, hit} =
          case found do
            {:ok, list, nodes} -> {{:ok, list}, nodes, 0}
            {:budget, nodes} -> {:budget, nodes, 1}
          end

        stats = %{
          searches: tr.stats.searches + 1,
          max_nodes: max(tr.stats.max_nodes, nodes),
          max_us: max(tr.stats.max_us, us),
          budget_hits: tr.stats.budget_hits + hit
        }

        {result, %{tr | memo: {stamp, Map.put(known, key, result)}, stats: stats}}
    end
  end

  # --- changing the game -------------------------------------------------------

  defp accept(tr, t, steps, extra) do
    # `:long_gap`: found across a hole in what the box knows - the board
    # was gone - and not merely several moves at once.
    extra = if tr.deaf? and extra != [], do: Enum.uniq(extra ++ [:long_gap]), else: extra
    {tr, plies} = push(tr, steps, extra, t, tr.raw)

    tr = settle_debt(%{tr | memo: nil, gesture: nil, rejected: nil, as_read: nil})
    {tr, status} = set_status(tr, :live, nil)
    {tr, [{:moves, plies}] ++ status ++ suggestion(tr)}
  end

  # Moves accepted after the board was not heard: what they put the game
  # ahead of the clock by is not the box making up moves.
  defp settle_debt(%{deaf?: true, presses: presses} = tr) when is_integer(presses),
    do: %{tr | deaf?: false, accepted_at: tr.at, debt: max(tr.debt, length(tr.plies) - presses)}

  # And any moves accepted put the game where it is: ahead of the clock by
  # this much, less the press of the last of them if it is still to come.
  # (Measured here as well as when a press arrives, because a move
  # accepted ON its press is never ahead of it at that moment.)
  defp settle_debt(%{presses: presses} = tr) when is_integer(presses) and presses > 0 do
    pending = if tr.pressed_at != nil and tr.pressed_at >= tr.raw_since, do: 0, else: 1

    %{
      tr
      | deaf?: false,
        accepted_at: tr.at,
        debt: max(tr.debt, length(tr.plies) - presses - pending)
    }
  end

  defp settle_debt(tr), do: %{tr | deaf?: false, accepted_at: tr.at}

  defp correct(tr, t, keep, steps, reason) do
    back = length(tr.plies) - keep

    tr =
      if back > 0 do
        before = Enum.at(tr.history, back - 1)

        %{
          tr
          | plies: Enum.take(tr.plies, keep),
            history: Enum.drop(tr.history, back),
            # What was read while the game stood further on was read of
            # another game: the moves just taken off it.
            trail: Enum.reject(tr.trail, fn {count, _board} -> count > keep end),
            pos: before.pos,
            phys: before.phys,
            unseen: before.unseen
        }
      else
        tr
      end

    final = if reason in [:takeback, :revised, :promotion, :misread], do: tr.raw
    {tr, plies} = push(tr, steps, [], t, final)
    tr = %{tr | memo: nil, rejected: nil, as_read: nil}

    {tr, status} =
      if tr.plies == [],
        do: set_status(tr, :waiting_start, :ready),
        else: set_status(tr, :live, nil)

    {tr, [{:correction, keep, plies, reason}] ++ status ++ suggestion(tr)}
  end

  # Plays `steps` onto the certain position. `final` is the board the sensors
  # read once they are all played, when that is known.
  defp push(tr, steps, extra, t, final) do
    {plies, tr} =
      Enum.map_reduce(steps, tr, fn {move, flags}, tr ->
        san = Chess.san(tr.pos, move)
        next = Chess.apply_move(tr.pos, move)

        [{board, _} | _] =
          tr.phys
          |> Search.outcomes(move, tr.pos.turn, tr.opts.promotion_default)
          |> Enum.sort_by(fn {_board, f} ->
            if :assumed in f == :assumed in flags, do: 0, else: 1
          end)

        board = shown(board, move, tr.unseen)

        # Still unseen after this move: not the piece that moved, not
        # taken where it stood.
        unseen =
          Enum.filter(tr.unseen, fn %{square: sq, piece: piece} ->
            elem(next.board, sq) == piece and elem(board, sq) == nil
          end)

        ply = %{
          san: san,
          from: move.from,
          to: move.to,
          promo: move.promo,
          flags: Enum.uniq(flags ++ extra ++ if(unseen == [], do: [], else: [:unseen])),
          at: t,
          fen: Chess.to_fen(next)
        }

        {ply,
         %{
           tr
           | history: [%{pos: tr.pos, phys: tr.phys, unseen: tr.unseen} | tr.history],
             pos: next,
             phys: board,
             unseen: unseen,
             plies: tr.plies ++ [ply]
         }}
      end)

    tr = if final && steps != [], do: %{tr | phys: final}, else: tr
    {tr, plies}
  end

  # Says so when the pieces taken to be unseen are not the ones they were:
  # `{:unseen, [%{square, piece}]}`, the whole list as it is now.
  defp noting({%__MODULE__{unseen: now} = tr, events}, %__MODULE__{unseen: was}) do
    if Enum.sort(now) == Enum.sort(was),
      do: {tr, events},
      else: {tr, events ++ [{:unseen, now}]}
  end

  defp suggestion(%{plies: []}), do: []

  defp suggestion(tr) do
    case Chess.state(tr.pos) do
      :checkmate ->
        [{:result_suggestion, if(tr.pos.turn == :w, do: "0-1", else: "1-0"), :checkmate}]

      :stalemate ->
        [{:result_suggestion, "1/2-1/2", :stalemate}]

      :insufficient_material ->
        [{:result_suggestion, "1/2-1/2", :insufficient_material}]

      :playing ->
        []
    end
  end

  defp set_status(tr, status, detail) do
    if tr.status == status and tr.detail == detail,
      do: {tr, []},
      else: {%{tr | status: status, detail: detail}, [{:status, status, detail}]}
  end

  defp and_then({tr, events}, fun) do
    {tr, more} = fun.(tr)
    {tr, events ++ more}
  end

  defp parse_sans(pos, sans) do
    sans
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, pos, []}, fn {san, index}, {:ok, pos, acc} ->
      case Chess.parse_san(pos, san) do
        {:ok, move} -> {:cont, {:ok, Chess.apply_move(pos, move), [{move, []} | acc]}}
        {:error, message} -> {:halt, {:error, {index, message}}}
      end
    end)
    |> case do
      {:ok, _pos, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp replay_while_legal(_pos, [], acc), do: {Enum.reverse(acc), 0}

  defp replay_while_legal(pos, [san | rest] = left, acc) do
    case Chess.parse_san(pos, san) do
      {:ok, move} -> replay_while_legal(Chess.apply_move(pos, move), rest, [{move, []} | acc])
      {:error, _message} -> {Enum.reverse(acc), length(left)}
    end
  end
end
