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
  5. it is two or more legal moves away - `Alnasl.Tracker.Search`. One answer
     is accepted and flagged `:recovered`; several are kept as candidates and
     narrowed by the boards that follow;
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
    :arbiter`;
  - `{:restart, fen}` - the game starts over from this position;
  - `{:status, status, detail}` - `:waiting_start | :live | :settling |
    :ambiguous | :out_of_sync`;
  - `{:result_suggestion, result, why}` - mate, stalemate, bare kings, or the
    kings set in the centre. A suggestion: the arbiter decides.

  A ply is `%{san, from, to, promo, flags, at, fen}`; `flags` may hold
  `:recovered` (found by the search), `:long_gap` (three or more at once),
  `:assumed` (promotion piece not seen), `:arbiter` (entered by hand).
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
    search_depth: 10,
    blind_depth: 4,
    max_nodes: 60_000,
    max_ms: nil,
    transient_ms: 8_000,
    lifted_ms: 60_000,
    promotion_default: :q,
    result_gesture: true,
    # A piece that left its square and stayed away while the game went on
    # is taken to be standing there unseen (see "A piece not seen"). A move
    # that would make it so must stand this long, or be pressed on the clock.
    unseen_piece: true,
    unseen_hold_ms: 2_000
  }

  # How many pieces may be unseen at once. One: a second piece gone is more
  # likely an exchange nobody saw than a second player with a pocket.
  @unseen_max 1

  # How many readings are remembered for the reconstruction: which squares
  # changed since a position, and in what order.
  @trail 400

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
      tr
    end)
    |> then(&%{&1 | status: if(&1.plies == [], do: :waiting_start, else: :live)})
  end

  @doc "The moves so far, as SAN."
  def sans(%__MODULE__{plies: plies}), do: Enum.map(plies, & &1.san)

  @doc "The FEN of the certain position."
  def fen(%__MODULE__{pos: pos}), do: Chess.to_fen(pos)

  @doc """
  The pieces taken to stand where the board does not see them:
  `[%{square, piece}]`, `piece` as `{colour, kind}`.
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
          tr
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
  """
  def undo(%__MODULE__{} = tr, t, n \\ 1) do
    keep = max(length(tr.plies) - n, 0)
    was = tr
    {tr, events} = correct(tr, t, keep, [], :arbiter)
    noting({%{tr | held: tr.raw}, events}, was)
  end

  @doc "Adds moves typed in SAN. `{:error, {index, message}}` names the first that is not legal."
  def append(%__MODULE__{} = tr, t, sans) do
    with {:ok, steps} <- parse_sans(tr.pos, sans) do
      was = tr
      {tr, plies} = push(tr, steps, [:arbiter], t, nil)
      tr = %{tr | memo: nil}
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
  """
  def presses(%__MODULE__{} = tr, count), do: %{tr | presses: count}

  @doc """
  "The board is right": search for the moves that lead from the game as it
  stands to the board as it reads now, deeper and for longer than the
  tracker does by itself (`depth` plies even where nothing was seen of
  them). `{tracker, events, outcome}` with `outcome` one of
  `{:accepted, sans}` (one path), `{:guessed, sans, others}` (one of
  several, taken; `others` is how many more), `:none`, `:budget`.
  """
  def resync(%__MODULE__{raw: nil} = tr, _t, _depth), do: {tr, [], :none}

  def resync(%__MODULE__{} = tr, t, depth) do
    o = tr.opts

    wide = %{
      tr
      | memo: nil,
        opts: %{
          o
          | search_depth: max(depth, o.search_depth),
            blind_depth: depth,
            max_nodes: o.max_nodes * 10,
            max_ms: o.max_ms && o.max_ms * 10
        }
    }

    {found, hit?, wide} = paths(wide, here(wide), o.deep_settle_ms, :all, 1)

    case found do
      [] ->
        {tr, [], if(hit?, do: :budget, else: :none)}

      [best | rest] ->
        flags = if rest == [], do: [:recovered, :arbiter], else: [:guessed]
        {done, events} = wide |> accept(t, best.steps, flags) |> noting(tr)
        sans = done.plies |> Enum.drop(length(tr.plies)) |> Enum.map(& &1.san)
        done = %{done | opts: o, memo: nil}

        {done, events,
         if(rest == [], do: {:accepted, sans}, else: {:guessed, sans, length(rest)})}
    end
  end

  @doc """
  The other ways the reconstructed moves around ply `number` (1-based)
  could have gone: every legal sequence of the same length (or shorter)
  from the position before that run of marked moves to the position after
  it, over the squares its moves used.

  `%{from: first_ply, to: last_ply, fen: fen_before, current: [san],
  options: [[san]]}` - `options` has `current` first - or `nil` when that
  ply is not a reconstructed or guessed one.
  """
  def alternatives(%__MODULE__{} = tr, number) do
    with {first, last} <- run(tr, number) do
      count = length(tr.plies)
      before = Enum.at(tr.history, count - first)
      target = if last == count, do: tr.phys, else: Enum.at(tr.history, count - last - 1).phys
      run = Enum.slice(tr.plies, (first - 1)..(last - 1))

      touch =
        Position.diff(before.phys, target) ++ Enum.flat_map(run, &[&1.from, &1.to])

      found =
        for depth <- Enum.uniq([1, length(run)]),
            {:ok, found, _nodes} <- [
              Search.find(before.pos, before.phys, target,
                min_depth: depth,
                max_depth: length(run),
                max_nodes: tr.opts.max_nodes,
                promotion_default: tr.opts.promotion_default,
                unseen: Enum.map(before.unseen, & &1.square),
                touch: touch
              )
            ],
            one <- found,
            do: sans_of(before.pos, one.steps)

      current = Enum.map(run, & &1.san)
      others = found |> Enum.uniq() |> Enum.sort() |> List.delete(current) |> Enum.take(63)

      %{
        from: first,
        to: last,
        fen: Chess.to_fen(before.pos),
        current: current,
        options: [current | others]
      }
    else
      _none -> nil
    end
  end

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

  # The run of reconstructed or guessed plies that ply `number` is in, as
  # `{first, last}` (1-based).
  defp run(tr, number) do
    marked? = fn ply -> ply != nil and (:recovered in ply.flags or :guessed in ply.flags) end
    at = fn n -> if n >= 1, do: Enum.at(tr.plies, n - 1) end

    if marked?.(at.(number)) do
      first = Enum.find(number..1//-1, &(not marked?.(at.(&1 - 1))))
      last = Enum.find(number..length(tr.plies), &(not marked?.(at.(&1 + 1))))
      {first, last}
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
      if elem(tr.raw, square) == piece,
        do: %{tr | phys: put_elem(tr.phys, square, piece), unseen: tr.unseen -- [entry]},
        else: tr
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

  defp in_sync(tr) do
    tr = %{
      tr
      | gesture: nil,
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
            if stable >= o.takeback_settle_ms,
              do: correct(tr, t, length(tr.plies) - k, [], :takeback),
              else: set_status(tr, :settling, :takeback)

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
  # 4. from before the last moves that were themselves reconstructed: they
  #    explained the board then, and do not explain this one.
  #
  # One path is accepted and marked `:recovered`. Of several, the first by
  # `rank/3` is accepted and marked `:guessed`; `alternatives/2` lists the
  # others for the arbiter. None: the alarm, as before.
  defp reconstruct(tr, t, stable, scope) do
    {found, hit?, tr} = paths(tr, here(tr), stable, scope, 2)
    why = if hit?, do: :search_gave_up, else: :unexplained

    cond do
      found != [] ->
        accept(tr, t, hd(found).steps, mark(found))

      (result = unseen_search(tr, t, stable)) != nil ->
        result

      (from = anchor(tr)) != nil ->
        {found, _hit?, tr} = paths(tr, from, stable, :guided, 1)

        if found == [],
          do: unexplained(tr, stable, why),
          else: correct(tr, t, from.count, marked(hd(found).steps, mark(found)), :revised)

      true ->
        unexplained(tr, stable, why)
    end
  end

  defp mark([_one]), do: [:recovered]
  defp mark(_several), do: [:guessed]

  defp marked(steps, flags) do
    flags = if length(steps) >= 3, do: flags ++ [:long_gap], else: flags
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

  # The paths from `from` to the board, best first: `{found, budget_hit?, tr}`.
  defp paths(tr, from, stable, scope, min) do
    o = tr.opts
    {guided, tr} = search(tr, from, min, o.search_depth, touched(tr, from))

    {found, hit?, tr} =
      case guided do
        {:ok, [_ | _] = found} ->
          {found, false, tr}

        guided when scope == :guided ->
          {[], guided == :budget, tr}

        guided ->
          depth = min(o.search_depth, if(stable >= o.deep_settle_ms, do: o.blind_depth, else: 2))

          case search(tr, from, min, depth, nil) do
            {{:ok, found}, tr} -> {found, guided == :budget, tr}
            {:budget, tr} -> {[], true, tr}
          end
      end

    {found, tr} = pressed_for(tr, from, distinct(found))
    {rank(tr, from, found), hit?, tr}
  end

  # The clock has been pressed more often than these paths have moves: they
  # are too short to be the whole story. Longer ones are looked for, and
  # go first. (A press tells late, never early: fewer presses than moves
  # proves nothing, more does.)
  defp pressed_for(tr, _from, [] = found), do: {found, tr}
  defp pressed_for(%{presses: nil} = tr, _from, found), do: {found, tr}

  defp pressed_for(tr, from, [one | _] = found) do
    have = length(one.steps)
    want = tr.presses - from.count

    if want > have and have < tr.opts.search_depth do
      case search(tr, from, have + 1, min(want + 1, tr.opts.search_depth), touched(tr, from)) do
        {{:ok, longer}, tr} -> {distinct(longer) ++ found, tr}
        {:budget, tr} -> {found, tr}
      end
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
  # (`out_of_order/3`); then the one that assumes least about a promotion;
  # then by the moves' names, so that the same board always gives the same
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
       sans_of(from.pos, one.steps)}
    end)
  end

  # How many of the moves are not seen in the readings in the order the
  # path has them: each move is looked for - both its squares reading as
  # the move leaves them - from the reading where the move before it was
  # found. A game played move by move in front of the board scores 0 for
  # the order it was played in, and more for the same moves in another.
  defp out_of_order(from, steps, boards) do
    {_phys, _pos, _rest, missed} =
      Enum.reduce(steps, {from.phys, from.pos, boards, 0}, fn {move, flags},
                                                              {phys, pos, rest, missed} ->
        {board, _} =
          phys
          |> Search.outcomes(move, pos.turn, tr_default(flags))
          |> Enum.find(fn {_board, f} -> :assumed in f == :assumed in flags end)

        shows? = fn seen ->
          elem(seen, move.from) == elem(board, move.from) and
            elem(seen, move.to) == elem(board, move.to)
        end

        case Enum.drop_while(rest, &(not shows?.(&1))) do
          [] -> {board, Chess.apply_move(pos, move), rest, missed + 1}
          found -> {board, Chess.apply_move(pos, move), found, missed}
        end
      end)

    missed
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
         {{:ok, found}, supposed} <- search(supposed, here(supposed), 2, 2, nil),
         [one] <- distinct(found) do
      supposed |> accept(t, one.steps, [:recovered]) |> since(tr)
    else
      _no -> nil
    end
  end

  defp unexplained(tr, stable, why) do
    o = tr.opts
    gesture = if o.result_gesture and tr.plies != [], do: gesture(tr)

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
          board == raw,
          Chess.legal?(pos, move),
          do: {move, flags}
    end
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
    tr = %{tr | memo: nil}
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
  defp search(tr, from, min, max, touch) do
    stamp = {tr.raw, length(tr.plies), tr.unseen}
    key = {from.count, min, max, touch != nil}

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
          Search.find(from.pos, from.phys, tr.raw,
            min_depth: min,
            max_depth: max,
            max_nodes: tr.opts.max_nodes,
            max_ms: tr.opts.max_ms,
            promotion_default: tr.opts.promotion_default,
            unseen: Enum.map(from.unseen, & &1.square),
            touch: touch
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
    extra = if length(steps) >= 3, do: extra ++ [:long_gap], else: extra
    {tr, plies} = push(tr, steps, extra, t, tr.raw)

    tr = %{tr | memo: nil, gesture: nil}
    {tr, status} = set_status(tr, :live, nil)
    {tr, [{:moves, plies}] ++ status ++ suggestion(tr)}
  end

  defp correct(tr, t, keep, steps, reason) do
    back = length(tr.plies) - keep

    tr =
      if back > 0 do
        before = Enum.at(tr.history, back - 1)

        %{
          tr
          | plies: Enum.take(tr.plies, keep),
            history: Enum.drop(tr.history, back),
            pos: before.pos,
            phys: before.phys,
            unseen: before.unseen
        }
      else
        tr
      end

    final = if reason in [:takeback, :revised, :promotion], do: tr.raw
    {tr, plies} = push(tr, steps, [], t, final)
    tr = %{tr | memo: nil}

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
