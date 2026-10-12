defmodule Alnasl.OpenPairings.Poller do
  @moduledoc """
  Asks the pairing programs, on time.

  Once a second this process looks which links are due - each at the pace
  its pairing program asked for (`poll_seconds`, five by default) - and
  asks them, one after the other, in a task: a request that hangs on a dead
  line does not keep this process from answering, and a link is never asked
  twice at once.

  A link that does not answer is asked again after a pause that doubles up
  to a minute, and at once when the arbiter says so. A link whose code was
  refused is not asked at all (`Alnasl.OpenPairings.polled?/1`): that is
  for the arbiter.

  When a link is new, and whenever the number of boards a tournament has
  been given changes, the pairing program is told about the box (`POST
  /box`), so its settings page can say which box is which.
  """

  use GenServer

  alias Alnasl.{OpenPairings, Tournaments}

  @tick 1_000
  @max_backoff 60_000

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Ask every link now, whatever its pace or pause."
  def poll_now do
    if pid = Process.whereis(__MODULE__), do: send(pid, :poll_now)
    :ok
  end

  @impl true
  def init(_arg) do
    # Stopped between two conversations, not in the middle of one (as
    # `Alnasl.Destination.Sender` is): see `terminate/2`.
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :tick, 200)
    # `due`: link id => monotonic ms; `backoff`: link id => ms; `told`: link
    # id => what the pairing program was last told about the box.
    {:ok, %{task: nil, due: %{}, backoff: %{}, told: %{}}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick)
    {:noreply, run(state)}
  end

  def handle_info(:poll_now, state), do: {:noreply, run(%{state | due: %{}, backoff: %{}})}

  def handle_info({ref, results}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    now = System.monotonic_time(:millisecond)

    state =
      Enum.reduce(results, %{state | task: nil}, fn {id, result, pace, told}, state ->
        case result do
          {:ok, _link} ->
            %{
              state
              | due: Map.put(state.due, id, now + pace),
                backoff: Map.delete(state.backoff, id),
                told: if(told, do: Map.put(state.told, id, told), else: state.told)
            }

          {:error, {:rate_limited, wait}} ->
            %{state | due: Map.put(state.due, id, now + wait)}

          {:error, _reason} ->
            wait = Map.get(state.backoff, id, pace)

            %{
              state
              | due: Map.put(state.due, id, now + wait),
                backoff: Map.put(state.backoff, id, min(wait * 2, @max_backoff))
            }
        end
      end)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: ref} = state),
    do: {:noreply, %{state | task: nil}}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{task: ref}) when is_reference(ref) do
    receive do
      {^ref, _results} -> :ok
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      4_000 -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  defp run(%{task: task} = state) when task != nil, do: state

  defp run(state) do
    now = System.monotonic_time(:millisecond)

    due =
      for link <- Tournaments.links(),
          OpenPairings.polled?(link),
          # A link nobody has asked yet is due now. (Not "at 0": the monotonic
          # clock is free to be negative, and on some machines it is.)
          Map.get(state.due, link.id, now) <= now,
          do: link

    case due do
      [] ->
        state

      links ->
        told = state.told

        task =
          Task.Supervisor.async_nolink(Alnasl.TaskSupervisor, fn ->
            Enum.map(links, &ask(&1, told[&1.id]))
          end)

        %{state | task: task.ref}
    end
  end

  # `{link id, result, pace in ms, what the pairing program was told | nil}`.
  defp ask(link, told) do
    result =
      try do
        OpenPairings.poll(link)
      rescue
        error -> {:error, {:crash, Exception.message(error)}}
      end

    counts = OpenPairings.board_counts(link)

    told =
      with {:ok, _link} <- result,
           true <- counts != told,
           :ok <- OpenPairings.tell(link) do
        counts
      else
        _no -> nil
      end

    pace =
      case result do
        {:ok, fresh} -> fresh.poll_seconds * 1000
        _error -> link.poll_seconds * 1000
      end

    {link.id, result, pace, told}
  end
end
