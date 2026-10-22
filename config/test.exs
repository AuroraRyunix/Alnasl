import Config

# Every `mix test` gets a directory of its own. SQLite has one writer per
# file and the sandbox holds its write lock until the test is over, so two
# runs on one checkout (a second terminal, an agent, a watcher) used to
# queue up behind each other's tests until `Database busy`, and wiped each
# other's capture files besides. The run's pid names it; leftovers of runs
# that did not clean up are removed after a day.
tmp_test = Path.expand("../tmp/test", __DIR__)
run_dir = Path.join(tmp_test, "run-#{System.pid()}")

day_ago = :os.system_time(:second) - 86_400

for stale <- Path.wildcard(Path.join(tmp_test, "run-*")),
    stale != run_dir,
    {:ok, %{mtime: mtime}} <- [File.stat(stale, time: :posix)],
    mtime < day_ago do
  File.rm_rf(stale)
end

File.mkdir_p!(Path.join(run_dir, "data"))

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :alnasl, Alnasl.Repo,
  database: Path.join(run_dir, "alnasl_test.db"),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :alnasl, AlnaslWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "1NLPkCqR2JVIlAbiRxpURgIKgC7PdnqGgKV+N1MMpyMBjamgOqyTO2BkQB7p5h8G",
  server: false

# Print only warnings and errors during test
config :alnasl,
  data_dir: Path.join(run_dir, "data"),
  # No bundled packs unless a test asks for them: the ordinary theme-pack
  # tests count the packs they installed, and the shipped Toon is not one.
  bundled_themes_dir: Path.join(run_dir, "no_bundled_themes"),
  autostart: false,
  # The fair-play queue, pool and retention job: tests that need them
  # start their own, with the database allowed to them.
  fair_play_live: false,
  # No launcher secret, no token file, no telemetry handler; the tests that
  # need them start their own `Alnasl.LauncherDetails`.
  launcher_details: false,
  updates_timer: false,
  install_kind: :manual,
  autostart_cmd: &Alnasl.NoReg.cmd/3,
  skip_migrations: true

config :logger, level: :warning

# Password hashes that take a millisecond, not a third of a second, and
# Keycloak's answers from a stub, never from auth.zerotwo.cloud.
config :alnasl, pbkdf2_iterations: 1_000, keycloak_req_plug: Alnasl.KeycloakStub

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# A real loop is listened to for a second after a ping to everybody, asked
# again a millisecond after each answer and looked over for new boards every
# ten seconds. The emulated ones answer at once. (The loop is Arkab's.)
config :arkab,
  loop_ping_window_ms: 30,
  loop_reply_ms: 80,
  loop_gap_ms: 5,
  loop_discover_ms: 400

# The vendored contracts' schemas refer to each other by their GitHub URLs;
# the tests answer those from priv/contracts/vendor and never from GitHub
# (Alnasl.Contract).
config :ex_json_schema, :remote_schema_resolver, {Alnasl.Contract, :resolve}
