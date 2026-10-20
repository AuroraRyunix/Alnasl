defmodule Alnasl.FairPlay.Queue do
  @moduledoc """
  The live analysis queue: the tracker says a game changed
  (`Alnasl.FairPlay.game_changed/1`), the queue sees that the game gets
  brought up to date (`Alnasl.FairPlay.Analysis`), by at most
  `Alnasl.FairPlay.engine_count/0` jobs at once.

  Nothing here may slow the tracker or the boards down:

    * `enqueue/1` is a `cast`; when the queue is not running it returns at
      once without doing anything;
    * the work runs in tasks under `Alnasl.FairPlay.TaskSupervisor`, at
      the lowest priority the platform offers for the engines, never in the
      queue's own process;
    * the queue is bounded (`:max`, 500 games by default). A game already
      waiting is not queued twice; when the line is full a game is
      **dropped and logged**. It is not lost for good: the next change of
      that game (every further move is one) queues it again, and a job
      analyses the whole game as it stands, not only the move it was
      called for;
    * a game being worked on that changes again is marked and queued once
      more when its job ends, so no job ever races another on one game.

  Whether the game's hall has fair play on, and an engine, is decided by
  the job when it starts, not when the game is queued: a switch turned
  on or off takes effect from the next job.

  The job can be replaced with `:job` (a `fn game_id -> any end`), which is
  how the tests watch the queue without an engine.
  """

  use GenServer

  require Logger

  alias Alnasl.FairPlay.{Analysis, Pool, Setting}
  alias Alnasl.{Games.Game, Halls, Repo, Tournaments}

  @max 500

  # --- API ---------------------------------------------------------------------

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Queues a game. Never waits, never fails."
  @spec enqueue(integer(), GenServer.server()) :: :ok
  def enqueue(game_id, server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.cast(server, {:game, game_id})
    :ok
  end

  @doc "`%{waiting: n, running: n, dropped: n}`."
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @doc "Blocks until nothing waits or runs (tests)."
  def drain(server \\ __MODULE__, timeout \\ 10_000), do: GenServer.call(server, :drain, timeout)

  # --- server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       max: Keyword.get(opts, :max, @max),
       slots: Keyword.get(opts, :slots, Alnasl.FairPlay.engine_count()),
       job: Keyword.get(opts, :job, &__MODULE__.job/1),
       line: :queue.new(),
       waiting: MapSet.new(),
       running: %{},
       again: MapSet.new(),
       dropped: 0,
       drainers: []
     }}
  end

  @impl true
  def handle_cast({:game, id}, state) do
    state =
      cond do
        MapSet.member?(state.waiting, id) ->
          state

        id in Map.values(state.running) ->
          %{state | again: MapSet.put(state.again, id)}

        MapSet.size(state.waiting) >= state.max ->
          Logger.warning(
            "fair play: the queue is full, game #{id} dropped until it changes again"
          )

          %{state | dropped: state.dropped + 1}

        true ->
          %{state | line: :queue.in(id, state.line), waiting: MapSet.put(state.waiting, id)}
      end

    {:noreply, state |> dispatch() |> reply_drainers()}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply,
     %{
       waiting: MapSet.size(state.waiting),
       running: map_size(state.running),
       dropped: state.dropped
     }, state}
  end

  def handle_call(:drain, from, state) do
    if idle?(state),
      do: {:reply, :ok, state},
      else: {:noreply, %{state | drainers: [from | state.drainers]}}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finished(ref) |> dispatch() |> reply_drainers()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    Logger.warning("fair play: a job ended badly: #{inspect(reason)}")
    {:noreply, state |> finished(ref) |> dispatch() |> reply_drainers()}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp finished(state, ref) do
    {id, running} = Map.pop(state.running, ref)

    if id != nil and MapSet.member?(state.again, id) do
      %{
        state
        | running: running,
          again: MapSet.delete(state.again, id),
          line: :queue.in(id, state.line),
          waiting: MapSet.put(state.waiting, id)
      }
    else
      %{state | running: running}
    end
  end

  defp dispatch(state) do
    if map_size(state.running) < state.slots do
      case :queue.out(state.line) do
        {{:value, id}, line} ->
          task =
            Task.Supervisor.async_nolink(Alnasl.FairPlay.TaskSupervisor, fn -> state.job.(id) end)

          dispatch(%{
            state
            | line: line,
              waiting: MapSet.delete(state.waiting, id),
              running: Map.put(state.running, task.ref, id)
          })

        {:empty, _line} ->
          state
      end
    else
      state
    end
  end

  defp idle?(state), do: map_size(state.running) == 0 and MapSet.size(state.waiting) == 0

  defp reply_drainers(state) do
    if idle?(state) and state.drainers != [] do
      for from <- state.drainers, do: GenServer.reply(from, :ok)
      %{state | drainers: []}
    else
      state
    end
  end

  # --- the job -----------------------------------------------------------------

  @doc false
  # What a job does: find the game's hall, and unless fair play is off or has
  # no engine there, bring the stored analysis up to date.
  def job(game_id) do
    with %Game{} = game <- Repo.get(Game, game_id),
         %{} = tournament <- Tournaments.get(game.tournament_id),
         %Setting{} = setting <- Alnasl.FairPlay.settings(Halls.of(tournament)),
         true <- Alnasl.FairPlay.working?(setting),
         {:ok, engine} <- Pool.checkout(setting.engine_path) do
      try do
        Analysis.run(game_id, Alnasl.FairPlay.Uci.engine_fun(engine, setting.nodes), setting)
      after
        Pool.checkin(engine)
      end
    else
      _off ->
        :ok
    end
  end
end
