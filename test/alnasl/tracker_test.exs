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

    assert [{1_700, {:moves, [%{san: "e4", flags: []}]}} | _] =
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
    assert alarms(out) == [:unexplained]
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

  test "a board that starts late is caught up from the start position" do
    {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4 e5 Qh5))
    {tr, _} = feed(Tracker.new(), [{0, board(List.last(plies).fen)}], 6_000)
    assert Tracker.sans(tr) == ~w(e4 e5 Qh5)
    assert Enum.all?(tr.plies, &(:recovered in &1.flags and :long_gap in &1.flags))
  end

  test "when two sequences explain the board nothing is emitted, the alarm names it, and the arbiter picks" do
    # f-pawn one square or two, then taken en passant or not: the board is the same.
    {tr, b, t} = after_moves(~w(e4 a6 e5))
    seen = b |> lift("f7") |> move("e5", "f6")
    {tr, out} = feed(tr, [{t, seen}], 10_000)
    assert Tracker.sans(tr) == ~w(e4 a6 e5)
    assert tr.status == :out_of_sync
    assert alarms(out) == [:ambiguous]
    assert Enum.sort(Tracker.candidates(tr)) == [~w(f5 exf6), ~w(f6 exf6)]

    # The game goes on underneath: the candidates follow it.
    next = move(seen, "g8", "f6")
    {tr, _} = feed(tr, [{t + 12_000, next}], 2_000)
    assert Enum.sort(Tracker.candidates(tr)) == [~w(f5 exf6 Nxf6), ~w(f6 exf6 Nxf6)]

    index = Enum.find_index(Tracker.candidates(tr), &(hd(&1) == "f5"))
    {tr, events} = Tracker.choose(tr, t + 20_000, index)
    assert Tracker.sans(tr) == ~w(e4 a6 e5 f5 exf6 Nxf6)
    assert tr.status == :live
    assert [{:moves, plies} | _] = events
    assert Enum.all?(plies, &(:arbiter in &1.flags))
  end

  # --- what cannot be explained ------------------------------------------------

  test "an illegal move raises the alarm after the patience runs out, and clears when undone" do
    {tr, b, t} = after_moves(~w(e4 e5))
    # A rook through its own pawn. (A knight to g3 would not do: Ne2-g3 with
    # a black knight out and back is four legal moves, and the tracker says
    # "ambiguous" - also an alarm, a different word.)
    illegal = move(b, "a1", "a3")
    {tr, out} = feed(tr, [{t, illegal}], 9_000)
    assert Tracker.sans(tr) == ~w(e4 e5)
    assert tr.status == :out_of_sync

    assert [{at, {:status, :out_of_sync, :unexplained}}] =
             Enum.filter(out, &match?({_, {:status, :out_of_sync, _}}, &1))

    assert at == t + tr.opts.transient_ms

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
    # Six plies, and White's three commute with each other only where legal:
    # there is more than one order, so the arbiter is asked.
    assert {:candidates, n} = outcome
    assert n > 1
    assert ~w(e4 e5 Nf3 Nc6 Bb5 a6) in Tracker.candidates(tr)
  end

  test "a stored game is restored move for move" do
    {tr, b, t} = after_moves(~w(e4 e5 Nf3))
    restored = Tracker.restore([], Enum.map(tr.plies, &Map.take(&1, [:san, :flags, :at])))
    assert Tracker.sans(restored) == Tracker.sans(tr)
    assert restored.pos == tr.pos
    {restored, _} = feed(restored, [{t, b}, {t + 5_000, move(b, "b8", "c6")}], 1_000)
    assert Tracker.sans(restored) == ~w(e4 e5 Nf3 Nc6)
  end
end
