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
echo "Starting Alnasl on http://localhost:$PORT"
echo "Data: ${ALNASL_DATA:-$HOME/.alnasl}"
echo "Press Ctrl-C to stop it. The boards are not read while it is stopped."
echo
exec "$here/bin/alnasl" start
