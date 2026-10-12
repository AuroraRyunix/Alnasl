#!/bin/sh
# The whole of "The link, end to end" (README) in one go: a fresh throwaway
# OpenPairings on PORT (4061), seeded, and `mix alnasl.link_e2e` against it
# with the hook that plays the arbiter. Stops the server and deletes its
# database afterwards. Run from Alnasl's root:
#
#   OPENPAIRINGS_DIR=/path/to/a/scratch/openpairings sh tools/link_e2e_run.sh
#
# OPENPAIRINGS_DIR must be a checkout whose dev database may be deleted.
# Not for CI: it needs both programs, their dependencies, and two ports.
here=$(cd "$(dirname "$0")" && pwd)
export PORT="${PORT:-4061}"
log="${LINK_E2E_LOG:-$here/../tmp/link-e2e-openpairings.log}"
mkdir -p "$(dirname "$log")"

sh "$here/link_e2e_server.sh" stop
sh "$here/link_e2e_server.sh" fresh || exit 1
sh "$here/link_e2e_server.sh" start > "$log" 2>&1 &

tries=0
until [ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/api/boards/v1/link")" = "401" ]; do
  tries=$((tries + 1))
  if [ "$tries" -gt 120 ]; then
    echo "OpenPairings did not come up on port $PORT; see $log" >&2
    sh "$here/link_e2e_server.sh" stop
    exit 1
  fi
  sleep 1
done

seed=$(sh "$here/link_e2e_hook.sh" seed 2>&1)
group=$(printf '%s\n' "$seed" | sed -n 's/^CODE group //p' | tr -d '\r')
solo=$(printf '%s\n' "$seed" | sed -n 's/^CODE solo //p' | tr -d '\r')

if [ -z "$group" ]; then
  printf '%s\n' "$seed" | tail -20 >&2
  sh "$here/link_e2e_server.sh" stop
  exit 1
fi

cd "$here/.." || exit 1
mix alnasl.link_e2e --code "$group" --code "$solo" --hook "sh tools/link_e2e_hook.sh" "$@"
status=$?

sh "$here/link_e2e_server.sh" stop
( cd "$OPENPAIRINGS_DIR" && rm -f pairings_engine_dev.db pairings_engine_dev.db-shm pairings_engine_dev.db-wal )
exit $status
