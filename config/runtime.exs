import Config

# Runtime configuration: read when the application starts, in every
# environment, also inside a release.

if System.get_env("PHX_SERVER") do
  config :alnasl, AlnaslWeb.Endpoint, server: true
end

# Where everything is kept. No environment variable is required: a box that
# has to be configured before it starts is a box that does not start in a
# playing hall. `Alnasl.DataHome` says where an installed copy keeps it and
# why that is never a folder an installer owns.
data_dir =
  cond do
    data = System.get_env("ALNASL_DATA") -> Path.expand(data)
    config_env() == :prod -> Path.expand(Alnasl.DataHome.default())
    true -> nil
  end

# Who may reach the management site: the box itself (the default, and the
# safe one - there is no PIN on a box nobody has set up yet), or the hall's
# network (an arbiter's laptop, the phone the boards are numbered with).
# ALNASL_LISTEN=lan|local decides when it is set. When it is not, the choice
# made on Setup does: a one-word file in the data directory, because the
# address is bound before the database is open. Access from elsewhere is
# behind the PIN, when one is set.
listen_choice =
  System.get_env("ALNASL_LISTEN") ||
    with dir when is_binary(dir) <- data_dir,
         {:ok, word} <- File.read(Path.join(dir, "listen")) do
      String.trim(word)
    else
      _none -> "local"
    end

listen = if listen_choice == "lan", do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

if config_env() != :test do
  config :alnasl, AlnaslWeb.Endpoint,
    http: [ip: listen, port: String.to_integer(System.get_env("PORT", "4040"))]
end

# A box with no hall of its own (the hosted server): no serial ports, no
# loops, no simulators, nothing started from a port. Its boards arrive from
# Arkab bridges, and everything after the board's own process - the tracker,
# the outbox, the destinations, the site - runs as anywhere else. Unset, the
# box reads what is plugged into it, as it always has.
if System.get_env("ALNASL_NO_LOCAL_BOARDS") in ~w(1 true yes) do
  config :alnasl, local_boards: false
end

# Who is an admin of this installation - everything, every hall - without
# a row saying so: the addresses here, comma-separated. On the server they
# are the people who may invite others, and who may sign in with 02cloud
# before they have an account. Optional on a box in a hall, whose first
# account is its admin anyway.
config :alnasl,
  admin_emails:
    (System.get_env("ALNASL_ADMIN_EMAILS") || "")
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))

# "Sign in with 02cloud" (Keycloak, `Alnasl.Keycloak`): shown only when a
# client secret is set. The secret goes in a file only root reads (the
# deploy script does that for every name with SECRET in it).
if keycloak_secret = System.get_env("ALNASL_KEYCLOAK_CLIENT_SECRET") do
  keycloak_url =
    (System.get_env("ALNASL_KEYCLOAK_URL") || "https://auth.zerotwo.cloud")
    |> String.trim_trailing("/")

  realm = System.get_env("ALNASL_KEYCLOAK_REALM") || "zerotwo"

  config :alnasl, :keycloak,
    issuer: "#{keycloak_url}/realms/#{realm}",
    client_id: System.get_env("ALNASL_KEYCLOAK_CLIENT_ID") || "alnasl",
    client_secret: keycloak_secret,
    # Unset: built from the address the browser used, so a box in a hall
    # and the server need nothing more.
    redirect_uri: System.get_env("ALNASL_KEYCLOAK_REDIRECT_URI")
end

# The OpenPairings that "Connect an OpenPairings account" on Setup offers
# first (`Alnasl.OpenPairings.Connect`). Unset on a box in a hall, where the
# arbiter types it once and it is remembered; the hosted server sets it to
# its neighbour.
config :alnasl, openpairings_url: System.get_env("ALNASL_OPENPAIRINGS_URL")

# Theme packs (`Alnasl.ThemePacks`): `<data dir>/themes` unless this says
# otherwise. Unset is the normal case; nothing is installed by default.
if themes_dir = System.get_env("ALNASL_THEMES_DIR") do
  config :alnasl, themes_dir: Path.expand(themes_dir)
end

if data_dir do
  config :alnasl, data_dir: data_dir
  config :alnasl, Alnasl.Repo, database: Path.join(data_dir, "alnasl.db")
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
  data = data_dir

  # Refused before anything is written there: data inside a folder that an
  # update replaces or an uninstall removes is data with a date on it.
  if reason = Alnasl.DataHome.refusal(data) do
    raise Alnasl.DataHome.refusal_message(data, reason)
  end

  File.mkdir_p!(data)

  config :alnasl, Alnasl.Repo, pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

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

  # The address links are built from: invitations, bridge join links, the
  # phone's QR code. A hall box is reached on its own port, so the endpoint's
  # port is right there. The server sits behind a tunnel that speaks https on
  # 443, and its own port 4006 is a number no visitor can reach - so there
  # the public address is https on 443, as OpenPairings has it.
  # ALNASL_PUBLIC_URL (https://alnasl.example.org) overrides both.
  url =
    case System.get_env("ALNASL_PUBLIC_URL") do
      public when public not in [nil, ""] ->
        %URI{scheme: scheme, host: host, port: port} = URI.parse(public)
        [host: host, port: port, scheme: scheme]

      _unset ->
        host = System.get_env("PHX_HOST") || "localhost"

        if System.get_env("ALNASL_NO_LOCAL_BOARDS") in ~w(1 true yes) and host != "localhost",
          do: [host: host, port: 443, scheme: "https"],
          else: [host: host]
    end

  config :alnasl, AlnaslWeb.Endpoint,
    url: url,
    secret_key_base: secret
end
