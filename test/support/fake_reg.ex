defmodule Alnasl.FakeReg do
  @moduledoc """
  `reg.exe` for `Alnasl.AutostartTest`: remembers what it was asked and
  whether the one value is there. `Alnasl.NoReg` is the one every other test
  gets, which remembers nothing.
  """

  use Agent

  def start_link(_opts),
    do: Agent.start_link(fn -> %{calls: [], value: nil} end, name: __MODULE__)

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  def value, do: Agent.get(__MODULE__, & &1.value)

  def cmd("reg", args, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = %{state | calls: [args | state.calls]}

      case args do
        ["query" | _] -> {{"", if(state.value, do: 0, else: 1)}, state}
        ["add" | rest] -> {{"", 0}, %{state | value: Enum.at(rest, 6)}}
        ["delete" | _] -> {{"", 0}, %{state | value: nil}}
      end
    end)
  end
end
