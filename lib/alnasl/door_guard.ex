defmodule Alnasl.DoorGuard do
  @moduledoc """
  Keeps the PIN from being guessed. On a box without accounts the PIN is the
  only thing between the hall's Wi-Fi and everything Alnasl does, and a
  hash is cheap: without a limit, four digits fall in minutes.

  Failures are counted per address and for the box as a whole. An address
  gets five free tries; from the fifth failure on it waits 5 seconds, then
  10, 20 and so on, up to a quarter of an hour, and a correct PIN does not
  get it in while it waits. Across all addresses the box takes at most
  40 failures a minute; a person with the right PIN is turned away for the
  rest of that minute, which is the price of not letting a crowd of
  addresses take turns. A correct PIN clears the address's count.

  The counts live in memory: a restart forgives everybody, which is no worse
  than the attacker waiting.
  """

  use Agent

  @free 5
  @base 5
  @cap 900
  @global_limit 40
  @window 60
  # An address that has been quiet this long starts again from nothing.
  @forget 3_600

  def start_link(_opts) do
    Agent.start_link(fn -> %{ips: %{}, global: []} end, name: __MODULE__)
  end

  @doc "`:ok`, or `{:wait, seconds}`: this address may not try yet."
  def check(ip, now \\ now()) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = prune(state, now)

      wait =
        [global_wait(state, now), ip_wait(state, ip, now)]
        |> Enum.max()

      {if(wait > 0, do: {:wait, wait}, else: :ok), state}
    end)
  end

  @doc "A wrong PIN from `ip`."
  def failed(ip, now \\ now()) do
    Agent.update(__MODULE__, fn state ->
      state = prune(state, now)
      fails = (state.ips[ip] || %{fails: 0}).fails + 1

      until =
        if fails >= @free, do: now + min(@base * Integer.pow(2, fails - @free), @cap)

      %{
        state
        | ips: Map.put(state.ips, ip, %{fails: fails, last: now, until: until}),
          global: [now | state.global]
      }
    end)
  end

  @doc "The right PIN from `ip`: its count starts again."
  def succeeded(ip) do
    Agent.update(__MODULE__, fn state -> %{state | ips: Map.delete(state.ips, ip)} end)
  end

  @doc "Forgets everything (for tests)."
  def reset, do: Agent.update(__MODULE__, fn _state -> %{ips: %{}, global: []} end)

  @doc "The shortest PIN a new one may be. Older, shorter PINs keep working."
  def min_length, do: 6

  defp now, do: System.monotonic_time(:second)

  defp ip_wait(state, ip, now) do
    case state.ips[ip] do
      %{until: until} when is_integer(until) -> max(until - now, 0)
      _none -> 0
    end
  end

  defp global_wait(%{global: times}, now) do
    if length(times) >= @global_limit do
      oldest = Enum.min(times)
      max(oldest + @window - now, 0)
    else
      0
    end
  end

  defp prune(state, now) do
    ips =
      state.ips
      |> Enum.reject(fn {_ip, %{last: last, until: until}} ->
        now - last > @forget and (until || now) <= now
      end)
      |> Map.new()

    %{state | ips: ips, global: Enum.filter(state.global, &(&1 > now - @window))}
  end
end
