defmodule Alnasl.TrackerTest do
  @moduledoc """
  The tracker, one situation at a time: what a hand does to a board, written
  out square by square, and what the tracker must and must not make of it.
  The fault matrix (`tracker_matrix_test.exs`) is the same thing in bulk.
  """

  use ExUnit.Case, async: true

  alias Alnasl.{Chess, Position, Tracker}

  # --- a small language for boards ---------------------------------------------

  defp board(fen), do: Position.from_fen(fen)
  defp sq(name), do: Position.square_index(name)
  defp lift(board, square), do: put_elem(board, sq(square), nil)
  defp put(board, square, piece), do: put_elem(board, sq(square), piece)

  defp move(board, from, to) do
    board |> put(to, elem(board, sq(from))) |> lift(from)
  end

  # Feeds `[{t, board}]` and ticks at every deadline in between and for
  # `tail` ms after. Returns the tracker and all events with their times.
  defp feed(tr, timed, tail \\ 70_000) do
    {tr, out, last} =
      Enum.reduce(timed, {tr, [], 0}, fn {t, what}, {tr, out, _last} ->
        {tr, out} = ticks(tr, t, out)

        {tr, events} =
          case what do
            :press -> Tracker.press(tr, t)
            {:presses, n} -> tr |> Tracker.presses(n, t) |> Tracker.press(t)
            board -> Tracker.observe(tr, t, board)
          end

        {tr, out ++ Enum.map(events, &{t, &1}), t}
      end)

    {tr, out} = ticks(tr, last + tail, out)
    {tr, out}
  end

  defp ticks(tr, until, out) do
    case Tracker.deadline(tr) do
      due when is_integer(due) and due < until ->
        {tr, events} = Tracker.tick(tr, due)
        ticks(tr, until, out ++ Enum.map(events, &{due, &1}))

      _none ->
        {tr, out}
    end
  end

  defp started do
    {tr, _} = Tracker.observe(Tracker.new(), 0, Position.start())
    tr
  end

  # A tracker that has seen `sans` played cleanly, and the board after them.
  defp after_moves(sans) do
    {:ok, plies} = Chess.replay(Chess.start_fen(), sans)
    boards = Enum.map(plies, &board(&1.fen))
    timed = boards |> Enum.with_index(1) |> Enum.map(fn {b, i} -> {i * 5_000, b} end)
    {tr, _} = feed(started(), timed, 1_000)
    assert Tracker.sans(tr) == sans
    {tr, List.last(boards) || Position.start(), length(sans) * 5_000 + 1_000}
  end

  defp alarms(out), do: for({_t, {:status, :out_of_sync, why}} <- out, do: why)
  defp moves(out), do: for({_t, {:moves, plies}} <- out, ply <- plies, do: ply.san)

  # --- the plain cases ---------------------------------------------------------

  test "the start position is waited for, then a move is a move" do
    tr = Tracker.new()
    assert tr.status == :waiting_start
    {tr, events} = Tracker.observe(tr, 0, Position.start())
    assert {:status, :waiting_start, :ready} in events

    b = Position.start()
    {tr, out} = feed(tr, [{1_000, lift(b, "e2")}, {1_300, move(b, "e2", "e4")}])
    assert Tracker.sans(tr) == ["e4"]
    assert tr.status == :live

    assert [{1_550, {:moves, [%{san: "e4", flags: []}]}} | _] =
             Enum.filter(out, &match?({_, {:moves, _}}, &1))
  end

  test "a piece in the air is not a move, and not an alarm until it has been gone a long time" do
    b = Position.start()
    {tr, out} = feed(started(), [{1_000, lift(b, "g1")}, {9_000, b}], 1_000)
    assert Tracker.sans(tr) == []
    assert alarms(out) == []

    {tr, _, t} = after_moves(~w(e4 e5))
    b = tr.raw
    {tr, out} = feed(tr, [{t, lift(b, "g1")}], 61_000)
    assert Tracker.sans(tr) == ~w(e4 e5)
    assert alarms(out) == [:piece_missing]

    # ...and it clears itself when the piece is back.
    {tr, out} = feed(tr, [{t + 62_000, b}], 1_000)
    assert tr.status == :live
    assert {:status, :live, nil} in Enum.map(out, &elem(&1, 1))
  end

  test "a clock press accepts a move before it has settled" do
    b = Position.start()
    {tr, out} = feed(started(), [{1_000, move(b, "e2", "e4")}, {1_050, :press}], 0)

    assert [{1_050, {:moves, [%{san: "e4"}]}} | _] =
             Enum.filter(out, &match?({_, {:moves, _}}, &1))

    assert tr.status == :live
  end

  test "a capture in either order is one move" do
    {tr, b, t} = after_moves(~w(e4 d5))

    off_first = [
      {t, lift(b, "d5")},
      {t + 900, b |> lift("d5") |> lift("e4")},
      {t + 1_400, move(b, "e4", "d5")}
    ]

    {tr1, out} = feed(tr, off_first)
    assert Tracker.sans(tr1) == ~w(e4 d5 exd5)
    assert alarms(out) == []

    lift_first = [
      {t, lift(b, "e4")},
      {t + 900, b |> lift("d5") |> lift("e4")},
      {t + 1_400, move(b, "e4", "d5")}
    ]

    {tr2, out} = feed(tr, lift_first)
    assert Tracker.sans(tr2) == ~w(e4 d5 exd5)
    assert alarms(out) == []
  end

  test "castling is one move whichever piece goes first, and a rook move is held while it could be half of it" do
    {tr, b, t} = after_moves(~w(e4 e5 Nf3 Nc6 Bc4 Bc5))
    castled = b |> move("e1", "g1") |> move("h1", "f1")

    king_first = [{t, move(b, "e1", "g1")}, {t + 1_200, castled}]
    {tr1, out} = feed(tr, king_first)
    assert List.last(Tracker.sans(tr1)) == "O-O"
    assert moves(out) == ["O-O"]

    rook_first = [{t, move(b, "h1", "f1")}, {t + 2_000, castled}]
    {tr2, out} = feed(tr, rook_first)
    assert moves(out) == ["O-O"], "the rook move alone must not be emitted inside the castle hold"
    assert List.last(Tracker.sans(tr2)) == "O-O"

    # A rook move that stays a rook move is believed after the hold.
    {tr3, out} = feed(tr, [{t, move(b, "h1", "f1")}])
    assert List.last(Tracker.sans(tr3)) == "Rf1"
    assert [{at, _}] = Enum.filter(out, &match?({_, {:moves, _}}, &1))
    assert at == t + tr.opts.castle_hold_ms

    # ...and if the king follows after all, the rook move is replaced.
    {tr4, out} = feed(tr, [{t, move(b, "h1", "f1")}, {t + 4_000, castled}])
    assert List.last(Tracker.sans(tr4)) == "O-O"
    assert Enum.any?(out, &match?({_, {:correction, 6, [%{san: "O-O"}], :revised}}, &1))
  end

  test "en passant, pawn first or captured pawn first" do
    {tr, b, t} = after_moves(~w(e4 a6 e5 d5))
    done = b |> move("e5", "d6") |> lift("d5")

    {tr1, out} = feed(tr, [{t, move(b, "e5", "d6")}, {t + 1_500, done}])
    assert List.last(Tracker.sans(tr1)) == "exd6"
    assert alarms(out) == []

    {tr2, _} = feed(tr, [{t, lift(b, "d5")}, {t + 1_500, done}])
    assert List.last(Tracker.sans(tr2)) == "exd6"
  end

  # --- promotion ---------------------------------------------------------------

  @promo "8/4P1k1/8/8/8/8/6K1/8 w - - 0 1"

  defp promo_tracker do
    {tr, _} = Tracker.observe(Tracker.new(start_fen: @promo), 0, board(@promo))
    {tr, board(@promo)}
  end

  test "the promotion piece is read from the board, underpromotion included" do
    {tr, b} = promo_tracker()
    gone = lift(b, "e7")

    {tr1, _} = feed(tr, [{1_000, gone}, {3_000, put(gone, "e8", {:w, :q})}])
    assert [%{san: "e8=Q", flags: []}] = tr1.plies

    {tr2, _} = feed(tr, [{1_000, gone}, {3_000, put(gone, "e8", {:w, :n})}])
    assert [%{san: "e8=N+", flags: []}] = tr2.plies
  end

  test "a pawn left on the last rank is the default piece, flagged, and corrected when another is placed" do
    {tr, b} = promo_tracker()
    pawn = move(b, "e7", "e8")

    {tr, out} = feed(tr, [{1_000, pawn}], 5_000)
    assert [%{san: "e8=Q", flags: [:assumed]}] = tr.plies
    assert [{at, _}] = Enum.filter(out, &match?({_, {:moves, _}}, &1))
    assert at == 1_000 + tr.opts.promotion_hold_ms

    # The pawn is swapped for a queen: nothing to report.
    queen = put(pawn, "e8", {:w, :q})
    {tr_q, out} = feed(tr, [{8_000, lift(pawn, "e8")}, {8_500, queen}], 2_000)
    assert Tracker.sans(tr_q) == ["e8=Q"]
    assert Enum.filter(out, &match?({_, {:correction, _, _, _}}, &1)) == []
    assert tr_q.status == :live

    # ...or for a knight: the move is rewritten.
    knight = put(pawn, "e8", {:w, :n})
    {tr_n, out} = feed(tr, [{8_000, lift(pawn, "e8")}, {8_500, knight}], 2_000)
    assert Tracker.sans(tr_n) == ["e8=N+"]
    assert Enum.any?(out, &match?({_, {:correction, 0, [%{san: "e8=N+"}], :promotion}}, &1))
  end

  test "the pawn standing in for a queen keeps moving as a queen" do
    {tr, b} = promo_tracker()
    pawn = move(b, "e7", "e8")
    {tr, _} = feed(tr, [{1_000, pawn}], 5_000)
    black = move(pawn, "g7", "h7")
    white = move(black, "e8", "e4")
    {tr, out} = feed(tr, [{10_000, black}, {15_000, white}], 2_000)
    assert Tracker.sans(tr) == ["e8=Q", "Kh7", "Qe4+"]
    assert alarms(out) == []
  end

  # --- takebacks and second thoughts -------------------------------------------

  test "a move taken back is a correction, not an alarm" do
    {tr, b, t} = after_moves(~w(e4 e5))
    played = move(b, "g1", "f3")
    {tr, out} = feed(tr, [{t, played}, {t + 3_000, b}], 3_000)
    assert Tracker.sans(tr) == ~w(e4 e5)
    assert Enum.any?(out, &match?({_, {:correction, 2, [], :takeback}}, &1))
    assert alarms(out) == []
  end

  test "takebacks can be switched off" do
    {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4))
    b1 = board(hd(plies).fen)
    {tr, _} = Tracker.observe(Tracker.new(takeback: false), 0, Position.start())
    {tr, out} = feed(tr, [{1_000, b1}, {5_000, Position.start()}], 20_000)
    assert Tracker.sans(tr) == ["e4"]
    refute Enum.any?(out, &match?({_, {:correction, _, _, _}}, &1))
    # A pawn that goes backwards is a move that is not one.
    assert [{:illegal, %{piece: {:w, :p}, why: :shape}}] = alarms(out)
  end

  test "a piece that rests on a square on its way replaces its own move" do
    {tr, b, t} = after_moves(~w(e4 e5 Bc4 Nc6))
    {tr, out} = feed(tr, [{t, move(b, "d1", "f3")}, {t + 1_000, move(b, "d1", "h5")}], 2_000)
    assert List.last(Tracker.sans(tr)) == "Qh5"
    assert length(tr.plies) == 5
    assert Enum.any?(out, &match?({_, {:correction, 4, [%{san: "Qh5"}], :revised}}, &1))
  end

  test "a position that repeats is not a takeback when legal moves explain it" do
    # Knights out and back, the second pair unseen: the board reads as it did
    # two plies ago.
    {tr, b, t} = after_moves(~w(Nf3 Nf6 Ng1))
    start = move(b, "f6", "g8")
    assert start == Position.start()
    {tr, _} = feed(tr, [{t, start}], 2_000)
    assert Tracker.sans(tr) == ~w(Nf3 Nf6 Ng1 Ng8)

    {tr, b, t} = after_moves(~w(Nf3 Nf6))
    assert b != Position.start()
    {tr, out} = feed(tr, [{t, Position.start()}], 3_000)
    assert Tracker.sans(tr) == ~w(Nf3 Nf6 Ng1 Ng8)
    assert Enum.all?(Enum.take(tr.plies, -2), &(:recovered in &1.flags))
    refute Enum.any?(out, &match?({_, {:correction, _, _, :takeback}}, &1))
  end

  # --- moves that went by unseen -----------------------------------------------

  test "two moves at once are found and flagged" do
    {tr, b, t} = after_moves(~w(e4))
    both = b |> move("e7", "e5") |> move("g1", "f3")
    {tr, out} = feed(tr, [{t, both}], 1_000)
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3)
    assert [%{flags: [:recovered]}, %{flags: [:recovered]}] = Enum.take(tr.plies, -2)
    assert alarms(out) == []
  end

  test "a board that starts late is caught up from the start position when it is two moves in" do
    {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4 e5))
    {tr, _} = feed(Tracker.new(), [{0, board(List.last(plies).fen)}], 6_000)
    assert Tracker.sans(tr) == ~w(e4 e5)
    assert Enum.all?(tr.plies, &(:recovered in &1.flags))
  end

  test "three moves in, before any move was seen, is pieces being set up - until the clock or the arbiter says a game is on" do
    {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4 e5 Qh5))
    seen = board(List.last(plies).fen)
    assert Tracker.defaults().search_depth == 8

    {tr, out} = feed(Tracker.new(), [{0, seen}], 6_000)
    assert Tracker.sans(tr) == []
    assert alarms(out) == []

    # "Resync from the board" on the board's page: one path, and it is told.
    {resynced, _events, {:accepted, ~w(e4 e5 Qh5)}} = Tracker.resync(tr, 7_000, 6)
    assert Tracker.sans(resynced) == ~w(e4 e5 Qh5)
    assert Enum.all?(resynced.plies, &(:recovered in &1.flags and :arbiter in &1.flags))

    # A clock pressed over a board that stood ready: the game is on, and
    # the three moves are worked out.
    {tr, out} = feed(started(), [{1_000, seen}, {1_500, :press}], 10_000)
    assert Tracker.sans(tr) == ~w(e4 e5 Qh5)
    # Three at once, and no hole in contact: nothing says "gap".
    assert Enum.all?(tr.plies, &(&1.flags == [:recovered]))
    assert alarms(out) == []
  end

  test "moves that went by unseen while the game was on are reconstructed, one path orange" do
    {tr, _b, t} = after_moves(~w(e4 e5))
    {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4 e5 Nf3 Nc6 Nxe5))
    # Nothing was seen of them (f3 never read as anything but empty), so
    # the board must stand before three moves are believed of it.
    {early, _} = feed(tr, [{t, board(List.last(plies).fen)}], 4_000)
    assert Tracker.sans(early) == ~w(e4 e5)
    {tr, out} = feed(tr, [{t, board(List.last(plies).fen)}], 6_000)

    assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6 Nxe5)
    assert alarms(out) == []
    assert tr.status == :live

    assert [[:recovered], [:recovered], [:recovered]] =
             tr.plies |> Enum.take(-3) |> Enum.map(& &1.flags)

    # Switched down to nothing in Setup, the board waits and is the alarm.
    {tr, _b, t} = after_moves(~w(e4 e5))
    tr = %{tr | opts: %{tr.opts | search_depth: 2, blind_depth: 2}}
    {tr, out} = feed(tr, [{t, board(List.last(plies).fen)}], 10_000)
    assert Tracker.sans(tr) == ~w(e4 e5)
    assert alarms(out) == [:unexplained]
  end

  test "moves that were seen one by one, but not believed in time, are put in the order they were seen" do
    # After 1. e4 e5 somebody lifts the a2 pawn off the board and keeps it
    # (the unseen-piece rule switched off, so that the board is stuck):
    # 2. Nf3 Nc6 3. Bc4 Nf6 are played, each read as it lands, and the pawn
    # is put back. Four moves to find; White's two could have been played
    # in either order and so could Black's - the readings say which.
    {tr, b, t} = after_moves(~w(e4 e5))
    tr = %{tr | opts: %{tr.opts | unseen_piece: false}}
    gone = lift(b, "a2")
    n1 = move(gone, "g1", "f3")
    n2 = move(n1, "b8", "c6")
    n3 = move(n2, "f1", "c4")
    n4 = move(n3, "g8", "f6")
    back = put(n4, "a2", {:w, :p})

    steps = [{t, gone}, {t + 3_000, n1}, {t + 6_000, n2}, {t + 9_000, n3}, {t + 12_000, n4}]
    {tr, out} = feed(tr, steps ++ [{t + 15_000, back}], 1_000)

    assert Enum.drop(Tracker.sans(tr), 2) == ~w(Nf3 Nc6 Bc4 Nf6)
    assert alarms(out) == []
    # More than one order is legal: a guess, marked as one - and the right one.
    assert Enum.all?(Enum.take(tr.plies, -4), &(:guessed in &1.flags))

    %{options: [current | others]} = Tracker.alternatives(tr, 4)
    assert current == ~w(Nf3 Nc6 Bc4 Nf6)
    assert ~w(Nf3 Nf6 Bc4 Nc6) in others
  end

  test "a piece in a hand beside a move that went by unseen is not a capture" do
    # 1. e4 e5 2. Nf3 went by unseen, and Black has the knight from b8 in
    # his hand: the board reads "knight on f3, b8 empty". Nothing takes on
    # b8 in a game of chess that early, but Ng1-f3-e5-c6xb8 and back is
    # legal with a few black moves in between. It is waited for.
    {tr, b, t} = after_moves(~w(e4 e5))
    unseen = move(b, "g1", "f3")
    {tr, out} = feed(tr, [{t, lift(unseen, "b8")}, {t + 900, move(unseen, "b8", "c6")}], 1_000)
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6)
    assert [[:recovered], [:recovered]] = tr.plies |> Enum.take(-2) |> Enum.map(& &1.flags)
    assert length(for({_, {:moves, _}} <- out, do: 1)) == 1
  end

  test "more clock presses than moves: the shortest path is not the whole story" do
    # 1. e4 e5, then unseen: 2. Bc4 a6 3. Bb5. The board reads as if the
    # bishop went to b5 in one move and Black played ...a6: two plies. The
    # clock was pressed six times (one may be the lever that started it).
    {tr, _b, t} = after_moves(~w(e4 e5))
    {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4 e5 Bc4 a6 Bb5))
    seen = board(List.last(plies).fen)

    {short, _} = feed(tr, [{t, seen}], 1_000)
    assert Enum.drop(Tracker.sans(short), 2) == ~w(Bb5 a6)

    {same, _} = feed(Tracker.presses(tr, 5), [{t, seen}], 1_000)
    assert Tracker.sans(same) == Tracker.sans(short)

    {long, _} = feed(Tracker.presses(tr, 6), [{t, seen}], 1_000)
    assert length(Tracker.sans(long)) == 5
    assert Enum.all?(Enum.take(long.plies, -3), &(:guessed in &1.flags))
    assert %{options: options} = Tracker.alternatives(long, 3)
    assert ~w(Bc4 a6 Bb5) in options
  end

  # --- fast play ---------------------------------------------------------------

  test "the next hand on the board makes the move: accepted at once, long before it has settled" do
    b = Position.start()
    e4 = move(b, "e2", "e4")

    {tr, out} =
      feed(
        started(),
        [
          {1_000, lift(b, "e2")},
          {1_080, e4},
          # 60 ms later Black's hand has the e-pawn.
          {1_140, lift(e4, "e7")},
          {1_200, move(e4, "e7", "e5")},
          # And White's knight is in the air 50 ms after that.
          {1_250, e4 |> move("e7", "e5") |> lift("g1")}
        ],
        0
      )

    assert [{1_140, {:moves, [%{san: "e4", flags: []}]}}, {1_250, {:moves, [%{san: "e5"}]}}] =
             Enum.filter(out, &match?({_, {:moves, _}}, &1))

    assert Tracker.sans(tr) == ~w(e4 e5)
    assert Enum.all?(tr.plies, &(&1.flags == []))
    assert alarms(out) == []
  end

  test "the piece that moved, lifted again, is not the next hand" do
    # A rook resting on d1 on its way to d5, a move being taken back, the
    # recapture: all of them lift the piece from where it landed.
    {tr, b, t} = after_moves(~w(e4 e5 Nf3 Nc6))
    bb5 = move(b, "f1", "b5")
    {tr, out} = feed(tr, [{t, lift(b, "f1")}, {t + 80, bb5}, {t + 160, lift(bb5, "b5")}], 0)
    assert moves(out) == []
    {tr, _out} = feed(tr, [{t + 240, move(b, "f1", "c4")}], 1_000)
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6 Bc4)
  end

  test "a rook on its castling square and the king in the air is castling, not a rook move and a hand" do
    {tr, b, t} = after_moves(~w(e4 e5 Nf3 Nc6 Bc4 Bc5))
    rook = move(b, "h1", "f1")

    {tr, out} =
      feed(
        tr,
        [
          {t, lift(b, "h1")},
          {t + 60, rook},
          {t + 120, lift(rook, "e1")},
          {t + 200, move(rook, "e1", "g1")},
          # Black's hand, at once.
          {t + 260, rook |> move("e1", "g1") |> lift("g8")}
        ],
        0
      )

    assert moves(out) == ["O-O"]
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6 Bc4 Bc5 O-O)
  end

  test "pieces that were off the board before the move are not a hand" do
    # A capture and its recapture went by unseen (both h-pawns are gone,
    # a pawn stands on g6 as before); then a move is made. The move is not
    # believed by itself over a position that is not the board's.
    {tr, _b, t} = after_moves(~w(h4 g6 h5 Nf6))
    {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(h4 g6 h5 Nf6 hxg6 hxg6))
    exchanged = board(List.last(plies).fen)
    {still, out} = feed(tr, [{t, exchanged}], 0)
    assert moves(out) == [] and still.status == :settling

    # Stood for a moment, it is searched and found: two moves, flagged.
    {tr, out} = feed(tr, [{t, exchanged}], 1_000)
    assert moves(out) == ~w(hxg6 hxg6)
    assert [%{flags: [:recovered]}, %{flags: [:recovered]}] = Enum.take(tr.plies, -2)
    assert alarms(out) == []
  end

  test "a capturer and its victim both in the air are a capture half made, and are waited for" do
    {tr, b, t} = after_moves(~w(e4 d5))
    both = b |> lift("e4") |> lift("d5")
    {tr, out} = feed(tr, [{t, lift(b, "e4")}, {t + 100, both}], 5_000)
    assert moves(out) == [] and alarms(out) == []
    assert tr.status == :settling
    {tr, _} = feed(tr, [{t + 5_200, put(both, "d5", {:w, :p})}], 1_000)
    assert Tracker.sans(tr) == ~w(e4 d5 exd5)
  end

  test "a game that began unseen is an alarm once the clock is pressed, not pieces being set up" do
    {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4 e5 Nf3))
    seen = board(List.last(plies).fen)

    # Without a press: pieces not in the starting position. No alarm, ever.
    {tr, out} = feed(started(), [{1_000, seen}], 60_000)
    assert tr.status == :waiting_start and alarms(out) == []

    # With one: the game is on, and the box did not see how. What the
    # board shows is three legal moves from the start, so those are them.
    {tr, out} = feed(started(), [{1_000, seen}, {1_500, :press}], 60_000)
    assert tr.status == :live and alarms(out) == []
    # ...in one of the orders they can have been played in: nobody saw.
    assert Enum.sort(Tracker.sans(tr)) == Enum.sort(~w(e4 e5 Nf3))
    assert Enum.all?(tr.plies, &(:guessed in &1.flags))
    assert %{options: options} = Tracker.alternatives(tr, 1)
    assert ~w(e4 e5 Nf3) in options

    # A board that left the start for something no game leads to: the alarm.
    mess =
      Position.start() |> lift("e2") |> lift("d2") |> put("e5", {:w, :p}) |> put("d6", {:w, :p})

    {tr, out} = feed(started(), [{1_000, mess}, {1_500, :press}], 60_000)
    assert tr.status == :out_of_sync and alarms(out) == [:unexplained]
    assert Tracker.sans(tr) == []

    # Set up again, it waits for the start as if nothing had happened.
    {tr, _out} = feed(tr, [{80_000, Position.start()}], 1_000)
    assert tr.status == :waiting_start and tr.detail == :ready

    # A board that never stood in the starting position is still being set
    # up, clock or no clock (the real board's first recording: one knight).
    knight = nil |> Tuple.duplicate(64) |> put("d6", {:b, :n})
    {tr, out} = feed(Tracker.new(), [{0, knight}, {500, :press}], 60_000)
    assert tr.status == :waiting_start and alarms(out) == []
  end

  test "a press confirms the move on the board only when it is that move's press" do
    alias Alnasl.Session
    clock = fn running -> {:clock, %{white_ms: 60_000, black_ms: 60_000, running: running}} end
    plies = fn session -> Tracker.sans(session.tracker) end
    b = Position.start()
    e4 = move(b, "e2", "e4")
    e5 = move(e4, "e7", "e5")

    session =
      Enum.reduce(
        [
          {0, {:position, b}},
          {0, clock.(:white)},
          {1_000, {:position, lift(b, "e2")}},
          {1_060, {:position, e4}},
          {1_120, {:position, lift(e4, "e7")}},
          {1_180, {:position, e5}}
        ],
        Session.new([]),
        fn {t, event}, session -> session |> Session.handle(t, event) |> elem(0) end
      )

    assert plies.(session) == ~w(e4)

    # White's press, told by the clock when Black's pawn is already down:
    # it is not Black's press, and e5 has stood for 20 ms.
    {session, _} = Session.handle(session, 1_200, clock.(:black))
    assert plies.(session) == ~w(e4)

    # Black's own.
    {session, _} = Session.handle(session, 1_260, clock.(:white))
    assert plies.(session) == ~w(e4 e5)
  end

  test "the fast-play preset is what Setup's button sets, and leaves the search depth alone" do
    assert Tracker.preset(:bullet) == %{settle_ms: 150, takeback: false}

    assert Tracker.preset(:classical) == %{}
    assert Tracker.defaults().search_depth == 8 and Tracker.defaults().settle_ms == 250
  end

  test "when two sequences explain the board one is taken, marked as a guess, and the arbiter can pick the other" do
    # f-pawn one square or two, then taken en passant or not: the board is the same.
    {tr, b, t} = after_moves(~w(e4 a6 e5))
    seen = b |> lift("f7") |> move("e5", "f6")
    {tr, out} = feed(tr, [{t, seen}], 10_000)
    assert Tracker.sans(tr) == ~w(e4 a6 e5 f5 exf6)
    assert tr.status == :live
    assert alarms(out) == []
    assert [[:guessed], [:guessed]] = tr.plies |> Enum.take(-2) |> Enum.map(& &1.flags)

    # The game goes on, and the moves after the guess are plain moves.
    next = move(seen, "g8", "f6")
    {tr, _} = feed(tr, [{t + 12_000, next}], 2_000)
    assert Tracker.sans(tr) == ~w(e4 a6 e5 f5 exf6 Nxf6)
    assert List.last(tr.plies).flags == []

    # Either of the two guessed moves leads to the same question.
    assert %{from: 4, to: 5, current: ~w(f5 exf6), options: [~w(f5 exf6), ~w(f6 exf6)]} =
             Tracker.alternatives(tr, 5)

    assert Tracker.alternatives(tr, 4) == Tracker.alternatives(tr, 5)
    assert Tracker.alternatives(tr, 6) == nil
    assert Tracker.alternatives(tr, 1) == nil

    assert {:error, _} = Tracker.choose(tr, t + 20_000, 4, ~w(f6 Nf3))

    {:ok, {tr, events}, 0} = Tracker.choose(tr, t + 20_000, 4, ~w(f6 exf6))
    assert Tracker.sans(tr) == ~w(e4 a6 e5 f6 exf6 Nxf6)
    assert tr.status == :live
    assert [{:correction, 3, plies, :arbiter} | _] = events
    assert Enum.map(plies, & &1.san) == ~w(f6 exf6 Nxf6)
    # The arbiter has said so: no longer a guess, and not asked again.
    assert [[:arbiter], [:arbiter], []] = Enum.map(plies, & &1.flags)
    assert Tracker.alternatives(tr, 4) == nil
  end

  # --- what cannot be explained ------------------------------------------------

  test "an illegal move raises the alarm after the patience runs out, and clears when undone" do
    {tr, b, t} = after_moves(~w(e4 e5))
    # A rook through its own pawn: no number of legal moves does that.
    illegal = move(b, "a1", "a3")
    {tr, out} = feed(tr, [{t, illegal}], 9_000)
    assert Tracker.sans(tr) == ~w(e4 e5)
    assert tr.status == :out_of_sync

    # Named, and as soon as it has stood like any claim about a piece.
    assert [{at, {:status, :out_of_sync, {:illegal, %{piece: {:w, :r}, why: :blocked}}}}] =
             Enum.filter(out, &match?({_, {:status, :out_of_sync, _}}, &1))

    assert at == t + tr.opts.unseen_hold_ms

    {tr, _} = feed(tr, [{t + 20_000, b}, {t + 25_000, move(b, "g1", "f3")}], 1_000)
    assert tr.status == :live
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3)
  end

  test "two pieces swapped by mistake and put right never show" do
    {tr, b, t} = after_moves(~w(e4 e5))
    swapped = b |> put("b1", {:w, :b}) |> put("c1", {:w, :n})
    {tr, out} = feed(tr, [{t, swapped}, {t + 6_000, b}], 2_000)
    assert Tracker.sans(tr) == ~w(e4 e5)
    assert alarms(out) == []
    assert moves(out) == []
  end

  test "a flickering square is nothing" do
    {tr, b, t} = after_moves(~w(e4 e5))
    flicker = for i <- 0..9, do: {t + i * 90, if(rem(i, 2) == 0, do: lift(b, "d1"), else: b)}
    {tr, out} = feed(tr, flicker, 2_000)
    assert Tracker.sans(tr) == ~w(e4 e5)
    assert moves(out) == [] and alarms(out) == []
  end

  # --- a square that is not read ----------------------------------------------

  test "a square that goes on reading a piece after it has left is found out, and not read again" do
    {tr, b, t} = after_moves(~w(e4 e5))
    knight = elem(b, sq("g1"))
    # g1's sensor has died with the knight on it: 2. Nf3 reads as a second
    # knight on f3, the first still on g1.
    stuck = fn board -> put(board, "g1", knight) end
    b = move(b, "g1", "f3")
    b2 = move(b, "b8", "c6")
    b3 = move(b2, "f3", "g1")

    {tr, out} =
      feed(tr, [{t, stuck.(b)}, {t + 5_000, stuck.(b2)}, {t + 10_000, stuck.(b3)}], 5_000)

    assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6 Ng1)
    assert alarms(out) == []
    # Said once, and the square named.
    assert [{_t, {:dead, [g1]}}] = for({_t, {:dead, _}} = e <- out, do: e)
    assert g1 == sq("g1") and Tracker.dead(tr) == [g1]
    assert tr.status == :live
  end

  test "a piece held in the air is not a dead square" do
    {tr, b, t} = after_moves(~w(e4 e5))
    {tr, out} = feed(tr, [{t, lift(b, "g1")}, {t + 6_000, move(b, "g1", "f3")}], 3_000)
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3)
    assert Tracker.dead(tr) == []
    refute Enum.any?(out, &match?({_t, {:dead, _}}, &1))
  end

  test "a square that reads empty is suspected when a piece moves off it, and found out when one goes onto it" do
    {tr, b, t} = after_moves(~w(e4 e5 Nf3 Nc6))
    # f3 stops reading, with the knight on it: a piece out of sight.
    off = fn board -> lift(board, "f3") end
    b0 = b
    b = move(b0, "f1", "c4")
    b2 = move(b, "g8", "f6")
    b3 = move(b2, "f3", "g5")
    b4 = move(b3, "d7", "d5")
    b5 = move(b4, "g5", "f3")

    timed =
      [b, b2, b3, b4, b5]
      |> Enum.with_index(1)
      |> Enum.map(fn {x, i} -> {t + i * 5_000, off.(x)} end)

    # Until the knight goes back: a piece gone, which a hand is too, and
    # the press that ends the move is what says otherwise.
    {held, _out} = feed(tr, [{t, off.(b0)} | timed], 5_000)
    assert Tracker.sans(held) == ~w(e4 e5 Nf3 Nc6 Bc4 Nf6 Ng5 d5)
    assert Tracker.dead(held) == []

    {tr, out} = feed(tr, [{t, off.(b0)} | timed] ++ [{t + 26_000, :press}], 5_000)
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6 Bc4 Nf6 Ng5 d5 Nf3)
    assert Tracker.dead(tr) == [sq("f3")]
    assert alarms(out) == []
  end

  test "a square that broke while empty: the press, a move owed, and only one square the piece could go to" do
    {tr, b, t} = after_moves(~w(e4 e5))
    # The king goes to e2, whose sensor has died: only the king gone. Its
    # one empty square, the clock pressed, and the count says a move is
    # owed.
    gone = lift(b, "e1")
    owed = Tracker.presses(tr, 3)
    {tr2, out} = feed(owed, [{t, gone}, {t + 1_000, :press}], 3_000)
    assert Tracker.sans(tr2) == ~w(e4 e5 Ke2)
    assert Tracker.dead(tr2) == [sq("e2")]
    assert alarms(out) == []

    # And the game goes on over it.
    {tr2, _} = feed(tr2, [{t + 5_000, move(gone, "d7", "d6")}], 2_000)
    assert Tracker.sans(tr2) == ~w(e4 e5 Ke2 d6)

    # The clock's count owes nothing (the press of the move before, late):
    # a piece in a hand.
    {tr3, _} = feed(Tracker.presses(tr, 2), [{t, gone}, {t + 1_000, :press}], 3_000)
    assert Tracker.sans(tr3) == ~w(e4 e5)
    assert Tracker.dead(tr3) == []

    # Two squares the knight could have gone to: nothing to say which.
    {tr4, _} = feed(owed, [{t, lift(b, "b1")}, {t + 1_000, :press}], 3_000)
    assert Tracker.sans(tr4) == ~w(e4 e5)
    assert Tracker.dead(tr4) == []
  end

  # --- results -----------------------------------------------------------------

  test "mate, stalemate and the kings in the centre are suggestions" do
    {tr, _, _} = after_moves(~w(f3 e5 g4))
    b = tr.raw
    {tr, out} = feed(tr, [{20_000, move(b, "d8", "h4")}], 1_000)
    assert List.last(Tracker.sans(tr)) == "Qh4#"
    assert {:result_suggestion, "0-1", :checkmate} in Enum.map(out, &elem(&1, 1))

    {tr, b, t} = after_moves(~w(e4 e5))
    white_won = b |> lift("e4") |> lift("e5") |> move("e1", "e4") |> move("e8", "d5")
    {tr, out} = feed(tr, [{t, white_won}], 20_000)
    assert {:result_suggestion, "1-0", :gesture} in Enum.map(out, &elem(&1, 1))
    assert alarms(out) == []
    assert Tracker.sans(tr) == ~w(e4 e5)

    draw = b |> lift("e4") |> lift("e5") |> move("e1", "e4") |> move("e8", "e5")
    {_tr, out} = feed(elem(after_moves(~w(e4 e5)), 0), [{t, draw}], 20_000)
    assert {:result_suggestion, "1/2-1/2", :gesture} in Enum.map(out, &elem(&1, 1))
  end

  # --- the arbiter's tools -----------------------------------------------------

  test "undo, typed moves, an edited move and a position set by hand" do
    {tr, _b, t} = after_moves(~w(e4 e5 Nf3 Nc6))

    {undone, events} = Tracker.undo(%{tr | raw: nil}, t)
    assert Tracker.sans(undone) == ~w(e4 e5 Nf3)
    assert [{:correction, 3, [], :arbiter} | _] = events

    assert {:ok, {typed, events}} = Tracker.append(%{tr | raw: nil}, t, ~w(Bb5 a6))
    assert Tracker.sans(typed) == ~w(e4 e5 Nf3 Nc6 Bb5 a6)
    assert [{:moves, [%{flags: [:arbiter]}, %{flags: [:arbiter]}]}] = events
    assert {:error, {2, _}} = Tracker.append(tr, t, ~w(Bb5 Ke4))

    # Move 2 was really ...d6: what follows is replayed as far as it fits.
    assert {:ok, {edited, events}, 0} = Tracker.edit(%{tr | raw: nil}, t, 2, "d6")
    assert Tracker.sans(edited) == ~w(e4 d6 Nf3 Nc6)
    assert [{:correction, 1, [_, _, _], :arbiter} | _] = events

    # ...and dropped where it does not: after 1...Nc6 there is no second ...Nc6.
    assert {:ok, {edited, _}, 1} = Tracker.edit(%{tr | raw: nil}, t, 2, "Nc6")
    assert Tracker.sans(edited) == ~w(e4 Nc6 Nf3)
    assert {:error, _} = Tracker.edit(tr, t, 9, "e4")

    fen = "4k3/8/8/8/8/8/4P3/4K3 w - - 0 40"
    assert {:ok, {fresh, [{:restart, ^fen} | _]}} = Tracker.set_position(tr, t, fen)
    assert Tracker.sans(fresh) == [] and fresh.start_fen == fen
    assert {:error, _} = Tracker.set_position(tr, t, "not a fen")
  end

  test "resync searches deeper than the tracker does by itself" do
    {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4 e5 Nf3 Nc6 Bb5 a6))
    {tr, out} = feed(started(), [{1_000, board(List.last(plies).fen)}], 20_000)
    assert Tracker.sans(tr) == []
    assert tr.status == :waiting_start
    assert alarms(out) == []

    {tr, _events, outcome} = Tracker.resync(tr, 30_000, 6)
    # Six plies, and more than one order of them is legal: one is taken,
    # marked as a guess, and the others are there for the arbiter.
    assert {:guessed, sans, others} = outcome
    assert others > 0
    assert Tracker.sans(tr) == sans and length(sans) == 6
    assert Enum.all?(tr.plies, &(:guessed in &1.flags))
    assert %{from: 1, to: 6, options: options} = Tracker.alternatives(tr, 3)
    assert ~w(e4 e5 Nf3 Nc6 Bb5 a6) in options
    assert length(options) == others + 1
  end

  test "a stored game is restored move for move" do
    {tr, b, t} = after_moves(~w(e4 e5 Nf3))
    restored = Tracker.restore([], Enum.map(tr.plies, &Map.take(&1, [:san, :flags, :at])))
    assert Tracker.sans(restored) == Tracker.sans(tr)
    assert restored.pos == tr.pos
    {restored, _} = feed(restored, [{t, b}, {t + 5_000, move(b, "b8", "c6")}], 1_000)
    assert Tracker.sans(restored) == ~w(e4 e5 Nf3 Nc6)
  end

  # --- hands in a hall ------------------------------------------------------------

  test "the next hand lifts before the move has landed: both moves, as played" do
    {tr, b, t} = after_moves(~w(e4 e5))
    nf3 = move(b, "g1", "f3")

    {tr, out} =
      feed(
        tr,
        [
          {t, lift(b, "g1")},
          # Black has the knight in hand before White's has landed.
          {t + 120, b |> lift("g1") |> lift("b8")},
          {t + 220, lift(nf3, "b8")},
          {t + 900, move(nf3, "b8", "c6")}
        ],
        1_000
      )

    assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6)
    assert Enum.all?(tr.plies, &(&1.flags == []))
    assert alarms(out) == []
  end

  test "a piece gone in the same reading as the move is not a hand" do
    # Nf3 and Black's knight vanish together: nobody saw the knight lifted
    # while White's was in the air, so it is not taken for the next hand.
    {tr, b, t} = after_moves(~w(e4 e5))
    nf3 = move(b, "g1", "f3")

    {held, _} = feed(tr, [{t, lift(nf3, "b8")}], 1_000)
    assert Tracker.sans(held) == ~w(e4 e5)

    {tr, _} = feed(tr, [{t, lift(b, "g1")}, {t + 150, lift(nf3, "b8")}], 1_000)
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3)
  end

  test "presses with nothing changed on the board do not ask for a longer game" do
    # As in "more clock presses than moves", but two of the six presses are
    # the lever knocked back and pressed again while the board stood still.
    {tr, _b, t} = after_moves(~w(e4 e5))
    {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4 e5 Bc4 a6 Bb5))
    seen = board(List.last(plies).fen)

    tr = tr |> Tracker.presses(2, t) |> Tracker.presses(3, t + 100) |> Tracker.presses(5, t + 400)
    assert tr.idle == 2

    # Then the cable is out, and what the clock counts there is moves.
    out = fn presses ->
      {tr, _} =
        tr
        |> Tracker.deaf()
        |> Tracker.presses(presses, t + 600)
        |> feed([{t + 1_000, seen}], 1_000)

      tr
    end

    short = out.(7)
    assert short.idle == 2
    assert Enum.drop(Tracker.sans(short), 2) == ~w(Bb5 a6)

    long = out.(8)
    assert long.idle == 2
    assert length(Tracker.sans(long)) == 5
    assert Enum.all?(Enum.take(long.plies, -3), &(:guessed in &1.flags))
  end

  test "fast play: a piece knocked onto a legal square, set back as the next hand comes" do
    # Bullet settings: no takebacks. White's queen is knocked from d1 to
    # e2 and stands there long enough to be Qe2; it goes back, and White
    # plays Bc4 while Black's hand already has the g8 knight. Nothing on
    # the board is one move from Qe2: the knock is undone, and the move
    # put in its place is marked for what it is, a guess.
    {tr, b, t} = after_moves(~w(e4 e5 Nf3 Nc6))
    tr = %{tr | opts: Map.merge(tr.opts, Tracker.preset(:bullet))} |> Tracker.presses(4)
    bc4 = move(b, "f1", "c4")

    {tr, out} =
      feed(
        tr,
        [
          {t, move(b, "d1", "e2")},
          {t + 600, b},
          {t + 800, lift(b, "f1")},
          {t + 850, b |> lift("f1") |> lift("g8")},
          {t + 950, lift(bc4, "g8")},
          {t + 1_500, move(bc4, "g8", "f6")},
          {t + 1_900, {:presses, 5}}
        ],
        2_000
      )

    assert "Qe2" in moves(out)
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6 Bc4 Nf6)
    assert :guessed in Enum.at(tr.plies, 4).flags
  end

  test "a slider resting on its way out of check is not an earlier move misread" do
    # 3. Qa4+ and the bishop goes f5-e6-d7, resting on e6, where it does
    # not block the check. Read as the bishop having been on e6 all along
    # (2...Be6 misread as Bf5), the board would make sense with no move at
    # all; a slide stops for under a second, so that waits for the press.
    {tr, b, t} = after_moves(~w(d4 d5 c4 Bf5 Qa4+))
    rest = move(b, "f5", "e6")

    {tr, out} =
      feed(
        tr,
        [
          {t, lift(b, "f5")},
          {t + 80, rest},
          {t + 700, lift(rest, "e6")},
          {t + 780, move(rest, "e6", "d7")}
        ],
        1_000
      )

    assert Tracker.sans(tr) == ~w(d4 d5 c4 Bf5 Qa4+ Bd7)
    assert Enum.all?(tr.plies, &(&1.flags == []))
    assert alarms(out) == []
  end

  test "a capture taken back and the hand straight back for another is not the recapture" do
    # 1. Rg8, 1...Rxg8 taken back, then 1...Rxh7: the black rook in the
    # air and the h7 pawn lifted leave the board as 2. hxg8=R would. That
    # waits as a takeback would, and the rook lands on h7.
    fen = "7r/6RP/8/8/8/k7/8/2K5 w - - 0 1"
    {tr, _} = Tracker.observe(Tracker.new(start_fen: fen), 0, board(fen))
    b = board(fen)
    rg8 = move(b, "g7", "g8")
    rxg8 = move(rg8, "h8", "g8")

    {tr, out} =
      feed(
        tr,
        [
          {1_000, lift(b, "g7")},
          {1_100, rg8},
          {3_000, lift(rg8, "h8")},
          {3_100, rg8 |> lift("h8") |> lift("g8")},
          {3_200, rxg8},
          {5_000, lift(rxg8, "g8")},
          {5_100, rg8 |> lift("g8") |> put("h8", {:b, :r})},
          {5_200, rg8},
          {6_000, lift(rg8, "h8")},
          {6_100, rg8 |> lift("h8") |> lift("h7")},
          {6_600, move(rg8, "h8", "h7")}
        ],
        3_000
      )

    assert "Rxg8" in moves(out)
    refute "hxg8=R" in moves(out)
    assert Tracker.sans(tr) == ~w(Rg8 Rxh7)
    assert alarms(out) == []
  end

  test "two pawns left standing for knights: the first one's jump is asked about too" do
    fen = "8/P3P3/8/8/8/8/8/2K4k w - - 0 1"
    {tr, _} = Tracker.observe(Tracker.new(start_fen: fen), 0, board(fen))
    b1 = fen |> board() |> move("e7", "e8")
    b2 = move(b1, "h1", "h2")
    b3 = move(b2, "a7", "a8")
    b4 = move(b3, "h2", "h3")
    b5 = move(b4, "e8", "f6")

    {tr, out} =
      feed(tr, [{1_000, b1}, {6_000, b2}, {11_000, b3}, {16_000, b4}, {21_000, b5}], 6_000)

    assert Enum.at(Tracker.sans(tr), 0) == "e8=N"
    assert Enum.at(Tracker.sans(tr), 4) == "Nf6"
    assert alarms(out) == []
  end
end
