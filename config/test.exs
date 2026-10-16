import Config

File.mkdir_p!(Path.expand("../tmp/test/data", __DIR__))

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :alnasl, Alnasl.Repo,
  database: Path.expand("../tmp/test/alnasl_test.db", __DIR__),
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
  data_dir: Path.expand("../tmp/test/data", __DIR__),
  # No bundled packs unless a test asks for them: the ordinary theme-pack
  # tests count the packs they installed, and the shipped Toon is not one.
  bundled_themes_dir: Path.expand("../tmp/test/no_bundled_themes", __DIR__),
  autostart: false,
  # No launcher secret, no token file, no telemetry handler; the tests that
  # need them start their own `Alnasl.LauncherDetails`.
  launcher_details: false,
  updates_timer: false,
  install_kind: :manual,
  autostart_cmd: &Alnasl.NoReg.cmd/3,
  skip_migrations: true

config :logger, level: :warning

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
