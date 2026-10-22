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
  | `:leave_pawn` | a pawn promoted - to any piece - but left standing as a pawn: no spare piece at hand. It goes on standing in for that piece until it is taken or the game ends |
  | `:slam` | the move in one reading: the piece was never seen in the air, and a capture never in two steps. A hand faster than the board scans |
  | `:topple` | the move knocks a neighbour over: it is off its square when the clock is pressed and set back on the opponent's time |
  | `:between` | a piece set down between two squares: the board reads it on the square NEXT to the one it went to (a legal move too), until it moves on, is taken, or somebody straightens it a few plies later. Nothing looks wrong until a later move makes no sense |
  | `:mask` | crosstalk: a piece beside another reads empty - for a moment, or for the rest of this ply. See "Crosstalk" |
  | `:mistype` | crosstalk: a piece beside another reads as another piece of its colour - for a moment, or until it is touched or nothing stands beside it any more |
  | `:unseen` | a piece (never a king) stops being seen where it stands, for `:unseen_plies` plies or until it moves or is taken: parked beside the board, or standing where the sensor loses it. The game goes on |

  Besides those: `:promotion_capture` (`:pawn_left | :quick`) rewrites the
  game so that every promotion is taken at once, where the other side can
  take on that square: the game ends with the capture (`:sans` in the
  result is the game as played, `:taken_at` the promotion's ply). `:pawn_left` leaves the pawn standing on
  the last rank until it is taken; `:quick` puts the new piece down and
  has it taken before it could settle - and the promotion's clock press
  is the one press that is never on time for that. `:promote_as` (`:q`,
  `:r`, `:b`, `:n`, or `:cycle` for one by the seed) makes those promotions that piece instead, where the
  game then still holds. `:unplug` (`[{ply, plies}]` - the board is gone from before
  `ply` for that many plies, then back), `:out_of_turn_at` and
  `:illegal_back_at` (a ply before which a move is made out of turn, or a
  move no rule allows, left standing a few seconds and taken back),
  `:illegal_at` (a ply at which the
  player makes a move that is not legal, after which the game is played on as
  if nothing happened), `:gesture` (the kings set in the centre for the
  result once the game is over) and `:dead_square`.

  ## Crosstalk

  A DGT board finds a piece by the resonance of the coil in its base: each
  kind of piece rings at its own frequency, and the board reports the
  piece code (0x01-0x0C: pawn, rook, knight, bishop, king, queen, White's
  first) whose band it heard. Two pieces close together disturb each
  other's reading. `:mask` is a piece that is not heard at all - for 100-
  700 ms, or (half the time) from now until the next ply begins. `:mistype`
  is a piece heard in the neighbouring band: reported as the piece whose
  code is next to its own (a pawn as a rook, a rook as a pawn or a knight,
  a knight as a rook or a bishop, a bishop as a knight or a king, a king
  as a bishop or a queen, a queen as a king), same colour - for a moment,
  or (half the time) until the piece is lifted or nothing stands beside it.
  ASSUMED: that neighbouring codes are neighbouring bands. Either fault
  picks a piece that has another on a square next to it; `:log` has
  `{ply, :mask}` and `{ply, :mistype}`.

  ## A sensor that has died

  `:dead_square` (`{ply, :off | :stuck}`) breaks one square's sensor before
  `ply`, for the rest of the game: `:off` reads it empty whatever stands on
  it, `:stuck` goes on reading the piece that stood there when it broke,
  after that piece has left and whatever comes. Not any square: one that
  the game has a piece leave or land on at least twice from there on (for
  `:stuck`, one with a piece on it that will leave), since a dead corner
  nobody plays on is a dead sensor nobody needs to know about. `:log` has
  `{ply, :dead_square}` and `:dead` says which square.

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
    # A ply before which the side that has just moved moves again - a legal
    # move, out of turn - leaves it standing a while and takes it back.
    out_of_turn_at: nil,
    # A ply before which the side to move makes a move no rule allows,
    # leaves it standing a while and takes it back.
    illegal_back_at: nil,
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
    unseen_plies: {1, 5},
    # For how many plies a piece of the `:between` fault is left crooked.
    between_plies: {1, 4},
    dead_square: nil,
    promotion_capture: nil,
    promote_as: nil
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
          sans: [String.t()],
          dead: 0..63 | nil,
          taken_at: pos_integer() | nil
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
    {sans, taken_at} = taken_at_once(pos, sans, o)

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
      hidden: nil,
      crooked: nil,
      # Crosstalk that lasts: `[%{square, piece, as, until}]` - the square
      # reads `as` while `piece` stands on it (see "Crosstalk").
      crosstalk: [],
      dead: nil,
      # The promotion that the `:promotion_capture` game has taken at once.
      taken_at: taken_at,
      # The positions of the game, so that a square can be chosen for what
      # the game will do on it.
      positions: positions(pos, sans)
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
    # Whoever tidies the board after the game straightens the piece, and a
    # piece not heard through the last move is heard again after it.
    st = %{st | crooked: nil, crosstalk: Enum.filter(st.crosstalk, &(&1.until == nil))}
    # A board is still read when nobody moves: whatever was missed at the
    # end is on the next reading.
    st = st |> wait(1_500) |> emit({:position, st.b})
    st = if o.clock, do: st |> wait(1_000) |> emit({:clock, reading(st, :none)}), else: st
    st = if o.gesture, do: gesture(st, o.gesture), else: st

    # A lagging clock's readings were written ahead of their time: put
    # everything in the order it arrives. Stable, so events of one
    # millisecond keep the order they were made in.
    events = st.ev |> Enum.reverse() |> Enum.sort_by(&elem(&1, 0))

    %{
      events: events,
      log: Enum.reverse(st.log),
      duration_ms: st.t,
      sans: sans,
      dead: st.dead && st.dead.square,
      taken_at: st.taken_at
    }
  end

  # --- a promotion taken at once ---------------------------------------------------

  # The game up to the first promotion that the other side can take on its
  # square, that promotion (as `:promote_as`, if that piece leaves the
  # capture legal), and the capture. `{sans, ply of the promotion | nil}`.
  defp taken_at_once(_pos, sans, %{promotion_capture: nil}), do: {sans, nil}

  defp taken_at_once(pos, sans, o) do
    sans
    |> Enum.with_index(1)
    |> Enum.reduce_while({pos, []}, fn {san, number}, {pos, acc} ->
      {:ok, move} = Chess.parse_san(pos, san)

      with promo when promo != nil <- move.promo,
           {made, capture} <- promoted_and_taken(pos, move, promote_as(o)) do
        after_it = Chess.apply_move(pos, made)
        line = Enum.reverse(acc) ++ [Chess.san(pos, made), Chess.san(after_it, capture)]
        {:halt, {:done, line, number}}
      else
        _plain -> {:cont, {Chess.apply_move(pos, move), [san | acc]}}
      end
    end)
    |> case do
      {:done, line, number} -> {line, number}
      {_pos, _acc} -> {sans, nil}
    end
  end

  # `:cycle`: a piece for each seed, so that a matrix of games has all four.
  defp promote_as(%{promote_as: :cycle, seed: seed}),
    do: Enum.at([:q, :r, :b, :n], :erlang.phash2(seed, 4))

  defp promote_as(o), do: o.promote_as

  defp promoted_and_taken(pos, move, as) do
    Enum.find_value([as, move.promo], fn piece ->
      made =
        Enum.find(
          Chess.legal_moves(pos),
          &(&1.from == move.from and &1.to == move.to and &1.promo == piece)
        )

      next = made && Chess.apply_move(pos, made)

      captures =
        if next,
          do:
            next
            |> Chess.legal_moves()
            |> Enum.filter(&(&1.to == move.to))
            |> Enum.sort_by(&Chess.san(next, &1)),
          else: []

      case captures do
        [first | _] -> {made, first}
        [] -> nil
      end
    end)
  end

  # --- one ply -----------------------------------------------------------------

  defp ply(st, pos, move, number) do
    o = st.o
    st = maybe_die(st, number)

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
      cond do
        st.derailed -> {o.long_think_ms, st}
        # The new piece is taken before it has stood a quarter of a second.
        quick_capture?(st, number) -> between(st, {10, 60})
        true -> between(st, o.think_ms)
      end

    st = wait(st, think)

    st =
      cond do
        o.out_of_turn_at == number -> st |> note(number, :out_of_turn) |> out_of_turn(pos)
        o.illegal_back_at == number -> st |> note(number, :illegal_back) |> illegal(pos, :back)
        true -> st
      end

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
        st =
          st
          |> see_again(number)
          |> maybe_hide(number)
          |> straighten(move, number)
          |> crosstalk(number)

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

  # The `:between` fault: the squares next to where the move really went on
  # which the board could read the piece instead - empty, and a legal move
  # of the same piece too, or the tracker would not be fooled for a moment.
  defp beside(pos, move, board) do
    for other <- Chess.legal_moves(pos),
        other.from == move.from and other.to != move.to,
        other.kind in [:normal, :double] and other.capture == nil and other.promo == nil,
        elem(board, other.to) == nil,
        abs(rem(other.to, 8) - rem(move.to, 8)) <= 1 and
          abs(div(other.to, 8) - div(move.to, 8)) <= 1,
        do: other.to
  end

  # A crooked piece is put straight after a few plies, or before a move
  # that lands where the board reads it: nobody plays onto a square that
  # looks taken.
  defp straighten(%{crooked: nil} = st, _move, _number), do: st

  defp straighten(%{crooked: crooked} = st, move, number) do
    cond do
      elem(st.b, crooked.real) != crooked.piece ->
        %{st | crooked: nil}

      number >= crooked.until or move.to == crooked.shown ->
        %{st | crooked: nil} |> emit({:position, st.b}) |> pause()

      true ->
        st
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

  # --- crosstalk -----------------------------------------------------------------

  # What is heard instead of a piece in the band beside its own.
  @mistyped %{
    p: [:r],
    r: [:p, :n],
    n: [:r, :b],
    b: [:n, :k],
    k: [:b, :q],
    q: [:k]
  }

  defp crosstalk(st, number) do
    st = fade(st, number)
    {mask?, st} = chance(st, :mask)
    {mistype?, st} = chance(st, :mistype)
    st = if mask?, do: cross(st, number, :mask), else: st
    if mistype?, do: cross(st, number, :mistype), else: st
  end

  # Lasting crosstalk ends with the ply it was for, when its piece has been
  # lifted, or when nothing stands beside it any more.
  defp fade(%{crosstalk: []} = st, _number), do: st

  defp fade(st, number) do
    {gone, kept} =
      Enum.split_with(st.crosstalk, fn entry ->
        elem(st.b, entry.square) != entry.piece or neighbours(st.b, entry.square) == [] or
          (entry.until != nil and number > entry.until)
      end)

    if gone == [], do: st, else: %{st | crosstalk: kept} |> emit({:position, st.b}) |> pause()
  end

  defp cross(st, number, fault) do
    taken = Enum.map(st.crosstalk, & &1.square)
    squares = for sq <- occupied(st.b), sq not in taken, neighbours(st.b, sq) != [], do: sq

    if squares == [] do
      st
    else
      {square, st} = pick(st, squares)
      {colour, kind} = piece = elem(st.b, square)

      {as, st} =
        if fault == :mask do
          {nil, st}
        else
          {other, st} = pick(st, Map.fetch!(@mistyped, kind))
          {{colour, other}, st}
        end

      {lasting, st} = pick(st, [false, true])
      entry = %{square: square, piece: piece, as: as, until: nil}
      st = note(st, number, fault)

      cond do
        lasting and fault == :mask ->
          # Until the next ply begins: through this ply's move.
          %{st | crosstalk: [%{entry | until: number} | st.crosstalk]}
          |> emit({:position, st.b})
          |> pause()

        lasting ->
          %{st | crosstalk: [entry | st.crosstalk]} |> emit({:position, st.b}) |> pause()

        true ->
          {dt, st} = between(st, {100, 700})
          was = st.crosstalk

          %{st | crosstalk: [entry | was]}
          |> emit({:position, st.b})
          |> wait(dt)
          |> Map.put(:crosstalk, was)
          |> emit({:position, st.b})
          |> pause()
      end
    end
  end

  defp neighbours(board, square) do
    {file, rank} = {rem(square, 8), div(square, 8)}

    for df <- -1..1,
        dr <- -1..1,
        {df, dr} != {0, 0},
        f = file + df,
        r = rank + dr,
        f in 0..7 and r in 0..7,
        elem(board, r * 8 + f) != nil,
        do: r * 8 + f
  end

  # The `:dead_square` fault: from this ply the square reads what `emit/2`
  # makes it read.
  defp maybe_die(%{o: %{dead_square: {at, kind}}, dead: nil} = st, number) when at == number do
    {board, _} = Enum.at(st.positions, number - 1)
    later = st.positions |> Enum.drop(number - 1) |> Enum.map(&elem(&1, 1))
    used = later |> Enum.flat_map(&[&1.from, &1.to]) |> Enum.frequencies()

    squares =
      for {sq, n} <- Enum.sort(used),
          n >= 2,
          kind == :off or leaves?(board, sq, later),
          do: sq

    if squares == [] do
      st
    else
      {square, st} = pick(st, squares)
      reading = if kind == :off, do: nil, else: elem(board, square)
      st = %{st | dead: %{square: square, reading: reading}}
      st |> note(number, :dead_square) |> emit({:position, st.b})
    end
  end

  defp maybe_die(st, _number), do: st

  # A piece stands on the square now, and the first move to touch it takes
  # it away (and not, say, captures it, which a stuck square shows exactly
  # as it should).
  defp leaves?(board, square, later) do
    elem(board, square) != nil and
      match?(%{from: ^square}, Enum.find(later, &(&1.from == square or &1.to == square)))
  end

  defp positions(pos, sans) do
    {list, _pos} =
      Enum.map_reduce(sans, pos, fn san, pos ->
        {:ok, move} = Chess.parse_san(pos, san)
        {{pos.board, move}, Chess.apply_move(pos, move)}
      end)

    list
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
        {leave?, st} =
          cond do
            not faults? -> {false, st}
            number == st.taken_at -> {st.o.promotion_capture == :pawn_left, st}
            promo == :q -> chance(st, :leave_pawn)
            # Drawn apart from the game's other chances, so that every game
            # without one plays exactly as it did when only queens were left.
            true -> {aside(st, number, :leave_pawn), st}
          end

        off = if move.capture, do: [{:lift, move.to}], else: []

        {order, st} =
          if quick_capture?(st, number + 1),
            do: {:quick, st},
            else: pick(st, [:swap_in_hand, :pawn_then_piece])

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

          # The new piece is at hand, and so is the hand that takes it.
          order == :quick ->
            st
            |> steps([{:lift, move.from}] ++ off)
            |> pause()
            |> steps([{:put, move.to, {us, promo}}], {20, 60})

          true ->
            st
            |> steps([{:lift, move.from}] ++ off ++ [{:put, move.to, piece}])
            |> pause({300, 1_500})
            |> steps([{:lift, move.to}, {:put, move.to, {us, promo}}])
        end

      %{capture: capture} when capture != nil ->
        {order, st} = pick(st, [:off_first, :lift_first, :replace])
        range = if quick_capture?(st, number), do: {20, 80}

        case order do
          :off_first ->
            steps(st, [{:lift, move.to}, {:lift, move.from}, {:put, move.to, piece}], range)

          :lift_first ->
            steps(st, [{:lift, move.from}, {:lift, move.to}, {:put, move.to, piece}], range)

          :replace ->
            steps(st, [{:lift, move.from}, {:put, move.to, piece}], range)
        end

      _quiet ->
        {slide?, st} = if faults?, do: chance(st, :slide), else: {false, st}
        via = if slide?, do: between_squares(move), else: []
        {crooked?, st} = if faults? and via == [], do: chance(st, :between), else: {false, st}
        beside = if crooked? and st.crooked == nil, do: beside(pos, move, st.b), else: []

        case {via, beside} do
          {[], [_ | _]} ->
            # Set down between two squares: the board reads the neighbour.
            {shown, st} = pick(st, beside)
            {plies, st} = between(st, st.o.between_plies)
            st = st |> note(number, :between) |> steps([{:lift, move.from}])

            st = %{
              st
              | crooked: %{real: move.to, shown: shown, piece: piece, until: number + plies}
            }

            steps(st, [{:put, move.to, piece}])

          {[], []} ->
            steps(st, [{:lift, move.from}, {:put, move.to, piece}])

          {squares, _beside} ->
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
  defp illegal(st, pos, back \\ nil) do
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
    st = steps(st, [{:lift, from}, {:put, to, piece}])

    if back do
      # Long enough to be noticed, and then put right: FIDE takes an
      # illegal move back.
      st |> pause({4_000, 10_000}) |> steps([{:lift, to}, {:put, from, piece}]) |> pause()
    else
      st
    end
  end

  # A legal move by the side that is NOT to move: the player who has just
  # moved moves again. It stands a while and is taken back.
  defp out_of_turn(st, pos) do
    theirs = %{pos | turn: other(pos.turn), ep: nil}

    quiet =
      for m <- Chess.legal_moves(theirs), m.kind in [:normal, :double], m.capture == nil, do: m

    case quiet do
      [] ->
        st

      moves ->
        {move, st} = pick(st, moves)
        piece = elem(st.b, move.from)

        st
        |> steps([{:lift, move.from}, {:put, move.to, piece}])
        |> pause({4_000, 10_000})
        |> steps([{:lift, move.to}, {:put, move.from, piece}])
        |> pause()
    end
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

  # Taken before it could settle: the promotion's own press did not come
  # in time to say so.
  defp maybe_press(%{taken_at: at, o: %{promotion_capture: :quick}} = st, pos, number)
       when at == number,
       do: silent_press(st, pos)

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

  defp quick_capture?(st, number),
    do: st.o.promotion_capture == :quick and st.taken_at != nil and number == st.taken_at + 1

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

  # Crosstalk is in the reading of whatever else is wrong with it: the
  # board as the rest makes it read, then the pieces heard otherwise -
  # for as long as each still stands there and has a neighbour.
  defp emit(%{crosstalk: [_ | _] = talk} = st, {:position, board}) do
    %{ev: [{t, {:position, read}} | rest]} = st = emit(%{st | crosstalk: []}, {:position, board})

    read =
      Enum.reduce(talk, read, fn %{square: square, piece: piece, as: as}, read ->
        if elem(board, square) == piece and elem(read, square) == piece and
             neighbours(board, square) != [],
           do: put_elem(read, square, as),
           else: read
      end)

    %{st | crosstalk: talk, ev: [{t, {:position, read}} | rest]}
  end

  defp emit(%{dead: %{square: square, reading: reading} = dead} = st, {:position, board}) do
    st = emit(%{st | dead: nil}, {:position, put_elem(board, square, reading)})
    %{st | dead: dead}
  end

  defp emit(%{hidden: %{square: square, piece: piece}} = st, {:position, board})
       when elem(board, square) == piece,
       do: %{st | ev: [{st.t, {:position, put_elem(board, square, nil)}} | st.ev]}

  # A crooked piece is read on the square beside its own - for as long as
  # it stands there and nothing else stands where it is read.
  defp emit(%{crooked: %{real: real, shown: shown, piece: piece}} = st, {:position, board})
       when elem(board, real) == piece and elem(board, shown) == nil do
    board = board |> put_elem(real, nil) |> put_elem(shown, piece)
    %{st | ev: [{st.t, {:position, board}} | st.ev]}
  end

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

  # A chance that does not draw on the game's stream: decided by the seed
  # and the ply alone.
  defp aside(st, number, fault) do
    rate = Map.get(st.o.faults, fault, 0)
    rate > 0 and :erlang.phash2({st.o.seed, number, fault}, 1_000_000) < rate * 1_000_000
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
