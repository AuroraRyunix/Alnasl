import Config

# Runtime configuration: read when the application starts, in every
# environment, also inside a release.

if System.get_env("PHX_SERVER") do
  config :alnasl, AlnaslWeb.Endpoint, server: true
end

# ALNASL_LISTEN=lan lets other machines in the hall reach the management
# site (an arbiter's laptop). Without it only the box itself can. Access
# from elsewhere is then behind the PIN, when one is set (Setup).
listen =
  case System.get_env("ALNASL_LISTEN") do
    "lan" -> {0, 0, 0, 0}
    _local -> {127, 0, 0, 1}
  end

if config_env() != :test do
  config :alnasl, AlnaslWeb.Endpoint,
    http: [ip: listen, port: String.to_integer(System.get_env("PORT", "4040"))]
end

if data = System.get_env("ALNASL_DATA") do
  config :alnasl, data_dir: Path.expand(data)
  config :alnasl, Alnasl.Repo, database: Path.join(Path.expand(data), "alnasl.db")
end

if config_env() == :dev do
  config :alnasl, AlnaslWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"priv/gettext/.*\.po$"E,
        ~r"lib/alnasl_web/router\.ex$"E,
        ~r"lib/alnasl_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # Everything the box keeps lives in one directory. No environment variable
  # is required: a box that has to be configured before it starts is a box
  # that does not start in a playing hall.
  data = Path.expand(System.get_env("ALNASL_DATA") || "~/.alnasl")
  File.mkdir_p!(data)

  config :alnasl, data_dir: data

  config :alnasl, Alnasl.Repo,
    database: Path.join(data, "alnasl.db"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The cookie-signing secret is made once and kept beside the data.
  secret_file = Path.join(data, "secret_key_base")

  secret =
    System.get_env("SECRET_KEY_BASE") ||
      case File.read(secret_file) do
        {:ok, secret} when byte_size(secret) >= 64 ->
          String.trim(secret)

        _missing ->
          secret = 48 |> :crypto.strong_rand_bytes() |> Base.encode64()
          File.write!(secret_file, secret)
          File.chmod(secret_file, 0o600)
          secret
      end

  config :alnasl, AlnaslWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST") || "localhost"],
    secret_key_base: secret
end
