defmodule Alnasl.MisreadMoveTest do
  @moduledoc """
  A move the board read wrong, and the lines the box will not make up.

  Board 06310, 2026-10-12: White played 3. d4 and set the pawn down so close
  to d3 that the board read d3. Then 3...e5 4. dxe5 - which from d3 a pawn
  cannot do. The reconstruction, which only knew how to add moves, got the
  pawn to d4 by having it move again and passed the time with a bishop to a3
  and back: `3. d3 e5 4. d4 Ba3 5. dxe5 Bf8`, ten moves to seven presses of
  the clock. The recording is the first test.
  """

  use ExUnit.Case, async: true

  alias Alnasl.{Chess, Position, Recorder, Session, Tracker}

  @recording "test/fixtures/captures/real-06310-misread-pawn.jsonl"
  @played ~w(e4 Nc6 Nc3 Nf6 d4 e5 dxe5)

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

  # 1. e4 Nc6 2. Nc3 Nf6 3. d3 (read; really d4) e5, as the box has it, and
  # the board as it reads once the pawn has taken on e5.
  defp misread(opts \\ []) do
    {tr, b, t} = after_moves(~w(e4 Nc6 Nc3 Nf6 d3 e5), opts)
    {tr, b |> lift("d3") |> put("e5", {:w, :p}), t}
  end

  describe "the recording" do
    test "reads as the game that was played: 3. d4 rewritten, no bishop anywhere, live" do
      assert {:ok, report} = Recorder.dry_run(@recording, [])
      assert report.moves == @played
      assert report.status == :live and report.alarms == []
      refute "Ba3" in report.moves

      [_, _, _, _, d4, e5, dxe5] = report.plies
      assert :rewritten in d4.flags and d4.read == "d3"
      # One explanation of its kind, and as many moves as presses: orange.
      assert :recovered in d4.flags and :recovered in dxe5.flags
      assert e5.flags == []
      assert report.presses == 7

      assert [{at, 4, ~w(d4 e5 dxe5), :misread}] = report.corrections
      # When the pawn landed on e5, not five seconds of looking later.
      assert_in_delta at, 77_150, 400
    end

    test "the choice screen has the move as it was read, and nothing with a bishop in it" do
      {:ok, capture} = Recorder.read(@recording)
      {session, _out} = Session.run(Session.new([]), capture.events, tail_ms: 5_500)
      tr = session.tracker

      assert %{from: 5, to: 7, read: {5, "d3"}, current: ~w(d4 e5 dxe5), options: options} =
               Tracker.alternatives(tr, 5)

      assert hd(options) == ~w(d4 e5 dxe5)
      assert ~w(d3 e5) in options
      refute Enum.any?(options, &("Ba3" in &1))
      # Asked from either end of it.
      assert Tracker.alternatives(tr, 7) == Tracker.alternatives(tr, 5)

      # The arbiter says it was d3 after all: his word, and the board is
      # then what it is - not the game's, and the alarm in time.
      assert {:ok, {tr, _events}, 0} = Tracker.choose(tr, 300_000, 5, ~w(d3 e5))
      assert Tracker.sans(tr) == ~w(e4 Nc6 Nc3 Nf6 d3 e5)
      assert Enum.all?(Enum.take(tr.plies, -2), &(&1.flags == [:arbiter]))
    end
  end

  describe "a move misread" do
    test "is rewritten when the piece moves on from where it really stood" do
      {tr, seen, t} = misread()
      {tr, out} = feed(tr, [{t, seen}], 1_000)

      assert Tracker.sans(tr) == @played
      assert alarms(out) == []
      assert tr.status == :live and tr.raw == tr.pos.board

      assert [{_at, {:correction, 4, [first, second, third], :misread}}] =
               Enum.filter(out, &match?({_, {:correction, _, _, _}}, &1))

      assert %{san: "d4", read: "d3", span: 3} = first
      assert :rewritten in first.flags
      assert second.san == "e5" and second.flags == []
      assert third.san == "dxe5"
      # No clock told how many moves were made: a guess, the only one.
      assert :guessed in first.flags and :alone in first.flags
    end

    test "is orange when the clock agrees: as many presses as moves" do
      {tr, seen, t} = misread()
      {tr, _out} = feed(Tracker.presses(tr, 6, t - 100), [{t, seen}], 1_000)
      assert [:rewritten, :recovered] = Enum.at(tr.plies, 4).flags
      assert [:recovered] = List.last(tr.plies).flags

      # And survives a restart: what it was read as is part of the game.
      plies = Enum.map(tr.plies, &Map.take(&1, [:san, :flags, :at, :read, :span]))
      restored = Tracker.restore([], plies)
      assert Enum.at(restored.plies, 4).read == "d3"
      assert %{read: {5, "d3"}} = Tracker.alternatives(restored, 6)
    end

    test "is rewritten when the piece is taken where it really stood" do
      # 1. e4 e5 2. d3 (really d4) and Black takes: exd4.
      {tr, b, t} = after_moves(~w(e4 e5 d3))
      seen = b |> lift("d3") |> move("e5", "d4")
      {tr, out} = feed(tr, [{t, seen}], 1_000)
      assert Tracker.sans(tr) == ~w(e4 e5 d4 exd4)
      assert alarms(out) == []
    end

    test "is rewritten when somebody straightens the piece on the other side's time" do
      # The pawn goes from d3 to d4 with Black to move: not a move of
      # White's. It was on d4 all along.
      {tr, b, t} = after_moves(~w(e4 Nc6 Nc3 Nf6 d3))
      {tr, out} = feed(tr, [{t, move(b, "d3", "d4")}], 1_000)
      assert Tracker.sans(tr) == ~w(e4 Nc6 Nc3 Nf6 d4)
      assert alarms(out) == []
      # The oldest rule of that kind: the last move, replaced.
      assert Enum.any?(out, &match?({_, {:correction, 4, [%{san: "d4"}], :revised}}, &1))
    end

    test "straightened on its own side's time it reads as a move - until that side moves again" do
      # ...e5 has been played; White straightens the pawn (d3-d4 is legal,
      # and is taken for White's move), and then plays Nf3.
      {tr, b, t} = after_moves(~w(e4 Nc6 Nc3 Nf6 d3 e5))
      straight = move(b, "d3", "d4")
      {tr, _} = feed(tr, [{t, straight}], 1_000)
      assert List.last(Tracker.sans(tr)) == "d4"
      assert length(tr.plies) == 7

      {tr, out} = feed(tr, [{t + 5_000, move(straight, "g1", "f3")}], 1_000)
      assert Tracker.sans(tr) == ~w(e4 Nc6 Nc3 Nf6 d4 e5 Nf3)
      assert alarms(out) == []
      assert Enum.at(tr.plies, 4).read == "d3"
    end

    test "still standing crooked, a move that only makes sense with it on its real square finds it out" do
      # 1. e4 e5 2. Bc4, read on d3, Nf6 3. d4: the pawn jumps over d3,
      # which it can with the bishop on c4 and cannot with it on d3. The
      # bishop has not moved; the board still reads it on d3.
      {tr, b, t} = after_moves(~w(e4 e5 Bd3 Nf6))
      seen = move(b, "d2", "d4")
      {tr, out} = feed(tr, [{t, seen}], 3_000)

      assert Tracker.sans(tr) == ~w(e4 e5 Bc4 Nf6 d4)
      assert alarms(out) == []
      assert Enum.at(tr.plies, 2).read == "Bd3"

      # The bishop is carried as "read on d3, standing on c4"...
      assert [%{square: c4, ghost: d3, piece: {:w, :b}}] = Tracker.unseen(tr)
      assert {c4, d3} == {sq("c4"), sq("d3")}
      assert tr.status == :live

      # ...and when it moves on, the board shows it leave d3.
      next = move(seen, "b8", "c6")
      taken = next |> lift("d3") |> put("f7", {:w, :b})
      {tr, out} = feed(tr, [{t + 5_000, next}, {t + 10_000, taken}], 1_000)
      assert Enum.take(Tracker.sans(tr), -2) == ~w(Nc6 Bxf7+)
      assert Tracker.unseen(tr) == []
      assert alarms(out) == []
    end

    test "that only needs waiting for must itself stand: a queen resting on her way is not proof" do
      {tr, b, t} = after_moves(~w(e4 e5 Bd3 Nf6))
      seen = move(b, "d2", "d4")
      {early, _} = feed(tr, [{t, seen}], 1_500)
      assert Tracker.sans(early) == ~w(e4 e5 Bd3 Nf6)
    end

    test "a castle is never rewritten" do
      {tr, b, t} = after_moves(~w(e4 e5 Nf3 Nc6 Bc4 Bc5 O-O Nf6))
      # King and rook put on each other's squares for a moment.
      swapped = b |> put("f1", {:w, :k}) |> put("g1", {:w, :r})
      {tr, _out} = feed(tr, [{t, swapped}, {t + 2_000, b}], 1_000)
      assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6 Bc4 Bc5 O-O Nf6)
      assert Enum.all?(tr.plies, &(&1.flags == []))
    end

    test "not possible - no neighbouring square does it - is what it was before: the alarm" do
      # A rook through its own pawn, as ever.
      {tr, b, t} = after_moves(~w(e4 e5))
      {tr, out} = feed(tr, [{t, move(b, "a1", "a3")}], 10_000)
      assert Tracker.sans(tr) == ~w(e4 e5)
      assert [{:illegal, %{piece: {:w, :r}, why: :blocked}}] = alarms(out)

      # Switched off, the misread pawn is the old story: nothing found at
      # once, and after five seconds the bishop's outing - unless the clock
      # forbids it, as in the next tests.
      {tr, seen, t} = misread(misread: false)
      {tr, _out} = feed(tr, [{t, seen}], 1_000)
      assert Tracker.sans(tr) == ~w(e4 Nc6 Nc3 Nf6 d3 e5)
    end
  end

  describe "which line" do
    test "one move rewritten and one added beats four made up" do
      # After five seconds the blind search has its four moves too.
      {tr, seen, t} = misread()
      {tr, _out} = feed(tr, [{t, seen}], 8_000)
      assert Tracker.sans(tr) == @played
    end

    test "with the rewrite switched off the board says what it shows, and nobody's bishop is sent out to explain it" do
      # Six moves, six presses; the bishop's outing would make ten - and
      # the bishop never left f8 in any reading.
      {tr, seen, t} = misread(misread: false)
      tr = Tracker.presses(tr, 6, t - 100)
      {tr, out} = feed(tr, [{t, seen}, {t + 900, :press}], 10_000)

      assert Tracker.sans(tr) == ~w(e4 Nc6 Nc3 Nf6 d3 e5)
      assert [{:illegal, %{piece: {:w, :p}, why: :shape}}] = alarms(out)

      # Not even when the arbiter asks: "the board is right" finds moves
      # the readings support, and there are none.
      assert {same, [], :none} = Tracker.resync(tr, t + 20_000, 6)
      assert Tracker.sans(same) == Tracker.sans(tr)
    end

    test "the same without a clock" do
      {tr, seen, t} = misread(misread: false)
      {tr, out} = feed(tr, [{t, seen}], 10_000)
      assert Tracker.sans(tr) == ~w(e4 Nc6 Nc3 Nf6 d3 e5)
      assert [{:illegal, _}] = alarms(out)
    end

    test "nor while another line does without it" do
      # 1. e4 e5 and then, unseen, 2. Nf3 Nc6: one line. With the knights
      # out and back in between there are more, and none is offered.
      {tr, _b, t} = after_moves(~w(e4 e5))
      {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4 e5 Nf3 Nc6))
      {tr, _out} = feed(tr, [{t, board(List.last(plies).fen)}], 8_000)
      assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6)
      assert Enum.all?(Enum.take(tr.plies, -2), &(&1.flags == [:recovered]))
    end

    test "a debt of presses is allowed for: players who forget the lever are not made to pay twice" do
      # Two presses forgotten earlier in the game: four moves, two presses.
      {tr, _b, t} = after_moves(~w(e4 e5 Nf3 Nc6))
      tr = Tracker.presses(tr, 1, 1_000)
      tr = Tracker.presses(tr, 2, t - 100)
      assert tr.debt == 2

      {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4 e5 Nf3 Nc6 Bc4 Bc5))
      {tr, out} = feed(tr, [{t, board(List.last(plies).fen)}], 1_000)
      assert Tracker.sans(tr) == ~w(e4 e5 Nf3 Nc6 Bc4 Bc5)
      assert alarms(out) == []
    end

    test "a board that was not heard is not measured against a clock that was not heard either" do
      {tr, _b, t} = after_moves(~w(e4 e5))
      tr = tr |> Tracker.presses(2, t - 100) |> Tracker.deaf()
      {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4 e5 Nf3 Nc6 Nxe5 Nxe5))
      {tr, out} = feed(tr, [{t, board(List.last(plies).fen)}], 8_000)
      assert length(Tracker.sans(tr)) == 6
      assert alarms(out) == []
      # What it added is debt now, not a reason to refuse the next line.
      assert tr.debt >= 3
    end
  end

  describe "what the arbiter is offered for the game as the box had it that morning" do
    # `3. d3 e5 4. d4 Ba3 5. dxe5 Bf8`, the last four guessed.
    setup do
      flags = fn index -> if index >= 6, do: [:guessed, :alone, :long_gap], else: [] end

      plies =
        ~w(e4 Nc6 Nc3 Nf6 d3 e5 d4 Ba3 dxe5 Bf8)
        |> Enum.with_index()
        |> Enum.map(fn {san, index} -> %{san: san, flags: flags.(index), at: 0} end)

      {:ok, tracker: Tracker.restore([], plies)}
    end

    test "the misread pawn first, ahead of the line as it stands", %{tracker: tr} do
      assert %{from: 5, to: 10, current: current, options: [first | _] = options} =
               Tracker.alternatives(tr, 8)

      assert current == ~w(d3 e5 d4 Ba3 dxe5 Bf8)
      assert first == ~w(d4 e5 dxe5)
      assert List.last(options) == current
      assert length(options) <= 64
    end

    test "choosing it is the game that was played", %{tracker: tr} do
      assert {:ok, {tr, [{:correction, 4, _plies, :arbiter} | _]}, 0} =
               Tracker.choose(tr, 1_000, 8, ~w(d4 e5 dxe5))

      assert Tracker.sans(tr) == @played
    end
  end
end
