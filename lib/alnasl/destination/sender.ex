defmodule Alnasl.Destination.Sender do
  @moduledoc """
  The process that sends for one destination (`Alnasl.Destination`).

  It owns nothing that matters: what is waiting is in the database, and the
  destination's `deliver/0` works from there. What this process adds is
  patience - the pause after a failure that doubles up to a minute, the
  thirty seconds between tries when a credential is refused, the short wait
  that lets a burst of moves go out as one - and an honest account of how
  things stand: connected or not, the last success, the last error.

  Each delivery runs in a task, so the process can always answer how things
  stand, also while a request hangs on a dead line. One task at a time: a
  destination is never sent to twice at once, which is what keeps a game's
  messages in order.
  """

  use GenServer

  alias Alnasl.{Destination, Log, Settings}

  @topic "outbox"
  @max_backoff 60_000
  @blocked_retry 30_000

  def start_link(opts) do
    destination = Keyword.fetch!(opts, :destination)
    name = Keyword.get(opts, :name) || Destination.sender(destination)
    GenServer.start_link(__MODULE__, destination, name: name)
  end

  @doc "`%{state, last_ok, last_error, next_try_at}` of the sender registered as `name`."
  def status(name) do
    case Process.whereis(name) do
      nil -> idle()
      pid -> GenServer.call(pid, :status)
    end
  catch
    # The sender did not answer. That is not a reason to say nothing.
    :exit, _reason -> idle()
  end

  defp idle, do: %{state: :idle, last_ok: nil, last_error: nil, next_try_at: nil}

  # --- the process -------------------------------------------------------------

  @impl true
  def init(destination) do
    Settings.subscribe()
    send(self(), :send_now)

    {:ok,
     %{
       destination: destination,
       keys: [Destination.enabled_key(destination) | destination.setting_keys()],
       state: :idle,
       last_ok: nil,
       last_error: nil,
       backoff: 1_000,
       timer: nil,
       next_try_at: nil,
       task: nil,
       again?: false
     }}
  end

  @impl true
  def handle_call(:status, _from, s) do
    {:reply, Map.take(s, [:state, :last_ok, :last_error, :next_try_at]), s}
  end

  @impl true
  # "Send now", and a change of the settings: no pause, no gathering.
  def handle_info(:send_now, s) do
    s = cancel(s)
    {:noreply, if(s.task == nil, do: start_batch(s), else: %{s | again?: true})}
  end

  def handle_info({:setting, key}, s) do
    if key in s.keys, do: handle_info(:send_now, s), else: {:noreply, s}
  end

  # A wake-up while a retry is scheduled changes nothing: the pause stands.
  def handle_info(:deliver, %{timer: timer} = s) when timer != nil, do: {:noreply, s}

  # A wake-up while a batch is out: look again when it is back.
  def handle_info(:deliver, %{task: task} = s) when task != nil,
    do: {:noreply, %{s | again?: true}}

  def handle_info(:deliver, s) do
    case s.destination.coalesce_ms() do
      0 -> {:noreply, start_batch(s)}
      # Gather: whatever else changes before the timer fires goes with it.
      wait -> {:noreply, %{s | timer: Process.send_after(self(), :retry, wait)}}
    end
  end

  def handle_info(:retry, %{task: nil} = s),
    do: {:noreply, start_batch(%{s | timer: nil, next_try_at: nil})}

  def handle_info(:retry, s), do: {:noreply, %{s | timer: nil, next_try_at: nil, again?: true}}

  def handle_info({ref, {result, sent}}, %{task: ref} = s) do
    Process.demonitor(ref, [:flush])
    s = finish(%{s | task: nil}, result, sent)
    if s.again? and s.timer == nil, do: send(self(), :deliver)
    {:noreply, %{s | again?: false}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: ref} = s) do
    {:noreply, finish(%{s | task: nil}, {:retry, {:crash, inspect(reason)}, nil}, 0)}
  end

  def handle_info(_other, s), do: {:noreply, s}

  defp cancel(%{timer: nil} = s), do: s

  defp cancel(%{timer: timer} = s) do
    Process.cancel_timer(timer)
    %{s | timer: nil, next_try_at: nil}
  end

  defp start_batch(%{destination: destination} = s) do
    if Destination.enabled?(destination) do
      task =
        Task.Supervisor.async_nolink(Alnasl.TaskSupervisor, fn ->
          try do
            destination.deliver()
          rescue
            error -> {{:retry, {:crash, Exception.message(error)}, nil}, 0}
          end
        end)

      %{s | task: task.ref}
    else
      # Switched off: quiet, and no stale error left standing.
      if s.state == :idle and s.last_error == nil,
        do: s,
        else: broadcast(%{s | state: :idle, last_error: nil, backoff: 1_000})
    end
  end

  defp finish(s, result, sent) do
    s = if sent > 0, do: online(%{s | last_ok: DateTime.utc_now(:second)}), else: s

    case result do
      :empty ->
        s

      :unconfigured ->
        change(s, :idle, nil)

      {:retry, reason, wait} ->
        wait = wait || s.backoff
        s = change(s, :offline, reason)
        schedule(%{s | backoff: min(s.backoff * 2, @max_backoff)}, wait)

      {:blocked, reason} ->
        s |> change(:blocked, reason) |> schedule(@blocked_retry)

      _more ->
        # The batch limit was reached mid-queue: go on after a breath.
        send(self(), :deliver)
        s
    end
  end

  defp online(s) do
    s = %{s | backoff: 1_000}

    if s.state == :connected do
      s
    else
      if s.state in [:offline, :blocked], do: log(s, :info, "online", %{})
      broadcast(%{s | state: :connected, last_error: nil})
    end
  end

  defp change(s, state, reason) do
    if s.state != state do
      case state do
        :offline -> log(s, :warn, "offline", %{reason: inspect(reason)})
        :blocked -> log(s, :error, "blocked", %{reason: inspect(reason)})
        _other -> :ok
      end
    end

    broadcast(%{s | state: state, last_error: reason})
  end

  # The results server keeps the log lines it always had; the others say
  # which destination they are about.
  defp log(%{destination: Alnasl.Destination.OpenResults}, level, what, data),
    do: Log.add(level, "outbox." <> what, data)

  defp log(%{destination: destination}, level, what, data),
    do: Log.add(level, "destination." <> what, Map.put(data, :destination, destination.id()))

  defp schedule(s, wait) do
    timer = Process.send_after(self(), :retry, wait)

    broadcast(%{
      s
      | timer: timer,
        next_try_at: DateTime.add(DateTime.utc_now(), wait, :millisecond)
    })
  end

  defp broadcast(s) do
    Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, :outbox_changed)
    s
  end
end
