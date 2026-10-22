# Tests that need a real Stockfish 19 (`mix test --only stockfish`, with
# ALNASL_STOCKFISH_ARCHIVE naming the official archive) are not run by default.
# `:e2e` drives a real browser against a real listener: `mix test.e2e` only.
ExUnit.start(exclude: [:stockfish, :e2e])

# The browser tests (test/e2e, docs/e2e.md). `mix test.e2e` sets E2E=1; an
# ordinary run leaves the endpoint without a listener and Playwright unstarted,
# so it neither needs Node nor claims a port.
if System.get_env("E2E") in ~w(1 true) do
  endpoint = AlnaslWeb.Endpoint
  port = String.to_integer(System.get_env("E2E_PORT", "4013"))
  config = Application.get_env(:alnasl, endpoint, [])

  Application.put_env(
    :alnasl,
    endpoint,
    config
    |> Keyword.put(:server, true)
    |> Keyword.update(:http, [port: port], &Keyword.put(&1, :port, port))
    |> Keyword.update(:url, [host: "localhost", port: port], &Keyword.put(&1, :port, port))
  )

  # one_for_one, so this restarts the endpoint alone, now reading the config above.
  :ok = Supervisor.terminate_child(Alnasl.Supervisor, endpoint)
  {:ok, _} = Supervisor.restart_child(Alnasl.Supervisor, endpoint)

  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
  Application.put_env(:phoenix_test, :base_url, endpoint.url())
end

Ecto.Adapters.SQL.Sandbox.mode(Alnasl.Repo, :manual)

# This run's database and data directory (config/test.exs) go with it.
# Best effort: Windows keeps a file the pool still has open.
run_dir = Path.dirname(Application.fetch_env!(:alnasl, :data_dir))
System.at_exit(fn _ -> File.rm_rf(run_dir) end)
