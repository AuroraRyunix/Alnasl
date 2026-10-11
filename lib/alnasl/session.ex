defmodule Alnasl.Session do
  @moduledoc """
  One game on one board: the tracker and the clock together.

  Still pure. It takes what a driver delivers - `{:position, board}`,
  `{:clock, reading}`, `:connected`, `:disconnected` - and time passing, and
  returns the tracker's events with two additions:

  - every accepted ply carries the clock as it read when it was accepted
    (`ply.clock`, or `nil` without a clock);
  - `{:warning, :move_missing, presses, plies}` when the clock has been
    pressed at least twice more often than moves were seen, and
    `{:warning_cleared, :move_missing}` when the moves have caught up.

  `run/3` plays a whole list of timed events through it, ticking at the
  tracker's own deadlines: the test bench, and the dry run of a recording.
  """

  alias Alnasl.{Clock, Tracker}

  defstruct tracker: nil, clock: Clock.new(), missing?: false

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
    session = %{session | clock: clock}

    {session, events} =
      if pressed?,
        do: session.tracker |> Tracker.press(t) |> wrap(session, t),
        else: check_missing(session, [])

    {session, [{:clock, Clock.read(clock, t)} | events]}
  end

  def handle(%__MODULE__{} = session, t, :tick) do
    session.tracker |> Tracker.tick(t) |> wrap(session, t)
  end

  def handle(%__MODULE__{} = session, _t, _other), do: {session, []}

  @doc "Applies a tracker operation (`fn tracker -> {tracker, events} end`) made by the arbiter."
  def with_tracker(%__MODULE__{} = session, t, fun), do: session.tracker |> fun.() |> wrap(session, t)

  def deadline(%__MODULE__{tracker: tracker}), do: Tracker.deadline(tracker)

  defp wrap({tracker, events}, session, t) do
    reading = Clock.read(session.clock, t)

    events =
      Enum.map(events, fn
        {:moves, plies} -> {:moves, stamp(plies, reading)}
        {:correction, keep, plies, reason} -> {:correction, keep, stamp(plies, reading), reason}
        other -> other
      end)

    check_missing(%{session | tracker: tracker}, events)
  end

  defp stamp([], _reading), do: []

  defp stamp(plies, reading) do
    clock = reading && Map.take(reading, [:white_ms, :black_ms])
    {earlier, [last]} = Enum.split(plies, -1)
    Enum.map(earlier, &Map.put(&1, :clock, nil)) ++ [Map.put(last, :clock, clock)]
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
