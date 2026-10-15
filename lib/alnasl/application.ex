defmodule Alnasl.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The database lives in the data directory; make sure there is one.
    case Application.get_env(:alnasl, Alnasl.Repo)[:database] do
      path when is_binary(path) -> File.mkdir_p!(Path.dirname(path))
      _memory -> :ok
    end

    tidy_release_tmp()

    autostart? = Application.get_env(:alnasl, :autostart, true)

    # The launcher's Details panel: this start's secret (and its file, when
    # no launcher handed one over), the CPU sample, the slow queries. Before
    # the endpoint, which asks it.
    children =
      [
        AlnaslWeb.Telemetry,
        Alnasl.Repo,
        # Always: the box is an appliance, not a deployment with a migration step.
        {Ecto.Migrator,
         repos: Application.fetch_env!(:alnasl, :ecto_repos), skip: skip_migrations?()},
        {Phoenix.PubSub, name: Alnasl.PubSub},
        {Registry, keys: :unique, name: Alnasl.BoardRegistry},
        {Registry, keys: :unique, name: Alnasl.BusRegistry},
        {Task.Supervisor, name: Alnasl.TaskSupervisor},
        Alnasl.Recorder,
        {Alnasl.Updates.Checker, timer: Application.get_env(:alnasl, :updates_timer, true)},
        {DynamicSupervisor, name: Alnasl.BusSupervisor, strategy: :one_for_one},
        {DynamicSupervisor,
         name: Alnasl.BoardSupervisor, strategy: :one_for_one, max_restarts: 100, max_seconds: 60}
      ] ++
        [Alnasl.Finder] ++
        [Alnasl.LauncherDetails] ++
        if(autostart?,
          do:
            Alnasl.Destination.child_specs() ++
              [Alnasl.OpenPairings.Poller, {Task, &Alnasl.Boards.start_all/0}],
          else: []
        ) ++
        [AlnaslWeb.Endpoint]

    opts = [strategy: :one_for_one, name: Alnasl.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AlnaslWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # A release writes the configuration it starts with to a file in
  # RELEASE_TMP, a new one every start, and never takes one away. They hold
  # the cookie secret and they add up; the one this start is using stays.
  defp tidy_release_tmp do
    with tmp when is_binary(tmp) <- System.get_env("RELEASE_TMP"),
         mine when is_binary(mine) <- System.get_env("RELEASE_SYS_CONFIG") do
      for file <- Path.wildcard(Path.join(Path.expand(tmp), "alnasl-*.runtime.config")),
          Path.basename(file, ".config") != Path.basename(mine) do
        File.rm(file)
      end
    end

    :ok
  end

  # Tests migrate through the `mix test` alias, under the sandbox.
  defp skip_migrations?, do: Application.get_env(:alnasl, :skip_migrations, false)
end
