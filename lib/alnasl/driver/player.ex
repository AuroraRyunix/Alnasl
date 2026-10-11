defmodule Alnasl.Driver.Player do
  @moduledoc """
  Plays a list of timed driver events to an owner, in real time or faster.
  The simulator and the replay driver are both this, with different lists.

  `speed` scales time: at 20, an event due after 10 s is sent after half a
  second. The clock readings are passed on as they are - a game played at
  speed 20 shows clocks that jump, which is right: they are the clocks of the
  game, not of the demonstration.

  Every event goes out as `{:at, t, speed, next_t, event}`: the time it has
  in the list, how fast that time runs, and the time of the event after it
  (`nil` after the last). The receiver may let time run on between events
  at `speed`, but never past `next_t`: a timer that fires a millisecond late
  at speed 600 would otherwise put the tracker more than half a simulated
  second ahead of the board it is watching. The board's process keeps the tracker's
  clock by it, so a tracker fed by a player at speed 20 waits 400 simulated
  milliseconds for a move to settle, not 400 real ones - and makes of a game
  exactly what it would have made of it at speed 1.

  `pause/1`, `resume/1` and `progress/1` are for the site: a simulated board
  can be stopped mid-game to see what the tracker does.
  """

  use GenServer

  alias Alnasl.Driver

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def pause(pid), do: GenServer.call(pid, :pause)
  def resume(pid), do: GenServer.call(pid, :resume)

  @doc "`%{done, total, paused?, finished?}`."
  def progress(pid) do
    GenServer.call(pid, :progress)
  catch
    :exit, _reason -> nil
  end

  @impl true
  def init(opts) do
    events = Keyword.fetch!(opts, :events)

    state = %{
      owner: Keyword.fetch!(opts, :owner),
      id: Keyword.fetch!(opts, :id),
      left: events,
      total: length(events),
      done: 0,
      speed: max(Keyword.get(opts, :speed, 1.0) * 1.0, 0.01),
      at: 0,
      paused?: false,
      timer: nil
    }

    if Keyword.get(opts, :connected, true), do: emit(state, 0, :connected, next_time(events))
    {:ok, schedule(state, Keyword.get(opts, :start_delay_ms, 0))}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:reply, :ok, %{state | paused?: true, timer: nil}}
  end

  def handle_call(:resume, _from, %{paused?: true} = state),
    do: {:reply, :ok, schedule(%{state | paused?: false}, 0)}

  def handle_call(:resume, _from, state), do: {:reply, :ok, state}

  def handle_call(:progress, _from, state) do
    {:reply, %{done: state.done, total: state.total, paused?: state.paused?, finished?: state.left == []}, state}
  end

  @impl true
  def handle_info(:next, %{paused?: true} = state), do: {:noreply, state}
  def handle_info(:next, %{left: []} = state), do: {:noreply, %{state | timer: nil}}

  def handle_info(:next, %{left: [{t, event} | rest]} = state) do
    emit(state, t, event, next_time(rest))
    {:noreply, schedule(%{state | left: rest, done: state.done + 1, at: t}, 0)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp emit(state, t, event, next),
    do: Driver.emit(state.owner, state.id, {:at, t, state.speed, next, event})

  defp next_time([{t, _event} | _]), do: t
  defp next_time([]), do: nil

  # Events due within a millisecond of each other go out together.
  defp schedule(%{left: []} = state, _extra), do: %{state | timer: nil}

  defp schedule(%{left: [{t, _event} | _]} = state, extra) do
    wait = round(max(t - state.at, 0) / state.speed) + extra
    %{state | timer: Process.send_after(self(), :next, wait)}
  end
end
