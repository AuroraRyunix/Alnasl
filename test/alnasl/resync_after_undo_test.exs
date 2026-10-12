defmodule Alnasl.ResyncAfterUndoTest do
  @moduledoc """
  The evening of 2026-10-11 on board 06310, with the arbiter's part in it.

  The box's log: 22:15:59 out of sync (the knight that had been parked
  beside the board for five moves came down on e5, six plies ahead of the
  game); 22:16:07 "The board is right" - nine orders of those six moves
  were listed and the arbiter picked `Nc6 Ne5 e6 Be3 Bb4 Qc1`, which is
  not the order they were played in; 22:17:36 the moves taken back one by
  one; later "The board is right" again, and again.

  What "it pulls up past moves" was: after an Undo the board still shows
  the moves taken back, the search starts from the shortened game, and the
  one path it finds is the moves just taken back - put back without a
  word. Two things are different now, and this is the test of both:

  - the six moves are found by themselves, in the order the readings show
    (each was read as it landed), marked as a guess because other orders
    are legal;
  - moves the arbiter takes back are not what the next search returns.

  The unseen-piece rule is switched off here: with it the board never
  falls behind in the first place (`unseen_piece_test.exs`).
  """

  use ExUnit.Case, async: true

  alias Alnasl.{Recorder, Session, Tracker}

  @recording "test/fixtures/captures/real-06310-unseen-knight.jsonl"
  @played ~w(Nc6 Be3 e6 Qc1 Bb4 Ne5)
  @picked ~w(Nc6 Ne5 e6 Be3 Bb4 Qc1)

  # The recording up to 4:44 (22:16:07), when the arbiter first acted: the
  # knight has landed, Black has not yet answered.
  setup do
    {:ok, capture} = Recorder.read(@recording)
    events = Enum.take_while(capture.events, fn {t, _event} -> t < 284_000 end)
    session = Session.new(settle_ms: 150, unseen_piece: false)
    {session, out} = Session.run(session, events, tail_ms: 0)
    {:ok, tracker: session.tracker, out: out}
  end

  test "the six moves are reconstructed in the order they were played, and marked as a guess", %{
    tracker: tr,
    out: out
  } do
    assert Tracker.sans(tr) == ~w(d4 d5 Nc3 Nf6 Nf3) ++ @played
    assert tr.status == :live
    assert for({_t, {:status, :out_of_sync, why}} <- out, do: why) == []

    marks = Enum.map(tr.plies, &(:guessed in &1.flags))
    assert marks == List.duplicate(false, 5) ++ List.duplicate(true, 6)

    # At the knight's landing, 4:28, and not eight seconds of alarm later.
    assert [{at, _}] = for({t, {:moves, [_, _, _ | _]}} <- out, do: {t, :found})
    assert_in_delta at, 268_300, 500
  end

  test "the other orders are there for the arbiter, the one he picked that night among them", %{
    tracker: tr
  } do
    assert %{from: 6, to: 11, current: @played, options: [@played | others]} =
             Tracker.alternatives(tr, 8)

    assert @picked in others
    # Nine that night; the same nine now.
    assert length(others) == 8
  end

  test "picking another order rewrites the game from there", %{tracker: tr} do
    {:ok, {tr, events}, 0} = Tracker.choose(tr, 367_000, 6, @picked)
    assert Tracker.sans(tr) == ~w(d4 d5 Nc3 Nf6 Nf3) ++ @picked
    assert [{:correction, 5, plies, :arbiter} | _] = events
    assert Enum.all?(plies, &(&1.flags == [:arbiter]))
  end

  test "moves taken back are not put back by the next search", %{tracker: tr} do
    {:ok, {tr, _events}, 0} = Tracker.choose(tr, 367_000, 6, @picked)

    # Two of them taken back. The board still shows them, and they are the
    # only two moves that lead to it from here: that used to be "found".
    {tr, _} = Tracker.undo(tr, 373_000)
    {tr, _} = Tracker.undo(tr, 373_800)
    assert Enum.take(Tracker.sans(tr), -2) == ~w(e6 Be3)

    assert {same, [], {:rejected, ~w(Bb4 Qc1)}} = Tracker.resync(tr, 380_000, 6)
    assert Tracker.sans(same) == Tracker.sans(tr)

    # Nor by the tracker itself, however long the board stands like that.
    {later, events} = Tracker.tick(tr, 460_000)
    assert Tracker.sans(later) == Tracker.sans(tr)
    refute Enum.any?(events, &match?({:moves, _}, &1))

    # All six taken back: what is found now is another order - the one the
    # readings show.
    tr = Enum.reduce(0..3, tr, fn i, tr -> tr |> Tracker.undo(381_000 + i * 800) |> elem(0) end)
    assert Tracker.sans(tr) == ~w(d4 d5 Nc3 Nf6 Nf3)
    assert tr.rejected == %{count: 5, sans: @picked}

    assert {tr, _events, {:guessed, @played, 7}} = Tracker.resync(tr, 390_000, 6)
    assert Tracker.sans(tr) == ~w(d4 d5 Nc3 Nf6 Nf3) ++ @played
    # A move accepted: nothing is held against the position any more.
    assert tr.rejected == nil
  end

  test "a move typed by the arbiter may be one he took back" do
    tr = Tracker.new()
    {tr, _} = Tracker.observe(tr, 0, Alnasl.Position.start())
    {:ok, {tr, _}} = Tracker.append(tr, 1_000, ~w(e4 e5))
    {tr, _} = Tracker.undo(tr, 2_000)
    assert tr.rejected == %{count: 1, sans: ~w(e5)}
    {:ok, {tr, _}} = Tracker.append(tr, 3_000, ~w(e5))
    assert Tracker.sans(tr) == ~w(e4 e5)
    assert tr.rejected == nil
  end
end
