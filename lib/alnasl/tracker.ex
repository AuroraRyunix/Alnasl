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
    # How many unseen plies the box may work out by itself. Two: at four,
    # 11 of 207 games with an illegal move played on were "recovered" into
    # a game that was never played (at three, 9; at two, none). Setup can
    # raise it; "Resync" on a board's page searches deeper when asked.
    search_depth: 2,
    max_nodes: 200_000,
    max_candidates: 12,
    transient_ms: 8_000,
    lifted_ms: 60_000,
    promotion_default: :q,
    result_gesture: true
  }

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
            candidates: [],
            candidates_since: nil,
            candidates_raw: nil,
            memo: nil,
            gesture: nil,
            held: nil,
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

  @doc "The candidate continuations when the status is ambiguous, each a list of SAN."
  def candidates(%__MODULE__{candidates: candidates, pos: pos}) do
    Enum.map(candidates, fn found ->
      {sans, _pos} =
        Enum.map_reduce(found.steps, pos, fn {move, _flags}, pos ->
          {Chess.san(pos, move), Chess.apply_move(pos, move)}
        end)

      sans
    end)
  end

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
        o.lifted_ms
      ]
      |> Enum.map(&(tr.raw_since + &1))

    marks =
      if tr.candidates_since, do: [tr.candidates_since + o.transient_ms | marks], else: marks

    if (tr.raw == tr.phys and tr.candidates == []) or (tr.held != nil and tr.held == tr.raw),
      do: nil,
      else: marks |> Enum.filter(&(&1 > tr.at)) |> Enum.min(fn -> nil end)
  end

  # --- what comes in -----------------------------------------------------------

  @doc "The board reads `board` at time `t`."
  @spec observe(t(), integer(), tuple()) :: {t(), [event()]}
  def observe(%__MODULE__{} = tr, t, board) when is_tuple(board) do
    tr = if board == tr.raw, do: tr, else: %{tr | raw: board, raw_since: t, before: tr.raw}
    evaluate(tr, t, false)
  end

  @doc "A clock was pressed at `t`: a move that is waiting to settle is accepted now."
  @spec press(t(), integer()) :: {t(), [event()]}
  def press(%__MODULE__{} = tr, t), do: evaluate(tr, t, true)

  @doc "Time passed. Call it at `deadline/1`, or every 100 ms."
  @spec tick(t(), integer()) :: {t(), [event()]}
  def tick(%__MODULE__{} = tr, t), do: evaluate(tr, t, false)

  # --- the arbiter -------------------------------------------------------------

  @doc """
  Takes back the last `n` plies. The board, which usually still shows them,
  is not read again until it changes: the arbiter has just said what it
  shows is not the game, and re-reading it at once would put the move back.
  """
  def undo(%__MODULE__{} = tr, t, n \\ 1) do
    keep = max(length(tr.plies) - n, 0)
    {tr, events} = correct(tr, t, keep, [], :arbiter)
    {%{tr | held: tr.raw}, events}
  end

  @doc "Adds moves typed in SAN. `{:error, {index, message}}` names the first that is not legal."
  def append(%__MODULE__{} = tr, t, sans) do
    with {:ok, steps} <- parse_sans(tr.pos, sans) do
      {tr, plies} = push(tr, steps, [:arbiter], t, nil)
      tr = %{tr | candidates: [], candidates_since: nil, memo: nil}
      {:ok, {tr, [{:moves, plies}]} |> and_then(&evaluate(&1, t, false))}
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
      {tr, events} = correct(tr, t, number - 1, [first | rest], :arbiter)
      # As with `undo/3`: the board is looked at again when it next changes.
      {:ok, {%{tr | held: tr.raw}, events}, dropped}
    end
  end

  def edit(_tr, _t, _number, _san), do: {:error, "there is no such move"}

  @doc "Starts the game over from `fen`: a resumed or adjourned game, or a last resort."
  def set_position(%__MODULE__{} = tr, t, fen) do
    case Chess.parse_fen(fen) do
      {:ok, pos} ->
        fen = Chess.to_fen(pos)
        fresh = %{new(Map.put(tr.opts, :start_fen, fen)) | raw: tr.raw, raw_since: tr.raw_since}
        {:ok, {fresh, [{:restart, fen}]} |> and_then(&evaluate(&1, t, false))}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  "The board is right": search up to `depth` plies for the moves that lead
  from the certain position to the board as it reads now. One answer is
  accepted; several become candidates for `choose/3`.
  `{tracker, events, :accepted | {:candidates, n} | :none | :budget}`.
  """
  def resync(%__MODULE__{raw: nil} = tr, _t, _depth), do: {tr, [], :none}

  def resync(%__MODULE__{} = tr, t, depth) do
    {result, tr} = search(tr, 1, depth, tr.opts.max_nodes * 10)

    case result do
      {:ok, [one]} ->
        {tr, events} = accept(tr, t, one.steps, [:recovered, :arbiter])
        {tr, events, :accepted}

      {:ok, [_ | _] = many} ->
        tr = %{tr | candidates: many, candidates_since: t, candidates_raw: tr.raw}
        {tr, events} = set_status(tr, :out_of_sync, :ambiguous)
        {tr, events, {:candidates, length(many)}}

      {:ok, []} ->
        {tr, [], :none}

      :budget ->
        {tr, [], :budget}
    end
  end

  @doc "Accepts candidate number `index` (0-based) of an ambiguous position."
  def choose(%__MODULE__{} = tr, t, index) do
    case Enum.at(tr.candidates, index) do
      nil -> {tr, []}
      found -> accept(%{tr | raw: found.phys}, t, found.steps, [:recovered, :arbiter])
    end
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

    cond do
      tr.raw == tr.phys ->
        in_sync(tr)

      normal?(tr) ->
        in_sync(%{tr | phys: tr.raw})

      tr.candidates != [] and tr.raw != tr.candidates_raw and
          (one_move_away?(tr) or Position.in_hand?(tr.phys, tr.raw)) ->
        # The plain explanation beats the clever ones we were weighing.
        explain(drop_candidates(tr), t, stable, force)

      tr.candidates != [] ->
        narrow(tr, t, stable, force)

      true ->
        explain(tr, t, stable, force)
    end
  end

  defp in_sync(tr) do
    tr = %{
      tr
      | candidates: [],
        candidates_since: nil,
        candidates_raw: nil,
        gesture: nil,
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

    case one_ply(tr.pos, tr.phys, tr.raw, o.promotion_default) do
      [{move, flags}] ->
        if force or stable >= hold(tr, move, flags),
          do: accept(tr, t, [{move, flags}], []),
          else: set_status(tr, :settling, :move)

      _none ->
        cond do
          (step = move_under_hand(tr)) != nil ->
            accept_under_hand(tr, t, step)

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
  defp deeper(tr, t, stable) do
    cond do
      Position.in_hand?(tr.phys, tr.raw) and not exchange?(tr, stable) ->
        unexplained(tr, stable, :unexplained)

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
        deeper_search(tr, t, stable)
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

    with true <- stable >= tr.opts.settle_ms,
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

  defp deeper_search(tr, t, stable) do
    {result, tr} = search(tr, 2, tr.opts.search_depth, tr.opts.max_nodes)

    result = with {:ok, found} <- result, do: {:ok, distinct(found)}

    case result do
      {:ok, [one]} ->
        # Three or more moves at once is a strong claim. It is kept as the
        # one candidate and believed when the board has stood still for it a
        # good deal longer than a single move needs - or when the next move
        # fits it.
        if length(one.steps) >= 3 and stable < tr.opts.deep_settle_ms,
          do:
            %{tr | candidates: [one], candidates_since: t, candidates_raw: tr.raw}
            |> set_status(:settling, :unexplained),
          else: accept(tr, t, one.steps, [:recovered])

      {:ok, [_ | _] = many} when length(many) <= tr.opts.max_candidates ->
        %{tr | candidates: many, candidates_since: t, candidates_raw: tr.raw}
        |> set_status(:ambiguous, length(many))

      {:ok, [_ | _]} ->
        unexplained(tr, stable, :ambiguous)

      {:ok, []} ->
        unexplained(tr, stable, :unexplained)

      :budget ->
        unexplained(tr, stable, :search_gave_up)
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

  # Several sequences explain the board. Each board that follows is tried
  # against every candidate; the ones that cannot explain it fall away.
  defp narrow(tr, t, stable, force) do
    o = tr.opts

    cond do
      tr.raw == tr.candidates_raw ->
        case tr.candidates do
          [one] ->
            if length(one.steps) < 3 or stable >= o.deep_settle_ms,
              do: accept(tr, t, one.steps, [:recovered]),
              else: {tr, []}

          _several ->
            if t - tr.candidates_since >= o.transient_ms,
              do: set_status(tr, :out_of_sync, :ambiguous),
              else: {tr, []}
        end

      stable < o.settle_ms ->
        {tr, []}

      true ->
        extended =
          tr.candidates
          |> Enum.flat_map(fn found ->
            case one_ply(found.pos, found.phys, tr.raw, o.promotion_default) do
              [] ->
                case Search.find(found.pos, found.phys, tr.raw,
                       min_depth: 2,
                       max_depth: 2,
                       max_nodes: o.max_nodes,
                       promotion_default: o.promotion_default
                     ) do
                  {:ok, more, _nodes} -> Enum.map(more, &join(found, &1))
                  {:budget, _nodes} -> []
                end

              singles ->
                Enum.map(singles, fn {move, flags} ->
                  [{board, _}] =
                    found.phys
                    |> Search.outcomes(move, found.pos.turn, o.promotion_default)
                    |> Enum.filter(fn {board, _} -> board == tr.raw end)

                  join(found, %{
                    steps: [{move, flags}],
                    pos: Chess.apply_move(found.pos, move),
                    phys: board
                  })
                end)
            end
          end)
          |> distinct()

        # No candidate goes on from here - but perhaps its last move was not
        # what it seemed: a rook that turned out to be castling, a piece that
        # rested on a square on its way.
        extended =
          if extended == [] do
            for %{prev: %{} = prev} <- tr.candidates,
                {move, flags} <- one_ply(prev.pos, prev.phys, tr.raw, o.promotion_default) do
              join(prev, %{
                steps: [{move, flags}],
                pos: Chess.apply_move(prev.pos, move),
                phys: tr.raw
              })
            end
            |> distinct()
          else
            extended
          end

        case extended do
          [one] ->
            accept(tr, t, one.steps, [:recovered])

          [] ->
            # A hand over the board while we wait: keep the candidates.
            # Unless the certain position explains this board by itself,
            # they stay: one hand must not cost us what we had worked out.
            {fresh, events} = explain(drop_candidates(tr), t, stable, force)

            kept = %{tr | memo: fresh.memo, stats: fresh.stats}

            cond do
              fresh.candidates != [] or
                  Enum.any?(events, &(elem(&1, 0) in [:moves, :correction])) ->
                {fresh, events}

              # Still nothing, for too long: the alarm goes up all the same.
              fresh.status == :out_of_sync ->
                set_status(kept, :out_of_sync, fresh.detail)

              true ->
                {kept, []}
            end

          many ->
            tr = %{tr | candidates: Enum.take(many, 64), candidates_raw: tr.raw}

            if tr.status == :out_of_sync,
              do: {tr, []},
              else: set_status(tr, :ambiguous, length(many))
        end
    end
  end

  # Two candidates that are the same moves are one candidate: a promotion
  # read as a queen and the same promotion read as a pawn left standing, once
  # the piece has been taken, are the same game.
  defp distinct(found) do
    found
    |> Enum.sort_by(fn f -> Enum.count(f.steps, fn {_move, flags} -> :assumed in flags end) end)
    |> Enum.uniq_by(fn f -> {Enum.map(f.steps, &elem(&1, 0)), f.phys} end)
  end

  defp one_move_away?(tr),
    do: one_ply(tr.pos, tr.phys, tr.raw, tr.opts.promotion_default) != []

  defp drop_candidates(tr),
    do: %{tr | candidates: [], candidates_since: nil, candidates_raw: nil}

  defp join(found, more) do
    %{
      steps: found.steps ++ more.steps,
      pos: more.pos,
      phys: more.phys,
      prev: if(length(more.steps) == 1, do: Map.delete(found, :prev))
    }
  end

  # --- the pieces of the decision ----------------------------------------------

  defp one_ply(pos, phys, raw, default) do
    squares = Position.diff(phys, raw)

    if length(squares) > 4 do
      []
    else
      for move <- Chess.moves_from(pos, squares),
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
         [{move, []}] <- one_ply(tr.pos, tr.phys, before, tr.opts.promotion_default),
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
    tr = %{tr | candidates: [], candidates_since: nil, candidates_raw: nil, memo: nil}
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
    |> Enum.find_index(&(&1.phys == tr.raw))
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
    case one_ply(before.pos, before.phys, tr.raw, tr.opts.promotion_default) do
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

  defp search(tr, min, max, max_nodes) do
    key = {tr.raw, length(tr.plies), min, max, max_nodes}

    case tr.memo do
      {^key, result} ->
        {result, tr}

      _stale ->
        started = System.monotonic_time(:microsecond)

        found =
          Search.find(tr.pos, tr.phys, tr.raw,
            min_depth: min,
            max_depth: max,
            max_nodes: max_nodes,
            promotion_default: tr.opts.promotion_default
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

        {result, %{tr | memo: {key, result}, stats: stats}}
    end
  end

  # --- changing the game -------------------------------------------------------

  defp accept(tr, t, steps, extra) do
    extra = if length(steps) >= 3, do: extra ++ [:long_gap], else: extra
    {tr, plies} = push(tr, steps, extra, t, tr.raw)

    tr = %{
      tr
      | candidates: [],
        candidates_since: nil,
        candidates_raw: nil,
        memo: nil,
        gesture: nil
    }

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
            phys: before.phys
        }
      else
        tr
      end

    final = if reason in [:takeback, :revised, :promotion], do: tr.raw
    {tr, plies} = push(tr, steps, [], t, final)
    tr = %{tr | candidates: [], candidates_since: nil, candidates_raw: nil, memo: nil}

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

        ply = %{
          san: san,
          from: move.from,
          to: move.to,
          promo: move.promo,
          flags: Enum.uniq(flags ++ extra),
          at: t,
          fen: Chess.to_fen(next)
        }

        {ply,
         %{
           tr
           | history: [%{pos: tr.pos, phys: tr.phys} | tr.history],
             pos: next,
             phys: board,
             plies: tr.plies ++ [ply]
         }}
      end)

    tr = if final && steps != [], do: %{tr | phys: final}, else: tr
    {tr, plies}
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
