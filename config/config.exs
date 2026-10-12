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

# Whether the outbox delivers by itself and the linked boards start with the
# application. Off in tests, which drive both by hand.
config :alnasl, autostart: true

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

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
