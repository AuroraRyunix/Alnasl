defmodule Alnasl.Clock do
  @moduledoc """
  What the chess clock on a board says: both times, which side runs, and how
  often it has been pressed.

  Pure, like the tracker. A reading is `%{white_ms, black_ms, running}` with
  `running` one of `:white | :black | :none`, and - from a driver that can
  tell - `armed`: the side whose time runs or, on a clock standing still,
  will run when it is started (`:white | :black`). A **press** is the running
  side changing from one player to the other; the count of presses is
  compared with the count of moves, because a press without a move is the
  earliest sign that the board missed one.

  A board without a clock never sends a reading; `read/2` is then `nil` and
  nothing about clocks is reported. A clock that is switched off or
  unplugged (`off/2`) is a board without a clock again, until it reports.

  ## Sides

  White's side of the clock is fixed: the clock stands to the right of the
  board, White's display toward ranks 1-2 (the cable is too short for
  anything else, and DGT's own software assumes the same). So nothing here
  swaps sides or guesses colours. A clock that is turned round, or whose
  lever is the wrong way, is found by `start_check/2` before the game and
  raised as an alarm of its own if the game starts anyway.
  """

  defstruct white_ms: nil,
            black_ms: nil,
            running: :none,
            armed: nil,
            started: nil,
            at: nil,
            presses: 0,
            off?: false

  @type t :: %__MODULE__{}
  @type reading :: %{white_ms: integer(), black_ms: integer(), running: atom()}
  @type side :: :white | :black

  # `started` is the side the clock was running on when it last went from
  # standing still (or from not being there) to running: `nil` while it
  # stands still. A press of the lever does not change it - which is how a
  # clock STARTED on Black's side is told from one that White pressed.

  def new, do: %__MODULE__{}

  @doc "Is a clock attached - has one reported, and not been switched off since?"
  def present?(%__MODULE__{at: at, off?: off?}), do: at != nil and not off?

  @doc "Takes a reading at time `t`. `{clock, pressed?}`."
  @spec update(t(), integer(), map()) :: {t(), boolean()}
  def update(%__MODULE__{} = clock, t, reading) do
    running = Map.get(reading, :running, :none)

    pressed? =
      clock.running in [:white, :black] and running in [:white, :black] and
        running != clock.running

    {%{
       clock
       | white_ms: Map.get(reading, :white_ms, clock.white_ms),
         black_ms: Map.get(reading, :black_ms, clock.black_ms),
         running: running,
         armed: Map.get(reading, :armed),
         started:
           cond do
             running == :none -> nil
             clock.running in [:white, :black] and not clock.off? -> clock.started
             true -> running
           end,
         at: t,
         off?: false,
         presses: clock.presses + if(pressed?, do: 1, else: 0)
     }, pressed?}
  end

  @doc """
  The clock was switched off or unplugged at `t`. Nothing runs and nothing
  is read from it until it reports again; the presses counted so far stay.
  """
  @spec off(t(), integer()) :: t()
  def off(%__MODULE__{at: nil} = clock, _t), do: clock

  def off(%__MODULE__{} = clock, t) do
    now = read(clock, t)

    %{
      clock
      | white_ms: (now && now.white_ms) || clock.white_ms,
        black_ms: (now && now.black_ms) || clock.black_ms,
        running: :none,
        armed: nil,
        started: nil,
        at: t,
        off?: true
    }
  end

  @doc "The clock as it reads at `t`: the running side counted down since the last reading."
  @spec read(t(), integer()) :: reading() | nil
  def read(%__MODULE__{at: nil}, _t), do: nil
  def read(%__MODULE__{off?: true}, _t), do: nil

  def read(%__MODULE__{} = clock, t) do
    gone = max(t - clock.at, 0)

    %{
      white_ms: down(clock.white_ms, clock.running == :white, gone),
      black_ms: down(clock.black_ms, clock.running == :black, gone),
      running: clock.running
    }
  end

  defp down(nil, _running?, _gone), do: nil
  defp down(ms, true, gone), do: max(ms - gone, 0)
  defp down(ms, false, _gone), do: ms

  @doc """
  The side whose time runs, or will run when the clock is started: the
  running side, or on a clock standing still the side its lever is set for.
  `nil` without a clock, and for a clock standing still that does not say.
  """
  @spec first(t()) :: side() | nil
  def first(%__MODULE__{} = clock) do
    cond do
      not present?(clock) -> nil
      clock.running in [:white, :black] -> clock.running
      true -> clock.armed
    end
  end

  @doc """
  The clock's part of the starting-position check, for a game in which
  `to_move` (`:white`, or `:black` for a game from a set position) makes the
  first move:

  - `nil` - no clock attached: nothing to check;
  - `:ok` - the clock is set so that `to_move`'s time runs first: it stands
    still with the lever on that side, or it already runs on that side;
  - `{:wrong, side}` - the other side's time runs or would run first: the
    clock is turned round, or its lever is the wrong way.

  A clock standing still that does not say where its lever is (a simulated
  one) passes.
  """
  @spec start_check(t(), side()) :: nil | :ok | {:wrong, side()}
  def start_check(%__MODULE__{} = clock, to_move \\ :white) do
    cond do
      not present?(clock) -> nil
      first(clock) in [nil, to_move] -> :ok
      true -> {:wrong, first(clock)}
    end
  end

  @doc "`\"1:23:45\"` for a time in milliseconds."
  def format(nil), do: "-:--"

  def format(ms) do
    total = div(max(ms, 0), 1000)
    h = div(total, 3600)
    m = total |> rem(3600) |> div(60)
    s = rem(total, 60)
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(s)}", else: "#{m}:#{pad.(s)}"
  end
end
