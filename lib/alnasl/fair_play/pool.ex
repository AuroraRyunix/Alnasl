defmodule Alnasl.FairPlay.Pool do
  @moduledoc """
  The engines of the live queue: up to `Alnasl.FairPlay.engine_count/0` UCI
  processes (`Alnasl.FairPlay.Uci`) per installed binary, handed out one
  job at a time and taken back afterwards.

  An engine is started when a job first needs one, at the lowest operating
  system priority the platform offers (the tracker and the pages matter
  more than a screening). One that dies is forgotten; the next job starts a
  fresh one. Reinstalling the engine (`stop_all/0`) stops them all, so no
  job runs the old binary after the new one is in place.

  How a binary is launched is `Application.get_env(:alnasl,
  :fair_play_launch)`, a `fn path -> {cmd, args} end`; unset, the path is
  the command. Tests use it to run a fake engine through `escript`.
  """

  use GenServer

  alias Alnasl.FairPlay.Uci

  require Logger

  # --- API ---------------------------------------------------------------------

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  An engine for the binary at `path`: `{:ok, pid}`, or `{:error, reason}`
  when none could be started. The caller must `checkin/2` it (or let it
  die; the pool notices).
  """
  def checkout(path, server \\ __MODULE__), do: GenServer.call(server, {:checkout, path}, 90_000)

  @doc "Gives an engine back."
  def checkin(pid, server \\ __MODULE__), do: GenServer.cast(server, {:checkin, pid})

  @doc "Stops every engine; the next job starts new ones."
  def stop_all(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.call(server, :stop_all), else: :ok
  end

  @doc "How many engines exist: `%{started: n, idle: n}`."
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  # --- server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, %{limit: Keyword.get(opts, :limit, Alnasl.FairPlay.engine_count()), engines: %{}}}
  end

  @impl true
  def handle_call({:checkout, path}, _from, state) do
    entry = Map.get(state.engines, path, %{idle: [], all: []})

    case entry.idle do
      [pid | rest] ->
        {:reply, {:ok, pid}, put_entry(state, path, %{entry | idle: rest})}

      [] when length(entry.all) < state.limit ->
        case start_engine(path) do
          {:ok, pid} ->
            Process.monitor(pid)
            {:reply, {:ok, pid}, put_entry(state, path, %{entry | all: [pid | entry.all]})}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      [] ->
        {:reply, {:error, :busy}, state}
    end
  end

  def handle_call(:stop_all, _from, state) do
    for {_path, %{all: all}} <- state.engines, pid <- all, do: stop(pid)
    {:reply, :ok, %{state | engines: %{}}}
  end

  def handle_call(:info, _from, state) do
    all = state.engines |> Map.values() |> Enum.flat_map(& &1.all)
    idle = state.engines |> Map.values() |> Enum.flat_map(& &1.idle)
    {:reply, %{started: length(all), idle: length(idle)}, state}
  end

  @impl true
  def handle_cast({:checkin, pid}, state) do
    engines =
      Map.new(state.engines, fn {path, entry} ->
        if pid in entry.all and pid not in entry.idle,
          do: {path, %{entry | idle: [pid | entry.idle]}},
          else: {path, entry}
      end)

    {:noreply, %{state | engines: engines}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    engines =
      Map.new(state.engines, fn {path, entry} ->
        {path, %{all: List.delete(entry.all, pid), idle: List.delete(entry.idle, pid)}}
      end)

    {:noreply, %{state | engines: engines}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {_path, %{all: all}} <- state.engines, pid <- all, do: stop(pid)
    :ok
  end

  defp put_entry(state, path, entry), do: %{state | engines: Map.put(state.engines, path, entry)}

  defp start_engine(path) do
    {cmd, args} =
      case Application.get_env(:alnasl, :fair_play_launch) do
        fun when is_function(fun, 1) -> fun.(path)
        _none -> {path, []}
      end

    case Uci.start(cmd: cmd, args: args, low_priority: true) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("fair play: the engine would not start: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp stop(pid) do
    Uci.stop(pid)
  catch
    :exit, _gone -> :ok
  end
end
