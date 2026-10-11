defmodule Alnasl.Simulator.Script do
  @moduledoc """
  What a real board would report while a game is played on it - hands and all.

  `build/2` takes the moves of a game and returns the timed stream a driver
  would deliver: `{t_ms, {:position, board}}`, `{t_ms, {:clock, reading}}`,
  `{t_ms, :disconnected}`, `{t_ms, :connected}`. Pure and seeded, so the same
  options give the same stream: the simulator process plays it out in real or
  accelerated time, and the tests feed it straight to the tracker.

  A move is never one event. A piece is lifted (the square reads empty), then
  put down; a capture takes a piece off first or lifts the capturer first; a
  castle is two piece moves in either order; a promotion is a pawn that
  disappears and a piece that appears a moment later.

  ## Faults

  `:faults` is a map of fault to the chance (0.0-1.0) that it happens on a
  ply. Each is something that happens at a real board:

  | fault | what the board reports |
  |---|---|
  | `:missed` | nothing at all for this ply - not its move, not its clock press. The next thing seen already has it played |
  | `:lift` | a piece lifted and put back before the move |
  | `:knock` | a piece knocked off and set back on its square |
  | `:swap` | two pieces of one colour put on each other's squares, then corrected |
  | `:hover` | a square flickering empty and back, a few times |
  | `:takeback` | another legal move played, then taken back, then the real move |
  | `:slide` | a rook, bishop or queen resting on a square on its way |
  | `:clock_miss` | the move is seen, the clock press after it is not |
  | `:leave_pawn` | a pawn promoted to a queen but left standing as a pawn |
  | `:slam` | the move in one reading: the piece was never seen in the air, and a capture never in two steps. A hand faster than the board scans |
  | `:topple` | the move knocks a neighbour over: it is off its square when the clock is pressed and set back on the opponent's time |
  | `:unseen` | a piece (never a king) stops being seen where it stands, for `:unseen_plies` plies or until it moves or is taken: parked beside the board, or standing where the sensor loses it. The game goes on |

  Besides those: `:unplug` (`[{ply, plies}]` - the board is gone from before
  `ply` for that many plies, then back), `:illegal_at` (a ply at which the
  player makes a move that is not legal, after which the game is played on as
  if nothing happened) and `:gesture` (the kings set in the centre for the
  result once the game is over).

  ## Fast play

  `profile(:bullet)` is a set of options for a game played against the
  clock: a move every 0.3-2 seconds, a minute each and no increment, pieces
  slammed down (`:slam`), knocked over (`:topple`, `:knock`), plies that go
  by unseen (`:missed`), and a clock that says what happened up to a second
  late (`:clock_lag_ms` - a real DGT clock reports about once a second, so
  the press usually arrives after the next hand is already on the board,
  and two presses inside one second are never seen at all: `:clock_miss`).

  The result also says what was done (`:log`, `[{ply, fault}]`) so a test can
  say what the tracker should have made of it.
  """

  import Bitwise, only: [band: 2]

  alias Alnasl.Chess

  @defaults %{
    seed: 1,
    start_fen: nil,
    faults: %{},
    # How many plies in a row may go unseen. One missed ply leaves two moves
    # to find at once, which the tracker can always do or knows it cannot;
    # more is where a board alone stops being enough (docs/design.md).
    missed_streak: 1,
    unplug: [],
    illegal_at: nil,
    gesture: nil,
    clock: true,
    initial_ms: 5_400_000,
    increment_ms: 30_000,
    think_ms: {2_500, 9_000},
    # After an illegal move the next think must outlast the tracker's
    # patience, or the alarm would race the next move.
    long_think_ms: 12_000,
    step_ms: {80, 500},
    pause_ms: {200, 1_500},
    fault_ms: {600, 3_500},
    # From the move to the hand on the lever.
    press_ms: {150, 900},
    # `{low, high}`: the clock's reading reaches the box that much after
    # the press, whatever the hands do meanwhile. `nil`: at once.
    clock_lag_ms: nil,
    # For how many plies a piece of the `:unseen` fault stays out of sight.
    unseen_plies: {1, 5}
  }

  @bullet %{
    initial_ms: 60_000,
    increment_ms: 0,
    think_ms: {100, 1_500},
    step_ms: {30, 160},
    pause_ms: {40, 300},
    fault_ms: {150, 900},
    press_ms: {30, 250},
    clock_lag_ms: {100, 900},
    faults: %{slam: 0.3, missed: 0.06, topple: 0.05, knock: 0.05, hover: 0.05, clock_miss: 0.1}
  }

  @type result :: %{
          events: [{non_neg_integer(), term()}],
          log: [{pos_integer(), atom()}],
          duration_ms: non_neg_integer(),
          sans: [String.t()]
        }

  def defaults, do: @defaults

  @doc """
  A named set of options. `:bullet` is fast play (see the module's "Fast
  play"); `:classical` is the defaults.
  """
  def profile(:bullet), do: @bullet
  def profile(_classical), do: %{}

  @spec build([String.t()], keyword() | map()) :: result()
  def build(sans, opts \\ []) do
    o = Map.merge(@defaults, Map.new(opts))
    fen = o.start_fen || Chess.start_fen()
    {:ok, pos} = Chess.parse_fen(fen)

    st = %{
      o: o,
      b: pos.board,
      t: 0,
      ev: [],
      log: [],
      mute: false,
      rng: :rand.seed_s(:exsss, {o.seed, 77, 4711}),
      white: o.initial_ms,
      black: o.initial_ms,
      pressed_at: 0,
      derailed: false,
      unplug_left: 0,
      streak: 0,
      clock_at: 0,
      hidden: nil
    }

    st = emit(st, {:position, st.b})
    st = if o.clock, do: emit(st, {:clock, reading(st, pos.turn)}), else: st

    {st, _pos} =
      sans
      |> Enum.with_index(1)
      |> Enum.reduce({st, pos}, fn {san, number}, {st, pos} ->
        {:ok, move} = Chess.parse_san(pos, san)
        {ply(st, pos, move, number), Chess.apply_move(pos, move)}
      end)

    st = if st.unplug_left > 0, do: plug(st), else: st
    # A board is still read when nobody moves: whatever was missed at the
    # end is on the next reading.
    st = st |> wait(1_500) |> emit({:position, st.b})
    st = if o.clock, do: st |> wait(1_000) |> emit({:clock, reading(st, :none)}), else: st
    st = if o.gesture, do: gesture(st, o.gesture), else: st

    # A lagging clock's readings were written ahead of their time: put
    # everything in the order it arrives. Stable, so events of one
    # millisecond keep the order they were made in.
    events = st.ev |> Enum.reverse() |> Enum.sort_by(&elem(&1, 0))
    %{events: events, log: Enum.reverse(st.log), duration_ms: st.t, sans: sans}
  end

  # --- one ply -----------------------------------------------------------------

  defp ply(st, pos, move, number) do
    o = st.o

    st =
      case Enum.find(o.unplug, fn {at, _plies} -> at == number end) do
        {_at, plies} ->
          st
          |> note(number, :unplug)
          |> emit(:disconnected)
          |> Map.merge(%{mute: true, unplug_left: plies})

        nil ->
          st
      end

    {think, st} =
      if st.derailed,
        do: {o.long_think_ms, st},
        else: between(st, o.think_ms)

    st = wait(st, think)

    cond do
      st.derailed ->
        st |> blind(move) |> press(pos, number)

      o.illegal_at == number ->
        st
        |> note(number, :illegal)
        |> illegal(pos)
        |> Map.put(:derailed, true)
        |> press(pos, number)

      st.unplug_left > 0 ->
        st = st |> play(pos, move, false) |> silent_press(pos)
        left = st.unplug_left - 1
        st = %{st | unplug_left: left}
        if left == 0, do: st |> wait(700) |> plug(), else: st

      true ->
        st = st |> see_again(number) |> maybe_hide(number)
        {missed?, st} = chance(st, :missed)

        if missed? and st.streak < o.missed_streak do
          st = note(st, number, :missed)

          %{st | mute: true, streak: st.streak + 1}
          |> play(pos, move, false)
          |> silent_press(pos)
          |> Map.put(:mute, false)
        else
          %{st | streak: 0}
          |> disturbances(pos, number)
          |> maybe_takeback(pos, move, number)
          |> played(pos, move, number)
        end
    end
  end

  # The move as the hands of this ply make it: slammed or not, with or
  # without a neighbour going over.
  defp played(st, pos, move, number) do
    {slam?, st} = chance(st, :slam)
    {topple?, st} = chance(st, :topple)

    st =
      if slam? do
        # Nothing of the move is seen but its end.
        st = st |> note(number, :slam) |> Map.put(:mute, true) |> play(pos, move, true, number)
        emit(%{st | mute: false}, {:position, st.b})
      else
        play(st, pos, move, true, number)
      end

    bystanders = for sq <- occupied(st.b), sq != move.to, do: sq

    if topple? and bystanders != [] do
      {square, st} = pick(st, bystanders)
      piece = elem(st.b, square)

      st
      |> note(number, :topple)
      |> steps([{:lift, square}], {20, 80})
      |> maybe_press(pos, number)
      |> pause(st.o.fault_ms)
      |> steps([{:put, square, piece}])
    else
      maybe_press(st, pos, number)
    end
  end

  # The `:unseen` fault. The piece stands where it stood; the board just
  # does not report it (`emit/2`).
  defp maybe_hide(%{hidden: nil} = st, number) do
    {yes?, st} = chance(st, :unseen)
    squares = for sq <- occupied(st.b), not match?({_, :k}, elem(st.b, sq)), do: sq

    if yes? and squares != [] do
      {square, st} = pick(st, squares)
      {plies, st} = between(st, st.o.unseen_plies)
      st = %{st | hidden: %{square: square, piece: elem(st.b, square), until: number + plies}}
      st |> note(number, :unseen) |> emit({:position, st.b}) |> pause(st.o.fault_ms)
    else
      st
    end
  end

  defp maybe_hide(st, _number), do: st

  defp see_again(%{hidden: nil} = st, _number), do: st

  defp see_again(%{hidden: hidden} = st, number) do
    cond do
      # It moved, or was taken: the board has shown that by itself.
      elem(st.b, hidden.square) != hidden.piece -> %{st | hidden: nil}
      number >= hidden.until -> %{st | hidden: nil} |> emit({:position, st.b}) |> pause()
      true -> st
    end
  end

  defp plug(st) do
    st = %{st | mute: false, unplug_left: 0}
    st |> emit(:connected) |> emit({:position, st.b})
  end

  # --- the move itself ---------------------------------------------------------

  defp play(st, pos, move, faults?, number \\ 0) do
    us = pos.turn
    piece = elem(st.b, move.from)

    case move do
      %{kind: kind} when kind in [:castle_k, :castle_q] ->
        {rook_from, rook_to} =
          if kind == :castle_k, do: {move.to + 1, move.to - 1}, else: {move.to - 2, move.to + 1}

        king = [{:lift, move.from}, {:put, move.to, piece}]
        rook = [{:lift, rook_from}, {:put, rook_to, {us, :r}}]
        {order, st} = pick(st, [:king_first, :rook_first, :both_up])

        case order do
          :king_first -> st |> steps(king) |> pause() |> steps(rook)
          # Short of the tracker's castle hold: longer, and the rook move
          # would be believed first and corrected after - right, but noisy.
          :rook_first -> st |> steps(rook) |> pause({200, 1_200}) |> steps(king)
          :both_up -> steps(st, [hd(king), hd(rook), List.last(king), List.last(rook)])
        end

      %{kind: :ep} ->
        taken = move.to + if(us == :w, do: 8, else: -8)
        {order, st} = pick(st, [:move_first, :take_first])

        if order == :move_first,
          do:
            st
            |> steps([{:lift, move.from}, {:put, move.to, piece}])
            |> pause()
            |> steps([{:lift, taken}]),
          else: steps(st, [{:lift, taken}, {:lift, move.from}, {:put, move.to, piece}])

      %{promo: promo} when promo != nil ->
        {leave?, st} = if promo == :q and faults?, do: chance(st, :leave_pawn), else: {false, st}
        off = if move.capture, do: [{:lift, move.to}], else: []
        {order, st} = pick(st, [:swap_in_hand, :pawn_then_piece])

        cond do
          leave? ->
            st
            |> note(number, :leave_pawn)
            |> steps([{:lift, move.from}] ++ off ++ [{:put, move.to, piece}])

          order == :swap_in_hand ->
            st
            |> steps([{:lift, move.from}] ++ off)
            |> pause()
            |> steps([{:put, move.to, {us, promo}}])

          true ->
            st
            |> steps([{:lift, move.from}] ++ off ++ [{:put, move.to, piece}])
            |> pause({300, 1_500})
            |> steps([{:lift, move.to}, {:put, move.to, {us, promo}}])
        end

      %{capture: capture} when capture != nil ->
        {order, st} = pick(st, [:off_first, :lift_first, :replace])

        case order do
          :off_first -> steps(st, [{:lift, move.to}, {:lift, move.from}, {:put, move.to, piece}])
          :lift_first -> steps(st, [{:lift, move.from}, {:lift, move.to}, {:put, move.to, piece}])
          :replace -> steps(st, [{:lift, move.from}, {:put, move.to, piece}])
        end

      _quiet ->
        {slide?, st} = if faults?, do: chance(st, :slide), else: {false, st}
        via = if slide?, do: between_squares(move), else: []

        case via do
          [] ->
            steps(st, [{:lift, move.from}, {:put, move.to, piece}])

          squares ->
            {mid, st} = pick(st, squares)

            st
            |> note(number, :slide)
            |> steps([{:lift, move.from}, {:put, mid, piece}])
            |> pause({100, 900})
            |> steps([{:lift, mid}, {:put, move.to, piece}])
        end
    end
  end

  # The squares strictly between the ends of a rook, bishop or queen move.
  defp between_squares(%{piece: piece, from: from, to: to}) when piece in [:r, :b, :q] do
    {f1, r1} = {band(from, 7), div(from, 8)}
    {f2, r2} = {band(to, 7), div(to, 8)}
    {df, dr} = {sign(f2 - f1), sign(r2 - r1)}
    count = max(abs(f2 - f1), abs(r2 - r1)) - 1
    for i <- 1..count//1, do: (r1 + dr * i) * 8 + f1 + df * i
  end

  defp between_squares(_move), do: []

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_zero), do: 0

  # A move played on a board that has left the game behind: whatever stands
  # on the from-square goes to the to-square.
  defp blind(st, move) do
    case elem(st.b, move.from) do
      nil -> st
      piece -> steps(st, [{:lift, move.from}, {:put, move.to, piece}])
    end
  end

  # A move no rule allows: a piece of the side to move set down on an empty
  # square it cannot reach, such that no legal move gives the same board.
  defp illegal(st, pos) do
    us = pos.turn
    legal_boards = for m <- Chess.legal_moves(pos), do: Chess.apply_move(pos, m).board

    options =
      for from <- 0..63,
          {^us, kind} = piece <- [elem(st.b, from)],
          kind != :k,
          to <- 0..63,
          elem(st.b, to) == nil,
          # Not onto a last rank, where a pawn would look like a promotion.
          div(to, 8) not in [0, 7],
          board = st.b |> put_elem(from, nil) |> put_elem(to, piece),
          board not in legal_boards,
          do: {from, to, piece}

    {{from, to, piece}, st} = pick(st, options)
    steps(st, [{:lift, from}, {:put, to, piece}])
  end

  # --- what hands do besides moving --------------------------------------------

  defp disturbances(st, pos, number) do
    Enum.reduce([:hover, :lift, :knock, :swap], st, fn fault, st ->
      {yes?, st} = chance(st, fault)
      if yes?, do: st |> note(number, fault) |> disturb(fault, pos), else: st
    end)
  end

  defp disturb(st, :hover, _pos) do
    {square, st} = pick(st, occupied(st.b))
    piece = elem(st.b, square)
    {times, st} = between(st, {1, 3})

    Enum.reduce(1..times, st, fn _i, st ->
      st |> steps([{:lift, square}], {40, 150}) |> steps([{:put, square, piece}], {40, 150})
    end)
    |> pause({200, 800})
  end

  defp disturb(st, :lift, pos) do
    {square, st} = pick(st, occupied(st.b, pos.turn))
    piece = elem(st.b, square)

    st
    |> steps([{:lift, square}])
    |> pause(st.o.fault_ms)
    |> steps([{:put, square, piece}])
    |> pause()
  end

  defp disturb(st, :knock, _pos) do
    {square, st} = pick(st, occupied(st.b))
    piece = elem(st.b, square)

    st
    |> steps([{:lift, square}], {20, 80})
    |> pause(st.o.fault_ms)
    |> steps([{:put, square, piece}])
    |> pause()
  end

  defp disturb(st, :swap, pos) do
    pairs =
      for a <- occupied(st.b, pos.turn),
          b <- occupied(st.b, pos.turn),
          a < b,
          elem(st.b, a) != elem(st.b, b),
          do: {a, b}

    case pairs do
      [] ->
        st

      pairs ->
        {{a, b}, st} = pick(st, pairs)
        {pa, pb} = {elem(st.b, a), elem(st.b, b)}

        st
        |> steps([{:lift, a}, {:lift, b}, {:put, a, pb}, {:put, b, pa}])
        |> pause(st.o.fault_ms)
        |> steps([{:lift, a}, {:lift, b}, {:put, a, pa}, {:put, b, pb}])
        |> pause()
    end
  end

  # Another legal move is played, stands a while, and is taken back.
  defp maybe_takeback(st, pos, move, number) do
    {yes?, st} = chance(st, :takeback)

    others =
      for m <- Chess.legal_moves(pos),
          m.kind in [:normal, :double],
          m.promo == nil,
          {m.from, m.to} != {move.from, move.to},
          do: m

    if yes? and others != [] do
      {other, st} = pick(st, others)
      piece = elem(st.b, other.from)
      taken = elem(st.b, other.to)
      back = if taken, do: [{:put, other.to, taken}], else: []

      st
      |> note(number, :takeback)
      |> steps(
        [{:lift, other.from}] ++
          if(taken, do: [{:lift, other.to}], else: []) ++ [{:put, other.to, piece}]
      )
      |> pause({200, 3_000})
      |> steps([{:lift, other.to}, {:put, other.from, piece}] ++ back)
      |> pause({200, 2_500})
    else
      st
    end
  end

  # The kings set in the centre: see `Alnasl.Tracker` for the convention.
  defp gesture(st, result) do
    {white, black} =
      case result do
        "1-0" -> {36, 27}
        "0-1" -> {35, 28}
        _draw -> {36, 28}
      end

    squares = Tuple.to_list(st.b)
    wk = Enum.find_index(squares, &(&1 == {:w, :k}))
    bk = Enum.find_index(squares, &(&1 == {:b, :k}))
    clear = for sq <- [white, black], elem(st.b, sq) != nil, sq not in [wk, bk], do: {:lift, sq}

    st
    |> wait(3_000)
    |> note(0, :gesture)
    |> steps(
      clear ++ [{:lift, wk}, {:put, white, {:w, :k}}, {:lift, bk}, {:put, black, {:b, :k}}]
    )
  end

  # --- clock -------------------------------------------------------------------

  defp maybe_press(st, pos, number) do
    {miss?, st} = chance(st, :clock_miss)

    if miss?,
      do: st |> note(number, :clock_miss) |> silent_press(pos),
      else: press(st, pos, number)
  end

  defp press(st, pos, _number) do
    {delay, st} = between(st, st.o.press_ms)
    st = st |> wait(delay) |> silent_press(pos)

    cond do
      not st.o.clock ->
        st

      st.o.clock_lag_ms == nil ->
        emit(st, {:clock, reading(st, other(pos.turn))})

      true ->
        {lag, st} = between(st, st.o.clock_lag_ms)
        emit_at(st, st.t + lag, {:clock, reading(st, other(pos.turn))})
    end
  end

  # The clock is pressed whether or not anybody hears it.
  defp silent_press(st, pos) do
    used = st.t - st.pressed_at

    st =
      if pos.turn == :w,
        do: %{st | white: max(st.white - used, 0) + st.o.increment_ms},
        else: %{st | black: max(st.black - used, 0) + st.o.increment_ms}

    %{st | pressed_at: st.t}
  end

  defp reading(st, running) do
    side = %{w: :white, b: :black, white: :white, black: :black, none: :none}
    %{white_ms: st.white, black_ms: st.black, running: Map.fetch!(side, running)}
  end

  defp other(:w), do: :b
  defp other(:b), do: :w

  # --- plumbing ----------------------------------------------------------------

  defp steps(st, list, range \\ nil) do
    Enum.reduce(list, st, fn step, st ->
      {dt, st} = between(st, range || st.o.step_ms)

      board =
        case step do
          {:lift, square} -> put_elem(st.b, square, nil)
          {:put, square, piece} -> put_elem(st.b, square, piece)
        end

      st = %{st | b: board, t: st.t + dt}
      emit(st, {:position, board})
    end)
  end

  defp pause(st, range \\ nil) do
    {dt, st} = between(st, range || st.o.pause_ms)
    wait(st, dt)
  end

  defp wait(st, ms), do: %{st | t: st.t + ms}

  defp emit(%{mute: true} = st, {:position, _board}), do: st
  defp emit(%{mute: true} = st, {:clock, _reading}), do: st

  defp emit(%{hidden: %{square: square, piece: piece}} = st, {:position, board})
       when elem(board, square) == piece,
       do: %{st | ev: [{st.t, {:position, put_elem(board, square, nil)}} | st.ev]}

  defp emit(st, event), do: %{st | ev: [{st.t, event} | st.ev]}

  # A reading that arrives later than it was made - but never before the
  # one made before it: a clock does not report out of order.
  defp emit_at(%{mute: true} = st, _t, _event), do: st

  defp emit_at(st, t, event) do
    t = max(t, st.clock_at + 1)
    %{st | ev: [{t, event} | st.ev], clock_at: t}
  end

  defp note(st, number, fault), do: %{st | log: [{number, fault} | st.log]}

  defp occupied(board), do: for(i <- 0..63, elem(board, i) != nil, do: i)
  defp occupied(board, colour), do: for(i <- 0..63, match?({^colour, _}, elem(board, i)), do: i)

  defp chance(st, fault) do
    case Map.get(st.o.faults, fault, 0) do
      rate when rate <= 0 ->
        {false, st}

      rate ->
        {x, rng} = :rand.uniform_s(st.rng)
        {x < rate, %{st | rng: rng}}
    end
  end

  defp between(st, {low, high}) do
    {x, rng} = :rand.uniform_s(st.rng)
    {low + trunc(x * (high - low + 1)), %{st | rng: rng}}
  end

  defp pick(st, [only]), do: {only, st}

  defp pick(st, list) do
    {n, rng} = :rand.uniform_s(length(list), st.rng)
    {Enum.at(list, n - 1), %{st | rng: rng}}
  end
end
