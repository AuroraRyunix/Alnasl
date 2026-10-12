defmodule Alnasl.UnseenPieceTest do
  @moduledoc """
  A piece that leaves its square while the game goes on.

  Board 06310, 2026-10-11: after 3. Nf3 the knight was lifted off f3 and
  parked beside the board, on purpose, and five moves were played before it
  came down on e5. The tracker waited for the knight for all five and was
  six plies behind when it landed. The recording is the first test; the rest
  is the same situation square by square, and the ordinary moves that must
  not be mistaken for it.
  """

  use ExUnit.Case, async: true

  alias Alnasl.{Chess, Position, Recorder, Tracker}

  @recording "test/fixtures/captures/real-06310-unseen-knight.jsonl"

  defp board(fen), do: Position.from_fen(fen)
  defp sq(name), do: Position.square_index(name)
  defp lift(board, square), do: put_elem(board, sq(square), nil)
  defp move(board, from, to), do: board |> put_elem(sq(to), elem(board, sq(from))) |> lift(from)

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

    ticks(tr, last + tail, out)
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

  defp after_moves(sans, opts \\ []) do
    {:ok, plies} = Chess.replay(Chess.start_fen(), sans)
    boards = Enum.map(plies, &board(&1.fen))
    timed = boards |> Enum.with_index(1) |> Enum.map(fn {b, i} -> {i * 5_000, b} end)
    {tr, _} = Tracker.observe(Tracker.new(opts), 0, Position.start())
    {tr, _} = feed(tr, timed, 1_000)
    assert Tracker.sans(tr) == sans
    {tr, List.last(boards), length(sans) * 5_000 + 1_000}
  end

  defp alarms(out), do: for({_t, {:status, :out_of_sync, why}} <- out, do: why)
  defp unseen(out), do: for({_t, {:unseen, pieces}} <- out, do: Enum.map(pieces, & &1.square))

  # 1. d4 d5 2. Nc3 Nf6 3. Nf3, the knight taken off f3, and ...Nc6 played
  # and settled: the knight is not seen on f3. The tracker, the board as it
  # reads (no knight), and the time.
  defp knight_parked(opts \\ []) do
    {tr, b, t} = after_moves(~w(d4 d5 Nc3 Nf6 Nf3), opts)
    gone = lift(b, "f3")
    played = move(gone, "b8", "c6")

    {tr, out} =
      feed(tr, [{t, gone}, {t + 5_000, lift(gone, "b8")}, {t + 5_400, played}], 3_000)

    {tr, played, t + 9_000, out}
  end

  test "the recording: the game is followed past the parked knight, to its landing on e5 and on" do
    assert {:ok, report} = Recorder.dry_run(@recording, settle_ms: 150, search_depth: 2)

    assert Enum.take(report.moves, 11) == ~w(d4 d5 Nc3 Nf6 Nf3 Nc6 Be3 e6 Qc1 Bb4 Ne5)
    assert report.alarms == []
    assert report.status == :live

    # What the recording holds after the knight's landing at 4:28: Black's
    # bishop to d7 at 8:01 and White's queen to d2 at 8:24, each with its
    # clock press. Nothing else.
    assert Enum.drop(report.moves, 11) == ~w(Bd7 Qd2)

    # Said once when it began (the press after ...Nc6) and once when the
    # knight was accounted for.
    f3 = sq("f3")
    assert [{from, [%{square: ^f3, piece: {:w, :n}}]}, {to, []}] = report.unseen
    assert_in_delta from, 252_200, 500
    assert_in_delta to, 268_300, 500

    # The moves made meanwhile carry the mark; the knight's own does not.
    flags = Enum.map(report.plies, &(:unseen in &1.flags))

    assert flags ==
             [false, false, false, false, false] ++
               [true, true, true, true, true] ++ [false, false, false]
  end

  test "a move by another piece while one is gone: accepted, and the piece is 'not seen' there" do
    {tr, _b, _t, out} = knight_parked()

    assert Tracker.sans(tr) == ~w(d4 d5 Nc3 Nf6 Nf3 Nc6)
    assert tr.status == :live
    assert alarms(out) == []
    assert unseen(out) == [[sq("f3")]]
    assert Tracker.unseen(tr) == [%{square: sq("f3"), piece: {:w, :n}}]

    # The position still has the knight: it was not dropped from the game.
    assert elem(tr.pos.board, sq("f3")) == {:w, :n}
    assert :unseen in List.last(tr.plies).flags
  end

  test "such a move must stand, or be pressed on the clock, before it is believed" do
    {tr, b, t} = after_moves(~w(d4 d5 Nc3 Nf6 Nf3))
    gone = lift(b, "f3")
    played = move(gone, "b8", "c6")

    {waiting, out} = feed(tr, [{t, gone}, {t + 5_000, played}], 1_900)
    assert Tracker.sans(waiting) == ~w(d4 d5 Nc3 Nf6 Nf3)
    assert unseen(out) == []

    {held, _out} = feed(tr, [{t, gone}, {t + 5_000, played}], 2_100)
    assert List.last(Tracker.sans(held)) == "Nc6"

    {pressed, out} = feed(tr, [{t, gone}, {t + 5_000, played}, {t + 5_100, :press}], 0)
    assert List.last(Tracker.sans(pressed)) == "Nc6"
    assert [{at, _}] = Enum.filter(out, &match?({_, {:moves, _}}, &1))
    assert at == t + 5_100
  end

  test "it is seen on its square again: it was there all along" do
    {tr, b, t, _} = knight_parked()
    back = put_elem(b, sq("f3"), {:w, :n})

    {tr, out} = feed(tr, [{t, back}], 1_000)
    assert Tracker.unseen(tr) == []
    assert unseen(out) == [[]]
    assert tr.status == :live
    assert Tracker.sans(tr) == ~w(d4 d5 Nc3 Nf6 Nf3 Nc6)

    # And the game goes on as if nothing had been.
    {tr, out} = feed(tr, [{t + 2_000, lift(back, "e2")}, {t + 2_300, move(back, "e2", "e3")}])
    assert List.last(Tracker.sans(tr)) == "e3"
    assert List.last(tr.plies).flags == []
    assert alarms(out) == []
  end

  test "it comes down on a square it can move to, on its side's turn: that is its move" do
    {tr, b, t, _} = knight_parked()
    landed = put_elem(b, sq("e5"), {:w, :n})

    {tr, out} = feed(tr, [{t, landed}], 1_000)
    assert List.last(Tracker.sans(tr)) == "Ne5"
    assert List.last(tr.plies).flags == []
    assert Tracker.unseen(tr) == []
    assert unseen(out) == [[]]
    assert alarms(out) == []
    assert tr.raw == tr.pos.board
  end

  test "it is taken where it stood: a piece of the other colour lands on its square" do
    # ...Nc6 is on the board; White plays e4, Black takes the knight nobody
    # sees: ...Bg4 first, then Bxf3.
    {tr, b, t, _} = knight_parked()
    e4 = move(b, "e2", "e4")
    bg4 = move(e4, "c8", "g4")
    h3 = move(bg4, "h2", "h3")
    bxf3 = move(h3, "g4", "f3")

    {tr, out} =
      feed(tr, [{t, e4}, {t + 3_000, bg4}, {t + 6_000, h3}, {t + 9_000, bxf3}], 1_000)

    assert Enum.drop(Tracker.sans(tr), 6) == ~w(e4 Bg4 h3 Bxf3)
    assert Tracker.unseen(tr) == []
    assert unseen(out) == [[]]
    assert alarms(out) == []
    assert tr.raw == tr.pos.board
  end

  test "a move that is illegal with the piece there is not explained away: the alarm, and the piece stays in the game" do
    # White's g-pawn turns up on f3: it cannot take its own knight.
    {tr, b, t, _} = knight_parked()
    through = move(b, "g2", "f3")

    {tr, out} = feed(tr, [{t, through}], 10_000)
    assert Tracker.sans(tr) == ~w(d4 d5 Nc3 Nf6 Nf3 Nc6)
    assert [{:illegal, %{piece: {:w, :p}}}] = alarms(out)
    assert Tracker.unseen(tr) == [%{square: sq("f3"), piece: {:w, :n}}]
    assert elem(tr.pos.board, sq("f3")) == {:w, :n}
  end

  test "a piece of its own side moved onto the unseen piece's square is the alarm too" do
    # 1. a4 h5 2. Ra3 h4 3. b3 h3: the rook is parked off a3, White takes
    # on h3, Black plays ...g6, and the bishop from c1 lands on a3.
    {tr, b, t} = after_moves(~w(a4 h5 Ra3 h4 b3 h3))
    gone = lift(b, "a3")
    reply = move(gone, "g2", "h3")

    {tr, _out} = feed(tr, [{t, gone}, {t + 3_000, reply}, {t + 3_100, :press}], 500)
    assert List.last(Tracker.sans(tr)) == "gxh3"
    assert Tracker.unseen(tr) == [%{square: sq("a3"), piece: {:w, :r}}]

    played = move(reply, "g7", "g6")
    onto = move(played, "c1", "a3")
    {tr, out} = feed(tr, [{t + 6_000, played}, {t + 9_000, onto}], 10_000)

    assert List.last(Tracker.sans(tr)) == "g6"
    assert [{:illegal, %{piece: {:w, :b}}}] = alarms(out)
    assert elem(tr.pos.board, sq("a3")) == {:w, :r}
  end

  test "it comes down when it is not its side's turn: no move of its, so the alarm" do
    # After ...Nc6 it is White's turn; let White move, then the knight lands
    # on e5 with Black to move.
    {tr, b, t, _} = knight_parked()
    e3 = move(b, "e2", "e3")
    landed = put_elem(e3, sq("e5"), {:w, :n})

    {tr, out} = feed(tr, [{t, e3}, {t + 3_000, landed}], 10_000)
    assert List.last(Tracker.sans(tr)) == "e3"
    # And named for what it is: White's knight, on Black's time.
    assert [{:out_of_turn, %{colour: :w, san: "Ne5"}}] = alarms(out)
  end

  test "an ordinary move, however slow, is not this" do
    {tr, b, t} = after_moves(~w(e4 e5))

    # The knight in the hand for half a minute, then put down.
    {tr, out} = feed(tr, [{t, lift(b, "g1")}, {t + 30_000, move(b, "g1", "f3")}], 2_000)
    assert List.last(Tracker.sans(tr)) == "Nf3"
    assert unseen(out) == []
    assert alarms(out) == []
    assert List.last(tr.plies).flags == []
  end

  test "a capture with the captured piece taken off first, and the capturer long in coming, is a capture" do
    {tr, b, t} = after_moves(~w(e4 d5))
    off = lift(b, "d5")

    steps = [
      {t, off},
      {t + 20_000, lift(off, "e4")},
      {t + 20_400, move(b, "e4", "d5")}
    ]

    {tr, out} = feed(tr, steps, 2_000)
    assert Tracker.sans(tr) == ~w(e4 d5 exd5)
    assert unseen(out) == []
    assert alarms(out) == []
    assert Tracker.unseen(tr) == []
  end

  test "a capture whose capturer rests on the way is put right when it arrives" do
    # 1. e4 d5 2. Qh5 d4: the pawn on f7 is lifted off, and the queen
    # rests on g6 for three seconds before it lands on f7.
    {tr, b, t} = after_moves(~w(e4 d5 Qh5 d4))
    off = lift(b, "f7")
    rest = move(off, "h5", "g6")
    done = move(b, "h5", "f7")

    {tr, out} = feed(tr, [{t, off}, {t + 500, rest}, {t + 3_500, done}], 2_000)
    assert List.last(Tracker.sans(tr)) == "Qxf7+"
    assert length(Tracker.sans(tr)) == 5
    assert Tracker.unseen(tr) == []
    assert alarms(out) == []
  end

  test "castling, king lifted first and the rook moved under it, is castling" do
    {tr, b, t} = after_moves(~w(e4 e5 Nf3 Nc6 Bc4 Bc5))
    king_up = lift(b, "e1")
    rook_over = move(king_up, "h1", "f1")
    castled = b |> move("e1", "g1") |> move("h1", "f1")

    {tr, out} = feed(tr, [{t, king_up}, {t + 1_000, rook_over}, {t + 6_000, castled}], 3_000)
    assert List.last(Tracker.sans(tr)) == "O-O"
    assert for({_t, {:moves, plies}} <- out, ply <- plies, do: ply.san) == ["O-O"]
    assert unseen(out) == []
  end

  test "a promotion with the pawn off the board for a while is a promotion" do
    fen = "8/4P3/8/8/8/k7/8/4K3 w - - 0 1"
    {tr, _} = Tracker.observe(Tracker.new(start_fen: fen), 0, board(fen))
    b = board(fen)
    up = lift(b, "e7")

    {tr, out} = feed(tr, [{1_000, up}, {9_000, put_elem(up, sq("e8"), {:w, :r})}], 5_000)
    assert Tracker.sans(tr) == ["e8=R"]
    assert unseen(out) == []
  end

  test "one piece at a time: a second one gone is waited for, and becomes the alarm it always was" do
    {tr, b, t, _} = knight_parked()
    second = lift(b, "c3")
    reply = move(second, "e2", "e4")

    {tr, out} = feed(tr, [{t, second}, {t + 3_000, reply}], 62_000)
    assert Tracker.sans(tr) == ~w(d4 d5 Nc3 Nf6 Nf3 Nc6)
    assert length(Tracker.unseen(tr)) == 1
    assert alarms(out) != []
  end

  test "never a king" do
    {tr, b, t} = after_moves(~w(e4 e5))
    gone = lift(b, "e1")

    {tr, out} = feed(tr, [{t, gone}, {t + 3_000, move(gone, "g1", "f3")}], 10_000)
    assert Tracker.sans(tr) == ~w(e4 e5)
    assert unseen(out) == []
  end

  test "a takeback does not put a piece out of sight again" do
    # The unseen knight lands on e5 and is lifted off once more: not "Ne5
    # taken back" - the board never showed it back on f3.
    {tr, b, t, _} = knight_parked()
    landed = put_elem(b, sq("e5"), {:w, :n})

    {tr, out} = feed(tr, [{t, landed}, {t + 3_000, b}], 5_000)
    assert List.last(Tracker.sans(tr)) == "Ne5"
    refute Enum.any?(out, &match?({_, {:correction, _, _, _}}, &1))
    assert Tracker.unseen(tr) == []
  end

  test "switched off in Setup: the board waits, as it did" do
    {tr, _b, _t, out} = knight_parked(unseen_piece: false)
    assert Tracker.sans(tr) == ~w(d4 d5 Nc3 Nf6 Nf3)
    assert unseen(out) == []
    assert Tracker.unseen(tr) == []
  end

  test "undoing the move that began it ends it; the history remembers which pieces were unseen when" do
    {tr, _b, t, _} = knight_parked()
    {tr, events} = Tracker.undo(tr, t)
    assert Tracker.sans(tr) == ~w(d4 d5 Nc3 Nf6 Nf3)
    assert Tracker.unseen(tr) == []
    assert {:unseen, []} in events
  end
end
