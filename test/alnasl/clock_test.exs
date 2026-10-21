defmodule Alnasl.ClockTest do
  @moduledoc """
  The press count, and the presses that only the times give away.
  """

  use ExUnit.Case, async: true

  alias Alnasl.Clock

  defp read(clock, readings) do
    Enum.reduce(readings, clock, fn {w, b, running}, clock ->
      {clock, _pressed?} = Clock.update(clock, 0, %{white_ms: w, black_ms: b, running: running})
      clock
    end)
  end

  test "a press is the running side changing" do
    clock = read(Clock.new(), [{60_000, 60_000, :white}, {58_000, 60_000, :black}])
    assert clock.presses == 1
  end

  test "the same side running, and the other side's time moved: two presses went by unseen" do
    clock = read(Clock.new(), [{60_000, 60_000, :black}, {57_000, 59_000, :black}])
    assert clock.presses == 2

    assert Clock.hidden_presses(read(Clock.new(), [{1, 2, :white}]), %{
             white_ms: 0,
             black_ms: 1,
             running: :white
           }) == 2
  end

  test "the side now running has more time than when it stopped: it pressed in between" do
    # White pressed, Black moved and pressed (and got the increment), White
    # pressed again: one change of side, three presses.
    clock = read(Clock.new(), [{60_000, 60_000, :white}, {85_000, 82_000, :black}])
    assert clock.presses == 3
  end

  test "the side now running with less time than it had is the one press it looks like" do
    clock = read(Clock.new(), [{60_000, 60_000, :white}, {85_000, 59_000, :black}])
    assert clock.presses == 1
  end

  test "an hourglass is recognised once, and its times count for nothing after" do
    clock =
      read(Clock.new(), [
        {60_000, 60_000, :white},
        {57_000, 63_000, :white},
        {57_000, 63_000, :black},
        {60_000, 60_000, :white}
      ])

    assert clock.hourglass?
    assert clock.presses == 2
  end

  test "the running side's own time moving is no press" do
    clock =
      read(Clock.new(), [
        {60_000, 60_000, :white},
        {59_000, 60_000, :white},
        {58_000, 60_000, :white}
      ])

    assert clock.presses == 0
  end

  test "a time put right while the clock stood still is no press" do
    clock =
      read(Clock.new(), [
        {60_000, 60_000, :white},
        {59_000, 60_000, :none},
        {59_000, 180_000, :none},
        {59_000, 180_000, :white}
      ])

    assert clock.presses == 0
  end

  test "an hourglass: the waiting side gains what the running side loses, and that is no press" do
    # (And the first such reading is enough to know it.)
    clock = read(Clock.new(), [{60_000, 60_000, :white}, {57_000, 63_000, :white}])
    assert clock.presses == 0
  end

  test "a clock switched off and on again starts its chain afresh" do
    clock = read(Clock.new(), [{60_000, 60_000, :white}])
    clock = Clock.off(clock, 0)
    clock = read(clock, [{59_000, 50_000, :white}])
    assert clock.presses == 0
  end
end
