defmodule Alnasl.FairPlay.Live do
  @moduledoc """
  What fair play keeps running, as one supervised unit: the task
  supervisor the jobs run under, the pool of engines, the queue that feeds
  them, a one-off task that queues the uploaded games a restart left
  waiting, and the daily retention job.

  Started with the application unless `config :alnasl, fair_play_live:
  false` (the tests start their own). Nothing in it starts an engine until
  a hall with fair play on and an engine installed has a game that changes.
  """

  use Supervisor

  def start_link(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Should the application start it?"
  def enabled?, do: Application.get_env(:alnasl, :fair_play_live, true)

  @impl true
  def init(opts) do
    children = [
      {Task.Supervisor, name: Alnasl.FairPlay.TaskSupervisor},
      {Alnasl.FairPlay.Pool, Keyword.take(opts, [:limit])},
      {Alnasl.FairPlay.Queue, Keyword.take(opts, [:slots, :max, :bulk_max, :job])},
      # Uploaded games a restart left waiting go back in the queue, once.
      Supervisor.child_spec({Task, &Alnasl.FairPlay.Uploads.resume/0}, restart: :temporary),
      {Alnasl.FairPlay.Retention, Keyword.take(opts, [:timer])}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
