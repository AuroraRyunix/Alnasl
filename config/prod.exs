import Config

# The box serves plain HTTP on the hall's network and to its own kiosk
# browser. There is no TLS to force and no host name to pin: it is reached by
# whatever address the hall gave it.
config :alnasl, AlnaslWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  check_origin: false,
  server: true

config :logger, level: :info
