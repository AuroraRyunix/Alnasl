defmodule Alnasl.Clock do
  @moduledoc """
  What the chess clock on a board says: both times, which side runs, and how
  often it has been pressed.

  Pure, like the tracker. A reading is `%{white_ms, black_ms, running}` with
  `running` one of `:white | :black | :none`. A **press** is the running side
  changing from one player to the other; the count of presses is compared
  with the count of moves, because a press without a move is the earliest
  sign that the board missed one.

  A board without a clock never sends a reading; `read/2` is then `nil` and
  nothing about clocks is reported.
  """

  defstruct white_ms: nil, black_ms: nil, running: :none, at: nil, presses: 0

  @type t :: %__MODULE__{}
  @type reading :: %{white_ms: integer(), black_ms: integer(), running: atom()}

  def new, do: %__MODULE__{}

  @doc "Has a clock ever reported?"
  def present?(%__MODULE__{at: at}), do: at != nil

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
         at: t,
         presses: clock.presses + if(pressed?, do: 1, else: 0)
     }, pressed?}
  end

  @doc "The clock as it reads at `t`: the running side counted down since the last reading."
  @spec read(t(), integer()) :: reading() | nil
  def read(%__MODULE__{at: nil}, _t), do: nil

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
