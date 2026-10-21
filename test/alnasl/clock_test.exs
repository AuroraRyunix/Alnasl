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
