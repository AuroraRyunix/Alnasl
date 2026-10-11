defmodule Alnasl.Session do
  @moduledoc """
  One game on one board: the tracker and the clock together.

  Still pure. It takes what a driver delivers - `{:position, board}`,
  `{:clock, reading}`, `{:info, %{clock: false}}` (the clock was switched
  off), `:connected`, `:disconnected` - and time passing, and returns the
  tracker's events with three additions:

  - every accepted ply carries the clock as it read when it was accepted
    (`ply.clock`, or `nil` without a clock);
  - `{:warning, :move_missing, presses, plies}` when the clock has been
    pressed at least twice more often than moves were seen, and
    `{:warning_cleared, :move_missing}` when the moves have caught up;
  - `{:warning, :clock_side, side}` the moment a clock RUNS on the wrong
    side with the pieces in the starting position and no move made (`side` is the one
    running: `:black`, in every game that White begins), and
    `{:warning_cleared, :clock_side}` when it has been put right.

  ## The clock alarm

  The clock's sides are fixed (`Alnasl.Clock`), so Black's time running
  before White has moved means the clock is turned round or was started
  with the lever the wrong way. It is an alarm about the clock, not about
  the pieces: the tracker goes on reading the moves, and their clock times
  are the wrong way round until somebody acts. It clears by itself:

  - before the first move, as soon as the right side runs, or the clock
    stands still with its lever the right way, or is switched off;
    (a lever pressed over to the wrong side with the pieces untouched is
    NOT this alarm: that is a first move the board did not see, and the
    press is counted toward "a move is missing")
  - once moves have been made, at the first press of the lever after which
    the running side is the side to move. With the clock still turned round
    every press leaves the wrong side running, so it stays.

  A clock that merely stands still the wrong way before the game is not an
  alarm: that is the starting-position check (`clock_check/1`), which the
  site shows beside the check of the pieces.

  `run/3` plays a whole list of timed events through it, ticking at the
  tracker's own deadlines: the test bench, and the dry run of a recording.
  """

  alias Alnasl.{Clock, Tracker}

  defstruct tracker: nil, clock: Clock.new(), missing?: false, clock_alarm: nil

  @type t :: %__MODULE__{}

  def new(opts \\ []), do: %__MODULE__{tracker: Tracker.new(opts)}

  @doc "A session for a stored game."
  def restore(opts, plies), do: %__MODULE__{tracker: Tracker.restore(opts, plies)}

  @spec handle(t(), integer(), term()) :: {t(), [tuple()]}
  def handle(%__MODULE__{} = session, t, {:position, board}) do
    session.tracker |> Tracker.observe(t, board) |> wrap(session, t)
  end

  def handle(%__MODULE__{} = session, t, {:clock, reading}) do
    {clock, pressed?} = Clock.update(session.clock, t, reading)

    # The press that puts a wrongly started clock right before the first
    # move is somebody setting the clock, not a move: it is not counted
    # toward "a move is missing".
    clock =
      if pressed? and session.clock_alarm != nil and session.tracker.plies == [] and
           clock.running == to_move(session.tracker),
         do: %{clock | presses: clock.presses - 1},
         else: clock

    # More presses than moves is how the reconstruction knows the board
    # has run further ahead than the shortest explanation says.
    session = %{session | clock: clock, tracker: Tracker.presses(session.tracker, clock.presses)}

    {session, events} =
      cond do
        not pressed? ->
          session |> check_missing([]) |> check_clock(false)

        # A press confirms the move that stands on the board only when it
        # is that move's press: the mover's clock stopped, the other side's
        # runs. A clock tells what happened up to a second late, and in
        # fast play the press of the move before arrives when the next
        # piece is already down - on a square where a rook may only be
        # resting on its way to castling.
        clock.running in [:none, to_move(session.tracker)] ->
          session.tracker |> Tracker.tick(t) |> wrap(session, t, true)

        true ->
          session.tracker |> Tracker.press(t) |> wrap(session, t, true)
      end

    {session, [{:clock, Clock.read(clock, t)} | events]}
  end

  # The clock was switched off or unplugged: a board without a clock again.
  def handle(%__MODULE__{} = session, t, {:info, %{clock: false}}) do
    %{session | clock: Clock.off(session.clock, t)} |> check_missing([]) |> check_clock(false)
  end

  def handle(%__MODULE__{} = session, t, :tick) do
    session.tracker |> Tracker.tick(t) |> wrap(session, t)
  end

  def handle(%__MODULE__{} = session, _t, _other), do: {session, []}

  @doc "Applies a tracker operation (`fn tracker -> {tracker, events} end`) made by the arbiter."
  def with_tracker(%__MODULE__{} = session, t, fun),
    do: session.tracker |> fun.() |> wrap(session, t)

  def deadline(%__MODULE__{tracker: tracker}), do: Tracker.deadline(tracker)

  @doc """
  The clock's part of the starting-position check: `nil` (no clock, or the
  game is under way), `:ok`, or `{:wrong, side}` - see
  `Alnasl.Clock.start_check/2`.
  """
  def clock_check(%__MODULE__{tracker: %{plies: []} = tracker, clock: clock}),
    do: Clock.start_check(clock, to_move(tracker))

  def clock_check(%__MODULE__{}), do: nil

  defp to_move(%{pos: %{turn: :b}}), do: :black
  defp to_move(_tracker), do: :white

  defp wrap({tracker, events}, session, t, pressed? \\ false) do
    reading = Clock.read(session.clock, t)

    events =
      Enum.map(events, fn
        {:moves, plies} -> {:moves, stamp(plies, reading)}
        {:correction, keep, plies, reason} -> {:correction, keep, stamp(plies, reading), reason}
        other -> other
      end)

    %{session | tracker: tracker} |> check_missing(events) |> check_clock(pressed?)
  end

  defp stamp([], _reading), do: []

  defp stamp(plies, reading) do
    clock = reading && Map.take(reading, [:white_ms, :black_ms])
    {earlier, [last]} = Enum.split(plies, -1)
    Enum.map(earlier, &Map.put(&1, :clock, nil)) ++ [Map.put(last, :clock, clock)]
  end

  defp check_clock({session, events}, pressed?) do
    clock = session.clock
    to_move = to_move(session.tracker)
    started? = session.tracker.plies != []
    # The pieces stand as the game begins: before that, a clock running the
    # wrong way is one more thing not set up yet, not a game going wrong.
    at_start? = session.tracker.raw == session.tracker.pos.board

    alarm =
      cond do
        not Clock.present?(clock) -> nil
        not started? and Clock.start_check(clock, to_move) == :ok -> nil
        # Started there, not pressed over to there: a lever pressed to the
        # wrong side over untouched pieces is a first move the board did
        # not see, and "Move missing?" has that.
        not started? and at_start? and clock.started not in [nil, to_move] -> clock.running
        started? and pressed? and clock.running == to_move -> nil
        true -> session.clock_alarm
      end

    cond do
      alarm == session.clock_alarm ->
        {session, events}

      alarm == nil ->
        {%{session | clock_alarm: nil}, events ++ [{:warning_cleared, :clock_side}]}

      true ->
        {%{session | clock_alarm: alarm}, events ++ [{:warning, :clock_side, alarm}]}
    end
  end

  defp check_missing(session, events) do
    presses = session.clock.presses
    plies = length(session.tracker.plies)
    missing? = Clock.present?(session.clock) and presses >= plies + 2

    cond do
      missing? and not session.missing? ->
        {%{session | missing?: true}, events ++ [{:warning, :move_missing, presses, plies}]}

      session.missing? and not missing? ->
        {%{session | missing?: false}, events ++ [{:warning_cleared, :move_missing}]}

      true ->
        {session, events}
    end
  end

  @doc """
  Plays `timed` (`[{t, event}]`, in time order) through `session`, ticking at
  every deadline on the way and for `:tail_ms` (70 s) after the last event.
  Returns `{session, [{t, event}]}` with everything that came out.
  """
  @spec run(t(), [{integer(), term()}], keyword()) :: {t(), [{integer(), tuple()}]}
  def run(%__MODULE__{} = session, timed, opts \\ []) do
    tail = Keyword.get(opts, :tail_ms, 70_000)

    {session, out, last} =
      Enum.reduce(timed, {session, [], 0}, fn {t, event}, {session, out, _last} ->
        {session, out} = tick_until(session, t, out)
        {session, events} = handle(session, t, event)
        {session, prepend(out, t, events), t}
      end)

    {session, out} = tick_until(session, last + tail, out)
    {session, Enum.reverse(out)}
  end

  defp tick_until(session, t, out) do
    case deadline(session) do
      due when is_integer(due) and due < t ->
        {session, events} = handle(session, due, :tick)
        tick_until(session, t, prepend(out, due, events))

      _none ->
        {session, out}
    end
  end

  defp prepend(out, t, events), do: Enum.reduce(events, out, &[{t, &1} | &2])
end
