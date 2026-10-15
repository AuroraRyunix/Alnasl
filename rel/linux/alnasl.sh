#!/bin/sh
# Starts Alnasl from this folder, in this terminal, without installing
# anything: to try it, or on a box you would rather not install a service on.
# install.sh, beside this file, is the other way.
#
# The data goes to ~/.alnasl (or ALNASL_DATA), not into this folder: a new
# version unpacked beside the old one finds it.
set -e
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PORT=${PORT:-4040}
export PORT

# `./alnasl.sh details [--once | --json]`: the numbers the Windows launcher's
# Details panel shows (version, uptime, CPU, memory, the database, the boards,
# the results relay) and the last lines of the log, in this terminal. It asks
# the Alnasl already running from this data folder, through a second,
# short-lived runtime (`eval` starts nothing of the server); see
# Alnasl.LauncherDetails.CLI and docs/launcher-details.md.
if [ "${1:-}" = details ]; then
  shift
  exec "$here/bin/alnasl" eval "Alnasl.LauncherDetails.CLI.main()" "$@"
fi

echo "Starting Alnasl on http://localhost:$PORT"
echo "Data: ${ALNASL_DATA:-$HOME/.alnasl}"
echo "Press Ctrl-C to stop it. The boards are not read while it is stopped."
echo
exec "$here/bin/alnasl" start
