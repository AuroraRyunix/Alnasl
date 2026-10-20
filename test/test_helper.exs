# Tests that need a real Stockfish 19 (`mix test --only stockfish`, with
# ALNASL_STOCKFISH_ARCHIVE naming the official archive) are not run by default.
ExUnit.start(exclude: [:stockfish])
Ecto.Adapters.SQL.Sandbox.mode(Alnasl.Repo, :manual)

# This run's database and data directory (config/test.exs) go with it.
# Best effort: Windows keeps a file the pool still has open.
run_dir = Path.dirname(Application.fetch_env!(:alnasl, :data_dir))
System.at_exit(fn _ -> File.rm_rf(run_dir) end)
