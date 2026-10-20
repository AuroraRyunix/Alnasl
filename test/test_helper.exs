# Tests that need a real Stockfish 19 (`mix test --only stockfish`, with
# ALNASL_STOCKFISH_ARCHIVE naming the official archive) are not run by default.
ExUnit.start(exclude: [:stockfish])
Ecto.Adapters.SQL.Sandbox.mode(Alnasl.Repo, :manual)
