defmodule Alnasl.TrackerCrosstalkTest do
  @moduledoc """
  Crosstalk: two pieces close together disturb each other's reading, so a
  piece reads as nothing, or as another piece of its colour. What the
  tracker makes of each, square by square.
  """

  use ExUnit.Case, async: true

  alias Alnasl.{Chess, Position, Tracker}

  defp board(fen), do: Position.from_fen(fen)
  defp sq(name), do: Position.square_index(name)
  defp lift(board, square), do: put_elem(board, sq(square), nil)
  defp put(board, square, piece), do: put_elem(board, sq(square), piece)
  defp move(board, from, to), do: board |> put(to, elem(board, sq(from))) |> lift(from)

  defp feed(tr, timed, tail) do
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

  defp alarms(out), do: for({_t, {:status, :out_of_sync, why}} <- out, do: why)

  defp after_moves(sans) do
    {:ok, plies} = Chess.replay(Chess.start_fen(), sans)
    boards = Enum.map(plies, &board(&1.fen))
    {tr, _} = Tracker.observe(Tracker.new(), 0, Position.start())
    timed = boards |> Enum.with_index(1) |> Enum.map(fn {b, i} -> {i * 5_000, b} end)
    {tr, _} = feed(tr, timed, 1_000)
    assert Tracker.sans(tr) == sans
    {tr, List.last(boards), length(sans) * 5_000 + 1_000}
  end

  test "a piece heard as another, standing still, is not an alarm, and is listed once it lasts" do
    {tr, b, t} = after_moves(~w(e4 e5 Nf3 Nc6))
    # The bishop on f1, beside the king, heard as a knight.
    heard = put(b, "f1", {:w, :n})
    {tr, out} = feed(tr, [{t, heard}], 30_000)

    assert alarms(out) == []
    assert tr.status == :live
    assert [%{square: square, piece: {:w, :b}, read: {:w, :n}}] = Tracker.confused(tr)
    assert square == sq("f1")
    assert Enum.any?(out, &match?({_, {:confused, [_]}}, &1))

    # Heard right again: off the list.
    {tr, out} = feed(tr, [{t + 40_000, b}], 1_000)
    assert Tracker.confused(tr) == []
    assert Enum.any?(out, &match?({_, {:confused, []}}, &1))
  end

  test "a moment of it is not even listed" do
    {tr, b, t} = after_moves(~w(e4 e5))
    heard = put(b, "d1", {:w, :k})
    {tr, out} = feed(tr, [{t, heard}, {t + 400, b}], 10_000)
    assert alarms(out) == []
    refute Enum.any?(out, &match?({_, {:confused, _}}, &1))
    assert Tracker.confused(tr) == []
  end

  test "moves go on while a piece is heard as another, and the game keeps the piece it has" do
    {tr, b, t} = after_moves(~w(e4 e5))
    heard = put(b, "f1", {:w, :n})
    {tr, _} = feed(tr, [{t, heard}], 3_000)

    played = heard |> move("g1", "f3")
    replied = played |> move("b8", "c6")

    {tr, out} = feed(tr, [{t + 5_000, played}, {t + 10_000, replied}], 5_000)
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6)
    assert alarms(out) == []
    assert Enum.all?(tr.plies, &(&1.flags == []))
    # The game's bishop stays a bishop; the board's reading is not the game.
    assert elem(tr.pos.board, sq("f1")) == {:w, :b}
    assert elem(tr.phys, sq("f1")) == {:w, :b}

    # And it moves as the bishop it is.
    bishop = replied |> put("f1", {:w, :b}) |> move("f1", "c4")
    {tr, _} = feed(tr, [{t + 15_000, bishop}], 5_000)
    assert List.last(Tracker.sans(tr)) == "Bc4"
  end

  test "a piece that lands heard as another is the move its squares say, once it has stood" do
    {tr, b, t} = after_moves(~w(e4 e5))
    # The knight goes to f3 and is heard there as a rook.
    landed = b |> lift("g1") |> put("f3", {:w, :r})
    {tr, out} = feed(tr, [{t, landed}], 10_000)
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3)
    assert alarms(out) == []
    [{at, _}] = for {_at, {:moves, _}} = e <- out, do: e
    assert at >= t + tr.opts.unseen_hold_ms

    # Pressed for: at once.
    {tr2, _, t2} = after_moves(~w(e4 e5))
    {tr2, _} = feed(tr2, [{t2, landed}, {t2 + 300, :press}], 0)
    assert Tracker.sans(tr2) == ~w(e4 e5 Nf3)
  end

  test "a piece heard as a king is not a king that landed" do
    {tr, b, t} = after_moves(~w(e4 e5))
    landed = b |> lift("g1") |> put("f3", {:w, :k})
    {tr, out} = feed(tr, [{t, landed}], 20_000)
    assert Tracker.sans(tr) == ~w(e4 e5)
    assert alarms(out) != []
  end

  test "it matters when the piece does what only the piece it was heard as can: the alarm, no move" do
    {tr, b, t} = after_moves(~w(e4 e5 Nf3 Nc6))
    # The game has a bishop on f1; it reads as a knight, and the "knight"
    # jumps to e3.
    jumped = b |> lift("f1") |> put("e3", {:w, :n})
    {tr, out} = feed(tr, [{t, put(b, "f1", {:w, :n})}, {t + 3_000, jumped}], 20_000)
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6)
    assert alarms(out) != []
  end

  test "a promotion pressed for keeps its piece when the board hears it as another" do
    # 1. a8=B+, the clock pressed for it, and four seconds later the bishop
    # beside nothing in particular reads as a knight. Before, the last move
    # was revised into 1. a8=N - which gives no check - without a mark.
    fen = "8/P7/8/8/8/8/8/K6k w - - 0 1"
    start = board(fen)
    {tr, _} = Tracker.observe(Tracker.new(start_fen: fen), 0, start)
    tr = Tracker.presses(tr, 0, 0)
    bishop = start |> lift("a7") |> put("a8", {:w, :b})
    heard = put(bishop, "a8", {:w, :n})

    {tr, out} = feed(tr, [{1_000, bishop}, {1_600, {:presses, 1}}, {5_000, heard}], 10_000)

    assert Tracker.sans(tr) == ["a8=B+"]
    refute Enum.any?(out, &match?({_, {:correction, _, _, _}}, &1))
    assert alarms(out) == []

    # Changed before the press - lifted and another piece set down - it is
    # the player's change, and the move is that.
    {tr, _} = Tracker.observe(Tracker.new(start_fen: fen), 0, start)
    tr = Tracker.presses(tr, 0, 0)
    swapped = put(bishop, "a8", {:w, :n})

    {tr, _} =
      feed(
        tr,
        [{1_000, bishop}, {2_000, lift(bishop, "a8")}, {2_400, swapped}, {4_000, {:presses, 1}}],
        5_000
      )

    assert Tracker.sans(tr) == ["a8=N"]
  end

  test "a hand beside a piece heard as another is a hand, not an exchange on its square" do
    # White's pawn on b3 has read as a rook for a while. Black takes on d3:
    # the rook off, the queen in the air. With b3 counted as a change, that
    # was more than a hand, and 250 ms in the search found 34...Qxb3
    # 35. Rxb3 - which ends with a white rook on b3, as read. Then the
    # queen landed on d3, and the alarm.
    fen = "1r2b1k1/7N/p3p1p1/3p4/3r1Q1P/1PqRK3/2B2P2/7R b - - 3 34"
    start = board(fen)
    {tr, _} = Tracker.observe(Tracker.new(start_fen: fen), 0, start)
    heard = put(start, "b3", {:w, :r})
    taken = lift(heard, "d3")
    lifted = lift(taken, "c3")
    landed = put(lifted, "d3", {:b, :q})

    {tr, out} =
      feed(tr, [{1_000, heard}, {6_000, taken}, {6_200, lifted}, {6_600, landed}], 6_000)

    assert Tracker.sans(tr) == ["Qxd3+"]
    assert Enum.all?(tr.plies, &(&1.flags == []))
    assert alarms(out) == []
  end

  test "the starting position with a piece heard as another is the starting position" do
    start = Position.start() |> put("c1", {:w, :n})
    {tr, out} = feed(Tracker.new(), [{0, start}], 5_000)
    assert {:status, :waiting_start, :ready} in Enum.map(out, &elem(&1, 1))
    played = start |> move("e2", "e4")
    {tr, _} = feed(tr, [{6_000, played}], 2_000)
    assert Tracker.sans(tr) == ["e4"]
  end

  test "a king not heard beside its neighbours, over a move pressed for, is a king standing there" do
    {tr, b, t} = after_moves(~w(e4 e5 Nf3 Nc6))
    # Black's king reads empty; White plays Bc4 and presses.
    quiet = lift(b, "e8")
    played = quiet |> move("f1", "c4")
    {tr, out} = feed(tr, [{t, quiet}, {t + 2_000, played}, {t + 2_300, :press}], 3_000)
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6 Bc4)
    assert alarms(out) == []
    assert [%{piece: {:b, :k}}] = Tracker.unseen(tr)

    # Heard again.
    {tr, _} = feed(tr, [{t + 8_000, b |> move("f1", "c4")}], 2_000)
    assert Tracker.unseen(tr) == []
  end

  test "the same king, a castle half made, is not supposed" do
    {tr, b, t} = after_moves(~w(e4 e5 Nf3 Nc6 Bc4 Bc5))
    # The king is in the hand, the rook has gone to f1: half a castle.
    half = b |> lift("e1") |> move("h1", "f1")
    {tr, _} = feed(tr, [{t, half}, {t + 300, :press}], 1_000)
    refute Enum.any?(Tracker.unseen(tr), &match?(%{piece: {:w, :k}}, &1))
  end

  test "a piece heard as another and one not heard at all, over a move" do
    {tr, b, t} = after_moves(~w(e4 e5 Nf3 Nc6))
    # Black's bishop on f8 heard as a knight, White's queen on d1 not
    # heard, and White plays Bc4.
    noise = b |> put("f8", {:b, :n}) |> lift("d1")
    played = noise |> move("f1", "c4")
    {tr, out} = feed(tr, [{t, noise}, {t + 1_000, played}, {t + 1_200, :press}], 3_000)
    assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6 Bc4)
    assert alarms(out) == []
  end
end
