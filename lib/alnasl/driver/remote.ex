defmodule Alnasl.Driver.Remote do
  @moduledoc """
  A board read by an Arkab bridge somewhere else: its events arrive over
  the bridge's link (`AlnaslWeb.BridgeSocket`) and leave here exactly as a
  local driver's would. The board's process cannot tell the difference,
  which is the point: the tracker, the capture, the outbox are the ones a
  board on the box's own serial port gets.

  The row's `port` names it: `"bridge-<bridge id>:<the bridge's name for
  the board>"`; the process is registered under that in
  `Alnasl.RemoteRegistry`, which is how the link finds it.

  ## Time

  A played board (a replay or a simulator on the bridge) brings its own
  time, `{:at, t, speed, next}`, and it is passed on unchanged: the game
  is the game it would have been here.

  A real board's events carry the bridge's clock when they happened. They
  go on as `{:at, t, 1.0, next, event}`, in the board process's own time:
  the first event this process sees is "now", and the rest keep their
  distances from it. A burst that arrives after the line was down is
  therefore played at the pace it was played, not all at once - and
  `next` is the event after it in the same burst, so the board's time does
  not run past something that has already happened and is merely late.
  After the last event of a burst, time runs on for `@hold_ms` and then
  waits for the bridge: a connected board says something every second
  (the bridge sends a poll a second), so a board that has been quiet for
  three is a link that is behind, and a tracker that kept counting would be
  counting a silence that was not there.

  The link going down is not the board going down: no `:disconnected` is
  invented here. The board's own come through when it sends them.
  """

  use GenServer

  @behaviour Alnasl.Driver

  @hold_ms 3_000

  @impl Alnasl.Driver
  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    GenServer.start_link(__MODULE__, opts, name: via(port))
  end

  def via(port), do: {:via, Registry, {Alnasl.RemoteRegistry, port}}

  def whereis(port) do
    case Registry.lookup(Alnasl.RemoteRegistry, port) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Hands a burst of events of this board to its process, oldest first:
  `[%{t, at, event}]` as `Arkab.Protocol.decode_event/1` gives them.
  Returns the board process the events went to, so the link can wait for
  them to be taken (`Alnasl.BoardServer.sync/1`).
  """
  def deliver(pid, events), do: GenServer.call(pid, {:deliver, events}, 15_000)

  @impl true
  def init(opts) do
    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       id: Keyword.fetch!(opts, :id),
       started: System.monotonic_time(:millisecond),
       base: nil
     }}
  end

  @impl true
  def handle_call({:deliver, events}, _from, state) do
    state = anchor(state, events)
    nexts = (events |> Enum.drop(1) |> Enum.map(& &1.t)) ++ [nil]

    for {event, next} <- Enum.zip(events, nexts) do
      send(state.owner, {:driver, state.id, timed(state, event, next)})
    end

    {:reply, state.owner, state}
  end

  # The first real-board event is now; a played one has its own time.
  defp anchor(%{base: nil} = state, [%{at: nil, t: t} | _]),
    do: %{state | base: t - (System.monotonic_time(:millisecond) - state.started)}

  defp anchor(state, _events), do: state

  defp timed(_state, %{at: {speed, next}, t: t, event: event}, _next_in_burst),
    do: {:at, t, speed, next, event}

  defp timed(%{base: base}, %{t: t, event: event}, next_in_burst) do
    next = if next_in_burst, do: next_in_burst - base, else: t - base + @hold_ms
    {:at, t - base, 1.0, next, event}
  end
end
