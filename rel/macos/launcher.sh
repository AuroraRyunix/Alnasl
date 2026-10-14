#!/bin/sh
# The server half of Alnasl.app: copied to Contents/Resources/launcher.sh by
# rel/macos/build_app.sh and run by the app's own executable
# (rel/macos/Launcher.swift, Contents/MacOS/Alnasl), which is the half you
# see: the Dock icon, the small window, the browser, the question before
# stopping. Finder never runs this file directly; a terminal can.
#
#   1. Works out where it is from its own path and finds the release in
#      Contents/Resources/app.
#   2. If something already answers on the port, leaves at once (exit 0): a
#      second start is not a second server. The app then opens a tab.
#   3. Starts the release with the data in
#      ~/Library/Application Support/AlnaslData (unless ALNASL_DATA says
#      otherwise), Erlang distribution off, and every file it writes OUTSIDE
#      the bundle (see "Nothing is written into the app"). Its output is this
#      script's output; the app points that at logs/server.log in the data
#      folder, a fresh file on every start.
#   4. Waits until the port really answers, says so, and then waits for the
#      server for as long as it runs.
#
# ## Exit codes, which the app turns into sentences
#
#   0  stopped when asked, or another copy already answers
#   2  the release is missing from inside the app
#   3  the data folder cannot be created
#   4  the server stopped while starting
#   5  no answer within two minutes; the server has been stopped
#   anything else, once it answered: the server's own exit status
#
# ## Stopping
#
# SIGTERM, SIGINT or SIGHUP to this script sends SIGTERM to the BEAM - a
# clean `init:stop()`, the database closed in order - and up to twenty
# seconds before insisting. The app sends the SIGTERM on Quit (after asking),
# on logout and on shutdown (without asking).
#
# If the app itself disappears without that (Force Quit, a crash), this
# script notices its parent is gone and stops the server anyway: a server
# nobody can see is a server nobody can stop.
#
# ## Nothing is written into the app
#
# An unsigned app opened from Downloads runs from a read-only, translocated
# copy, and writing into a signed bundle breaks its seal. So RELEASE_TMP
# goes to the user's temporary folder, the working directory (crash dumps)
# is the data folder, and the data folder is one no update and no uninstall
# reaches - `Alnasl.DataHome` refuses any folder inside a `.app`. CI starts
# the app from a read-only bundle to prove it.
#
# ## No updates from here
#
# On Windows the launcher applies an update; a Mac app is replaced by hand
# for now (docs/macos.md). ALNASL_UPDATER=macos-app only tells the Setup page
# what kind of copy this is.

set -u

contents=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
app="$contents/Resources/app"
release="$app/bin/alnasl"

PORT=${PORT:-4040}
url="http://localhost:$PORT"
ALNASL_DATA=${ALNASL_DATA:-"$HOME/Library/Application Support/AlnaslData"}

answers() {
  curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/help" 2>/dev/null
}

if [ ! -x "$release" ]; then
  echo "Alnasl is incomplete: $release is missing." >&2
  exit 2
fi

# Already running: do not start a second one that cannot bind.
if answers; then
  echo "Alnasl already answers on $url"
  exit 0
fi

if ! mkdir -p "$ALNASL_DATA"; then
  echo "Alnasl cannot create its data folder: $ALNASL_DATA" >&2
  exit 3
fi

export ALNASL_DATA PORT
export ALNASL_UPDATER=macos-app
# rel/env.sh.eex makes this the default too; said here as well because this
# is the front door, and a Finder start passes nothing else in.
export RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-none}"
export RELEASE_TMP="${TMPDIR:-/tmp}/Alnasl"
# Finder starts an app with no locale, and the VM then runs in latin1.
export LANG="${LANG:-en_US.UTF-8}"
mkdir -p "$RELEASE_TMP"
cd "$ALNASL_DATA" || exit 3

echo "Starting $release ($url, data in $ALNASL_DATA)"
"$release" start &
pid=$!

stop_server() {
  kill -TERM "$pid" 2>/dev/null || return 0
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 1
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
}

# The parent watch: the app, gone without a word, takes the server with it.
# Not when the parent is launchd (pid 1), which `kill -0` cannot ask about.
parent=$PPID
watcher=
if [ "$parent" -gt 1 ]; then
  (
    while kill -0 "$parent" 2>/dev/null; do sleep 2; done
    kill -TERM $$ 2>/dev/null
  ) &
  watcher=$!
fi

trap 'if [ -n "$watcher" ]; then kill "$watcher" 2>/dev/null; fi' EXIT
trap 'stop_server; exit 0' TERM INT HUP

waited=0
until answers; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Alnasl could not start." >&2
    exit 4
  fi
  if [ "$waited" -ge 120 ]; then
    stop_server
    echo "Alnasl did not answer within two minutes, and has been stopped." >&2
    exit 5
  fi
  sleep 1
  waited=$((waited + 1))
done

echo "Alnasl answers on $url"
wait "$pid"
status=$?
exit "$status"
