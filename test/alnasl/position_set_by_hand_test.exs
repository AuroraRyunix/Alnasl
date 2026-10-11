defmodule Alnasl.PositionSetByHandTest do
  @moduledoc """
  A position taken from the board by hand, mid-game.

  Board 06310, 2026-10-11: the arbiter set the position from what the board
  read ("Start from a position", "Take it from the board"), and the FEN it
  was given said nobody could castle and White was to move. Black castled
  short and White long; both were "Out of sync". The recording is the test.
  """

  use ExUnit.Case, async: true

  alias Alnasl.{Chess, Position, Recorder, Session, Tracker}

  @recording "test/fixtures/captures/real-06310-castling-after-set.jsonl"

  defp sq(name), do: Position.square_index(name)

  describe "the FEN offered for a bare board" do
    test "kings and rooks at home: every right, and the side to move as told" do
      assert Position.fen(Position.start()) ==
               "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

      assert Position.fen(Position.start(), :b) =~ " b KQkq - 0 1"
    end

    test "a king or a rook not at home: that right is not offered" do
      b = Position.start()
      off = fn squares -> Enum.reduce(squares, b, &put_elem(&2, sq(&1), nil)) end

      assert Position.fen(off.(~w(h1))) =~ " w Qkq "
      assert Position.fen(off.(~w(a1))) =~ " w Kkq "
      assert Position.fen(off.(~w(a8 h1))) =~ " w Qk "
      assert Position.fen(off.(~w(e8))) =~ " w KQ "
      assert Position.fen(off.(~w(e1 e8))) =~ " w - "

      # A rook of the other colour in the corner is not a right.
      assert Position.fen(put_elem(b, sq("h1"), {:b, :r})) =~ " w Qkq "
    end

    test "it is a position the tracker takes" do
      assert {:ok, pos} = Chess.parse_fen(Position.fen(Position.start(), :b))
      assert pos.turn == :b
    end
  end

  describe "the recording" do
    # Its first reading is half a second into Black's castling: the king
    # is already off e8. The position that was set is that board with the
    # king back, Black to move.
    setup do
      {:ok, capture} = Recorder.read(@recording)
      {_t, {:position, first}} = Enum.find(capture.events, &match?({_, {:position, _}}, &1))
      assert elem(first, sq("e8")) == nil
      set = put_elem(first, sq("e8"), {:b, :k})
      {:ok, events: capture.events, set: set}
    end

    test "with the rights the board implies, both castles are moves", %{events: events, set: set} do
      fen = Position.fen(set, :b)
      assert fen == "r2qk2r/pppb1ppp/2n1pn2/3pN3/1b1P4/2N1B3/PPPQPPPP/R3KB1R b KQkq - 0 1"

      session = Session.new(start_fen: fen, settle_ms: 150)
      {session, _} = Session.handle(session, 0, {:position, set})
      {session, out} = Session.run(session, events, tail_ms: 5_500)

      # King first, rook after, readings 0.3-1.3 s apart: 2:21 and 2:34.
      assert Tracker.sans(session.tracker) == ~w(O-O O-O-O)
      assert for({_t, {:status, :out_of_sync, why}} <- out, do: why) == []
      assert session.tracker.status == :live
    end

    test "as it was - no rights - neither is, and the board is out of sync", %{
      events: events,
      set: set
    } do
      fen = Position.placement(set) <> " b - - 0 1"
      session = Session.new(start_fen: fen, settle_ms: 150)
      {session, _} = Session.handle(session, 0, {:position, set})
      {session, out} = Session.run(session, events, tail_ms: 5_500)

      assert Tracker.sans(session.tracker) == []
      assert for({_t, {:status, :out_of_sync, why}} <- out, do: why) != []
    end
  end

  test "set from the board with king and rooks at home: castling either way round, either side" do
    fen = "r3k2r/pppq1ppp/2npbn2/2b1p3/2B1P3/2NPBN2/PPPQ1PPP/R3K2R w KQkq - 0 1"
    board = Position.from_fen(fen)
    assert Position.fen(board) == fen

    move = fn b, from, to ->
      b |> put_elem(sq(to), elem(b, sq(from))) |> put_elem(sq(from), nil)
    end

    for {king, rook, san, turn} <- [
          {{"e1", "g1"}, {"h1", "f1"}, "O-O", :w},
          {{"e1", "c1"}, {"a1", "d1"}, "O-O-O", :w},
          {{"e8", "g8"}, {"h8", "f8"}, "O-O", :b},
          {{"e8", "c8"}, {"a8", "d8"}, "O-O-O", :b}
        ],
        order <- [:king_first, :rook_first] do
      {k_from, k_to} = king
      {r_from, r_to} = rook
      tracker = Tracker.new(start_fen: Position.fen(board, turn))
      {tracker, _} = Tracker.observe(tracker, 0, board)

      half =
        if order == :king_first,
          do: move.(board, k_from, k_to),
          else: move.(board, r_from, r_to)

      done = board |> move.(k_from, k_to) |> move.(r_from, r_to)
      {tracker, _} = Tracker.observe(tracker, 1_000, half)
      {tracker, _} = Tracker.observe(tracker, 1_800, done)
      {tracker, _} = Tracker.tick(tracker, 3_000)

      assert Tracker.sans(tracker) == [san], "#{san}, #{order}, #{turn} to move"
    end
  end
end
