defmodule Alnasl.NoPhantomsTest do
  @moduledoc """
  No move for which no reading gives evidence, and a name for what the
  board does show.

  Board 06310, connected throughout: 1. e4, twenty-four minutes of nothing,
  1...e5 - and then Black's knight to c6, a second black move in a row. The
  tracker let White's bishop go to a6 and back so that Black could have it:
  `2. Ba6 Nc6 3. Bf1`. The bishop stood on f1 in every reading. The knight
  went back, a bishop was put on g5 through its own pawn and taken back,
  and the pieces were set up again. The recording is the first test.
  """

  use ExUnit.Case, async: true

  alias Alnasl.{Chess, Position, Recorder, Session, Tracker}
  alias Alnasl.Tracker.Search

  @recording "test/fixtures/captures/real-06310-out-of-turn.jsonl"

  defp board(fen), do: Position.from_fen(fen)
  defp sq(name), do: Position.square_index(name)
  defp lift(board, square), do: put_elem(board, sq(square), nil)
  defp put(board, square, piece), do: put_elem(board, sq(square), piece)
  defp move(board, from, to), do: board |> put(to, elem(board, sq(from))) |> lift(from)

  defp feed(tr, timed, tail \\ 10_000) do
    {tr, out, last} =
      Enum.reduce(timed, {tr, [], 0}, fn {t, what}, {tr, out, _last} ->
        {tr, out} = ticks(tr, t, out)
        {tr, events} = Tracker.observe(tr, t, what)
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

  defp after_fen(sans),
    do:
      sans
      |> then(&Chess.replay(Chess.start_fen(), &1))
      |> elem(1)
      |> List.last()
      |> Map.fetch!(:fen)

  describe "the recording" do
    # Up to 32:13.5: the knight and the bishop are back where they stood.
    setup do
      {:ok, capture} = Recorder.read(@recording)
      {:ok, events: capture.events}
    end

    test "is 1. e4 e5, live, no mark on any move - and the two things it saw, by name", %{
      events: events
    } do
      until = Enum.take_while(events, fn {t, _event} -> t < 1_933_500 end)
      {session, out} = Session.run(Session.new([]), until, tail_ms: 0)
      tr = session.tracker

      assert Tracker.sans(tr) == ~w(e4 e5)
      assert tr.status == :live
      assert Enum.all?(tr.plies, &(&1.flags == []))
      refute Enum.any?(out, &match?({_, {:correction, _, _, _}}, &1))
      assert for({_t, {:moves, plies}} <- out, ply <- plies, do: ply.san) == ~w(e4 e5)

      assert [{turn_at, out_of_turn}, {illegal_at, illegal}] =
               for({t, {:status, :out_of_sync, why}} <- out, do: {t, why})

      assert {:out_of_turn, %{colour: :b, san: "Nc6", piece: :n, from: b8, to: c6}} = out_of_turn
      assert {b8, c6} == {sq("b8"), sq("c6")}
      # Two seconds after the knight stood on c6 at 31:48.4, not eight.
      assert_in_delta turn_at, 1_910_400, 300

      assert {:illegal, %{piece: {:w, :b}, from: c1, to: g5, why: :blocked}} = illegal
      assert {c1, g5} == {sq("c1"), sq("g5")}
      assert_in_delta illegal_at, 1_926_300, 300

      # Each gone by itself when the piece went back.
      assert [knight_back, bishop_back] =
               for({t, {:status, :live, nil}} <- out, t > 1_910_000, do: t)

      assert_in_delta knight_back, 1_921_100, 300
      assert_in_delta bishop_back, 1_933_300, 300
    end

    test "twenty-four quiet minutes on a connected board are a player thinking", %{events: events} do
      refute Enum.any?(events, &match?({_t, :disconnected}, &1))
      until = Enum.take_while(events, fn {t, _event} -> t < 1_903_500 end)
      {session, _out} = Session.run(Session.new([]), until, tail_ms: 500)
      # 1...e5, read at 31:42.9, is a plain move after a long think.
      assert Tracker.sans(session.tracker) == ~w(e4 e5)
      refute session.tracker.deaf?
      assert List.last(session.tracker.plies).flags == []
    end

    test "to its end: the pieces are set up again, which two moves in is those two taken back" do
      assert {:ok, report} = Recorder.dry_run(@recording, [])
      assert report.moves == []
      assert report.status == :waiting_start
      assert [{_at, 0, [], :takeback}] = report.corrections
      # (A pawn going from e4 back to e2 is, for the second it stands
      # alone, a move that is not one; it does not stand long enough to
      # be called that.)
      assert [{:out_of_turn, _}, {:illegal, %{from: c1}}] = Enum.map(report.alarms, &elem(&1, 1))
      assert c1 == sq("c1")
    end
  end

  describe "the evidence rule" do
    test "a piece that stood on its square in every reading did not move, however much it would help" do
      # 1. e4 e5 and Black's knight to c6: two black moves. The bishop's
      # outing explains it in three legal moves.
      {tr, b, t} = after_moves(~w(e4 e5))
      seen = move(b, "b8", "c6")

      # Every legal move tried, there it is...
      {:ok, pos} = Chess.parse_fen(after_fen(~w(e4 e5)))
      assert {:ok, blind, _} = Search.find(pos, b, seen, min_depth: 2, max_depth: 3)
      assert blind == [], "a line out and back is not returned by any walk"

      # ...and with the knights' squares as the evidence, nothing either:
      # White has no piece that was seen to leave its square.
      assert {:ok, [], _} =
               Search.find(pos, b, seen,
                 min_depth: 2,
                 max_depth: 4,
                 evidence: [sq("b8"), sq("c6")]
               )

      {tr, out} = feed(tr, [{t, seen}], 20_000)
      assert Tracker.sans(tr) == ~w(e4 e5)
      assert [{:out_of_turn, %{san: "Nc6"}}] = alarms(out)
      refute Enum.any?(out, &match?({_, {:moves, _}}, &1))
    end

    test "a white tempo that is not a round trip is not made up either" do
      # The same, with the knight left on c6 for a minute: no "a3 Nc6",
      # no "Nf3 Nc6": the a-pawn and the g1 knight read at home throughout.
      {tr, b, t} = after_moves(~w(e4 e5))
      {tr, _out} = feed(tr, [{t, move(b, "b8", "c6")}], 70_000)
      assert Tracker.sans(tr) == ~w(e4 e5)
    end

    test "moves by pieces that were seen to leave their squares are found, whatever was not read between" do
      # A capture and its recapture on one square between two readings:
      # d5 reads a black pawn before and after. Both pawns that took are
      # gone from where they stood, and that is evidence enough.
      {tr, b, t} = after_moves(~w(e4 d5 c4 e6))
      seen = b |> lift("e4") |> lift("e6")
      # (After five seconds: until then it is as likely ...e6 being taken
      # back with a pawn in the other hand.)
      {tr, out} = feed(tr, [{t, seen}], 8_000)
      assert Enum.take(Tracker.sans(tr), -2) == ~w(exd5 exd5)
      assert alarms(out) == []
    end

    test "a piece that moved twice unread is followed from the square it left" do
      {tr, _b, t} = after_moves(~w(e4 e5))
      {tr, _out} = feed(tr, [{t, board(after_fen(~w(e4 e5 Bc4 a6 Bb5)))}], 8_000)
      # Two plies explain the board (Bb5 a6); the bishop left f1, the pawn a7.
      assert Enum.drop(Tracker.sans(tr), 2) == ~w(Bb5 a6)
    end

    test "\"the board is right\" does not find phantoms either" do
      {tr, b, t} = after_moves(~w(e4 e5))
      {tr, _out} = feed(tr, [{t, move(b, "b8", "c6")}], 20_000)
      assert {same, [], :none} = Tracker.resync(tr, t + 30_000, 6)
      assert Tracker.sans(same) == ~w(e4 e5)
    end

    test "nor does the choice screen offer one for a game that has one in it" do
      # The game as the box had it that morning, marks and all.
      flags = fn index -> if index in 2..4, do: [:guessed], else: [] end

      plies =
        ~w(e4 e5 Ba6 Nc6 Bf1 Nb8)
        |> Enum.with_index()
        |> Enum.map(fn {san, index} -> %{san: san, flags: flags.(index), at: 0} end)

      tr = Tracker.restore([], plies)
      assert %{current: ~w(Ba6 Nc6 Bf1), options: options} = Tracker.alternatives(tr, 4)
      # Nothing else leads there, and no other outing is invented to go with it.
      assert options == [~w(Ba6 Nc6 Bf1)]
    end
  end

  describe "a hole in what the box knows" do
    test "moves the readings do not support are considered only across one, and are red" do
      # 1. e4 e5, then 2. Nf3 Nc6 3. Nxe5 Nxe5 unread. The white knight is
      # gone and the black one stands on e5: g1, b8 and e5 changed, f3 and
      # c6 never read as anything but empty.
      {tr, _b, t} = after_moves(~w(e4 e5))
      seen = board(after_fen(~w(e4 e5 Nf3 Nc6 Nxe5 Nxe5)))

      {connected, out} = feed(tr, [{t, seen}], 8_000)
      assert Enum.drop(Tracker.sans(connected), 2) == ~w(Nf3 Nc6 Nxe5 Nxe5)
      # Found by the pieces that left their squares: g1 and b8. No gap.
      refute Enum.any?(connected.plies, &(:long_gap in &1.flags))
      assert alarms(out) == []

      {gone, _out} = feed(Tracker.deaf(tr), [{t, seen}], 8_000)
      assert Enum.drop(Tracker.sans(gone), 2) == ~w(Nf3 Nc6 Nxe5 Nxe5)
      marks = gone.plies |> Enum.drop(2) |> Enum.map(& &1.flags)
      assert Enum.all?(marks, &(:guessed in &1 and :long_gap in &1))
      refute gone.deaf?
    end

    test "`long_gap` is that hole, not several moves at once and not a long think" do
      {tr, _b, t} = after_moves(~w(e4 e5))
      seen = board(after_fen(~w(e4 e5 Nf3 Nc6 Nxe5)))

      # Three at once, an hour later, connected all the while.
      {tr, _out} = feed(tr, [{t + 3_600_000, seen}], 8_000)
      assert length(tr.plies) == 5
      assert Enum.all?(tr.plies, &(:long_gap not in &1.flags))
    end

    test "a board that comes back as it was has no hole to reason across" do
      {tr, b, t} = after_moves(~w(e4 e5))
      {tr, _} = Tracker.observe(Tracker.deaf(tr), t, b)
      refute tr.deaf?
    end

    test "the session calls a disconnection what it is" do
      session = Session.new([])
      {session, _} = Session.handle(session, 0, {:position, Position.start()})
      refute session.tracker.deaf?
      {session, _} = Session.handle(session, 1_000, :disconnected)
      assert session.tracker.deaf?
    end
  end

  describe "a move out of turn" do
    test "is named, with its squares, adds nothing, and is gone when the piece is back" do
      {tr, b, t} = after_moves(~w(e4 e5))
      there = move(b, "b8", "c6")

      {tr, out} = feed(tr, [{t, there}], 5_000)
      assert tr.status == :out_of_sync
      assert {:out_of_turn, %{colour: :b, san: "Nc6", from: from, to: to}} = tr.detail
      assert {from, to} == {sq("b8"), sq("c6")}
      assert [{at, _}] = for({at, {:status, :out_of_sync, why}} <- out, do: {at, why})
      assert at == t + tr.opts.unseen_hold_ms
      assert Tracker.sans(tr) == ~w(e4 e5)

      {tr, out} = feed(tr, [{t + 10_000, b}], 1_000)
      assert tr.status == :live and tr.detail == nil
      assert {t + 10_000, {:status, :live, nil}} in out
      assert Tracker.sans(tr) == ~w(e4 e5)

      # And the game goes on as if nothing had been.
      {tr, _} = feed(tr, [{t + 15_000, move(b, "g1", "f3")}], 1_000)
      assert Tracker.sans(tr) == ~w(e4 e5 Nf3)
      assert List.last(tr.plies).flags == []
    end

    test "a hand that is quicker than two seconds is nobody's alarm" do
      {tr, b, t} = after_moves(~w(e4 e5))
      {tr, out} = feed(tr, [{t, move(b, "b8", "c6")}, {t + 1_500, b}], 5_000)
      assert alarms(out) == []
      assert tr.status == :live
    end

    test "either side: White, on Black's time" do
      {tr, b, t} = after_moves(~w(e4 e5 Nf3 Nc6 Bc4 Bc5 O-O))
      # White has castled, and with Black to move plays d3 as well.
      {tr, out} = feed(tr, [{t, move(b, "d2", "d3")}], 5_000)
      assert [{:out_of_turn, %{colour: :w, san: "d3"}}] = alarms(out)
      assert length(tr.plies) == 7
    end
  end

  describe "a move that is not legal" do
    defp illegal(sans, change) do
      {tr, b, t} = after_moves(sans)
      {tr, out} = feed(tr, [{t, change.(b)}], 5_000)
      assert Tracker.sans(tr) == sans
      assert [{:illegal, move}] = alarms(out)
      {tr, b, t, move}
    end

    test "says the piece, the squares and why: something in the way" do
      {tr, b, t, move} = illegal(~w(e4 e5), &move(&1, "c1", "g5"))
      assert %{piece: {:w, :b}, why: :blocked} = move
      assert {move.from, move.to} == {sq("c1"), sq("g5")}

      # Gone when the bishop is back.
      {tr, out} = feed(tr, [{t + 10_000, b}], 1_000)
      assert tr.status == :live
      assert alarms(out) == []
    end

    test "that piece does not move like that" do
      {_tr, _b, _t, move} = illegal(~w(e4 e5), &move(&1, "g1", "g3"))
      assert %{piece: {:w, :n}, why: :shape} = move
    end

    test "a piece of its own side stands there" do
      {_tr, _b, _t, move} = illegal(~w(e4 e5), &(&1 |> lift("d1") |> put("d2", {:w, :q})))
      assert %{piece: {:w, :q}, why: :own_piece} = move
      assert {move.from, move.to} == {sq("d1"), sq("d2")}
    end

    test "it leaves its own king in check" do
      # 1. e4 e5 2. Qh5 Nc6 3. Qxf7+: Black is in check, and plays ...a6.
      {_tr, _b, _t, move} = illegal(~w(e4 e5 Qh5 Nc6 Qxf7+), &move(&1, "a7", "a6"))
      assert %{piece: {:b, :p}, why: :check} = move
    end

    test "more than one piece moved has no such name: unexplained, in its own time" do
      {tr, b, t} = after_moves(~w(e4 e5))
      mess = b |> move("c1", "g5") |> move("a2", "a5")
      {tr, out} = feed(tr, [{t, mess}], 10_000)
      assert alarms(out) == [:unexplained]
      assert Tracker.sans(tr) == ~w(e4 e5)
    end

    test "before the first move it is pieces being set up" do
      {tr, _} = Tracker.observe(Tracker.new(), 0, Position.start())
      {tr, out} = feed(tr, [{1_000, move(Position.start(), "c1", "g5")}], 20_000)
      assert alarms(out) == []
      assert tr.status == :waiting_start
    end
  end
end
