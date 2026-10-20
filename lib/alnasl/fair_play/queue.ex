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

  ## Two lanes

  What the owner asks for in bulk - a round analysed on demand
  (`{:game, id}`, `Alnasl.FairPlay.analyse_round/3`) and the games of an
  uploaded PGN (`{:upload_game, id}`, `Alnasl.FairPlay.Uploads`) - waits
  in a lane of its own (`:bulk_max`, 5,000 by default) and only gets an
  engine when no live game is waiting. A round of a hundred games or an
  upload of a thousand never keeps the live games of this round from
  their analysis. A board game is the same game in either lane: one
  queued live while it waits in bulk is not queued twice, and never runs
  twice at once.

  The job can be replaced with `:job` (a `fn item -> any end`, the item
  being a live game's id or one of the tuples above), which is how the
  tests watch the queue without an engine.
  """

  use GenServer

  require Logger

  alias Alnasl.FairPlay.{Analysis, Pool, Setting, Uploads}
  alias Alnasl.{Games.Game, Halls, Repo, Tournaments}

  @max 500
  @bulk_max 5_000

  # --- API ---------------------------------------------------------------------

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Queues a live game (its id), or bulk work: `{:game, id}` (a board game,
  on demand) or `{:upload_game, id}`. Never waits, never fails.
  """
  @spec enqueue(integer() | {:game | :upload_game, integer()}, GenServer.server()) :: :ok
  def enqueue(item, server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.cast(server, {:item, item})
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
       bulk_max: Keyword.get(opts, :bulk_max, @bulk_max),
       slots: Keyword.get(opts, :slots, Alnasl.FairPlay.engine_count()),
       job: Keyword.get(opts, :job, &__MODULE__.job/1),
       line: :queue.new(),
       bulk: :queue.new(),
       bulk_waiting: 0,
       waiting: MapSet.new(),
       running: %{},
       again: MapSet.new(),
       dropped: 0,
       drainers: []
     }}
  end

  @impl true
  def handle_cast({:item, item}, state) do
    id = identity(item)
    lane = lane(item)

    state =
      cond do
        MapSet.member?(state.waiting, id) ->
          state

        id in Enum.map(Map.values(state.running), &identity/1) ->
          %{state | again: MapSet.put(state.again, id)}

        lane == :live and MapSet.size(state.waiting) - state.bulk_waiting >= state.max ->
          Logger.warning(
            "fair play: the queue is full, game #{inspect(item)} dropped until it changes again"
          )

          %{state | dropped: state.dropped + 1}

        lane == :bulk and state.bulk_waiting >= state.bulk_max ->
          Logger.warning("fair play: the bulk queue is full, #{inspect(item)} dropped")
          %{state | dropped: state.dropped + 1}

        lane == :live ->
          %{state | line: :queue.in(item, state.line), waiting: MapSet.put(state.waiting, id)}

        true ->
          %{
            state
            | bulk: :queue.in(item, state.bulk),
              bulk_waiting: state.bulk_waiting + 1,
              waiting: MapSet.put(state.waiting, id)
          }
      end

    {:noreply, state |> dispatch() |> reply_drainers()}
  end

  # The same board game is the same work in either lane.
  defp identity({:game, id}), do: {:game, id}
  defp identity({:upload_game, id}), do: {:upload_game, id}
  defp identity(id) when is_integer(id), do: {:game, id}

  defp lane(id) when is_integer(id), do: :live
  defp lane(_bulk), do: :bulk

  @impl true
  def handle_call(:info, _from, state) do
    {:reply,
     %{
       waiting: MapSet.size(state.waiting),
       bulk: state.bulk_waiting,
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
    {running_item, running} = Map.pop(state.running, ref)
    id = running_item && identity(running_item)

    if id != nil and MapSet.member?(state.again, id) do
      %{
        state
        | running: running,
          again: MapSet.delete(state.again, id),
          line: :queue.in(running_item, state.line),
          waiting: MapSet.put(state.waiting, id)
      }
    else
      %{state | running: running}
    end
  end

  # Live games first; bulk work only when none waits.
  defp dispatch(state) do
    if map_size(state.running) < state.slots do
      case next(state) do
        {item, state} ->
          task =
            Task.Supervisor.async_nolink(Alnasl.FairPlay.TaskSupervisor, fn ->
              state.job.(item)
            end)

          dispatch(%{
            state
            | waiting: MapSet.delete(state.waiting, identity(item)),
              running: Map.put(state.running, task.ref, item)
          })

        nil ->
          state
      end
    else
      state
    end
  end

  defp next(state) do
    case :queue.out(state.line) do
      {{:value, item}, line} ->
        {item, %{state | line: line}}

      {:empty, _line} ->
        case :queue.out(state.bulk) do
          {{:value, item}, bulk} ->
            {item, %{state | bulk: bulk, bulk_waiting: state.bulk_waiting - 1}}

          {:empty, _bulk} ->
            nil
        end
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
  # What a job does: for a board game, live or on demand, find the game's
  # hall, and unless fair play is off or has no engine there, bring the
  # stored analysis up to date; an uploaded game is `Uploads.job/1`'s.
  def job({:upload_game, id}), do: Uploads.job(id)
  def job({:game, id}), do: job(id)

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
