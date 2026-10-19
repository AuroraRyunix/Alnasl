# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :alnasl,
  ecto_repos: [Alnasl.Repo],
  generators: [timestamp_type: :utc_datetime]

# Where the box keeps what it must not lose: the database, the raw captures,
# the PGN of every game. Overridden per environment and by ALNASL_DATA.
config :alnasl, data_dir: Path.expand("../data", __DIR__)

# Whether the box asks GitHub, on a timer, if a newer version is out. Off in
# tests, which ask when they mean to.
config :alnasl, updates_timer: true

# Whether the outbox delivers by itself and the linked boards start with the
# application. Off in tests, which drive both by hand.
config :alnasl, autostart: true

# A board that answers on a loop nobody reads it on yet is the box's to
# make a row of: Arkab's bus driver tells `Alnasl.Loops`.
config :arkab, loop_stranger: {Alnasl.Loops, :stranger}

# SQLite, in WAL mode, and with every commit forced to the disk before it
# counts: "written first" has to survive the plug being pulled. The box
# writes a few rows a move; it can afford the fsync.
config :alnasl, Alnasl.Repo,
  journal_mode: :wal,
  synchronous: :full,
  busy_timeout: 10_000,
  log: false

config :alnasl, AlnaslWeb.Gettext, default_locale: "en", locales: ~w(en nl)

config :phoenix_live_view, :colocated_assets, disable_symlink_warning: true

# Configure the endpoint
config :alnasl, AlnaslWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  # At a stop, open connections (every spectator's live page) get three
  # seconds to go, not Bandit's fifteen, which the Mac launcher's twenty
  # barely covered and a restart did not need.
  http: [thousand_island_options: [shutdown_timeout: 3_000]],
  render_errors: [
    formats: [html: AlnaslWeb.ErrorHTML, json: AlnaslWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Alnasl.PubSub,
  live_view: [signing_salt: "xggYrlZx"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  alnasl: [
    args:
      ~w(js/theme.js js/app.js css/app.css --bundle --target=es2022 --outbase=. --outdir=../priv/static/assets --external:/fonts/* --external:/images/* --external:/pieces/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
# What never goes into a log, at any level: the secrets a form carries. The
# PIN, a relay key, a Lichess token, a connect code.
config :phoenix, :filter_parameters, ["password", "pin", "relay_key", "token", "code", "secret"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# The SQLite NIF compiled here instead of downloaded, when the build asks
# (the macOS job sets EXQLITE_FORCE_BUILD): the precompiled one wants macOS
# 14, and the app promises 11. rel/macos/build_app.sh checks the result.
if System.get_env("EXQLITE_FORCE_BUILD") == "true" do
  config :exqlite, force_build: true
end

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
