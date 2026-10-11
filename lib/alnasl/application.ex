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

    autostart? = Application.get_env(:alnasl, :autostart, true)

    children =
      [
        AlnaslWeb.Telemetry,
        Alnasl.Repo,
        # Always: the box is an appliance, not a deployment with a migration step.
        {Ecto.Migrator, repos: Application.fetch_env!(:alnasl, :ecto_repos), skip: skip_migrations?()},
        {Phoenix.PubSub, name: Alnasl.PubSub},
        {Registry, keys: :unique, name: Alnasl.BoardRegistry},
        {Registry, keys: :unique, name: Alnasl.BusRegistry},
        Alnasl.Recorder,
        {DynamicSupervisor, name: Alnasl.BusSupervisor, strategy: :one_for_one},
        {DynamicSupervisor, name: Alnasl.BoardSupervisor, strategy: :one_for_one, max_restarts: 100, max_seconds: 60}
      ] ++
        if(autostart?, do: [Alnasl.Outbox, {Task, &Alnasl.Boards.start_all/0}], else: []) ++
        [AlnaslWeb.Endpoint]

    opts = [strategy: :one_for_one, name: Alnasl.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AlnaslWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Tests migrate through the `mix test` alias, under the sandbox.
  defp skip_migrations?, do: Application.get_env(:alnasl, :skip_migrations, false)
end
