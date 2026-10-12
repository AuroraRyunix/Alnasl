#!/bin/sh
# Starts, or stops, the OpenPairings that `mix alnasl.link_e2e` talks to: a
# dev server on PORT (4061) in OPENPAIRINGS_DIR, on that checkout's own dev
# database - which `fresh` deletes first. Never point OPENPAIRINGS_DIR at a
# checkout whose dev database you care about.
#
#   sh tools/link_e2e_server.sh fresh    delete the dev database and migrate
#   sh tools/link_e2e_server.sh start    serve (in the foreground)
#   sh tools/link_e2e_server.sh stop     stop whatever listens on PORT
port="${PORT:-4061}"
cd "${OPENPAIRINGS_DIR:?set OPENPAIRINGS_DIR to the OpenPairings checkout}" || exit 1
unset MIX_BUILD_PATH MIX_DEPS_PATH MIX_ENV
[ -n "$OPENPAIRINGS_BUILD_PATH" ] && export MIX_BUILD_PATH="$OPENPAIRINGS_BUILD_PATH"
[ -n "$OPENPAIRINGS_DEPS_PATH" ] && export MIX_DEPS_PATH="$OPENPAIRINGS_DEPS_PATH"

case "$1" in
  fresh)
    rm -f pairings_engine_dev.db pairings_engine_dev.db-shm pairings_engine_dev.db-wal
    mix ecto.migrate --quiet
    ;;
  start)
    PORT="$port" exec mix phx.server
    ;;
  stop)
    if command -v netstat >/dev/null 2>&1 && command -v taskkill >/dev/null 2>&1; then
      for pid in $(netstat -ano | grep "LISTENING" | grep ":$port " | awk '{print $NF}' | sort -u); do
        taskkill //PID "$pid" //F >/dev/null 2>&1 && echo "stopped $pid"
      done
    else
      pid=$(lsof -ti "tcp:$port" 2>/dev/null) && kill $pid && echo "stopped $pid"
    fi
    ;;
  *)
    echo "usage: link_e2e_server.sh fresh|start|stop" >&2
    exit 2
    ;;
esac
