#!/bin/sh
# Alnasl.app's front door: copied to Contents/MacOS/Alnasl by
# rel/macos/build_app.sh, and what Finder runs when the app is opened.
#
# It follows Alnasl.exe (rel/windows/launcher.c) in everything an arbiter
# can see, as far as a shell script and macOS's own `osascript` allow:
#
#   1. Works out where it is from its own path and finds the release in
#      Contents/Resources/app.
#   2. If something already answers on the port, offers to open it in the
#      browser and leaves: a second double-click is not a second server.
#   3. Starts the release with the data in
#      ~/Library/Application Support/AlnaslData (unless ALNASL_DATA says
#      otherwise), Erlang distribution off, and every file it writes OUTSIDE
#      the bundle (see "Nothing is written into the app").
#   4. Waits until the port really answers, then opens the browser.
#   5. Stays, as a small window: "Alnasl is running", with "Open in browser"
#      and "Stop Alnasl". Stopping asks first, as on Windows: while Alnasl is
#      stopped the boards are not read.
#
# English, and Dutch when the Mac's first language is Dutch. The site has
# its own language setting; this window is on screen before anything could
# read it.
#
# The window is AppleScript's `display dialog`, run by `osascript`, which
# every Mac has: nothing compiled, nothing to sign separately. A menu-bar
# icon needs a real Cocoa program, which nobody here can run.
#
# ## Stopping
#
# SIGTERM to the BEAM - a clean `init:stop()`, the database closed in order
# - and up to twenty seconds before insisting. Logging out or shutting down
# sends this script SIGTERM, and the trap passes it on. If the server dies by
# itself, the window says so and names the log.
#
# ## Nothing is written into the app
#
# An unsigned app opened from Downloads runs from a read-only, translocated
# copy, and writing into a signed bundle breaks its seal. So RELEASE_TMP
# goes to the user's temporary folder, the working directory (crash dumps)
# is the data folder, and the data folder is one no update and no uninstall
# reaches - `Alnasl.DataHome` refuses any folder inside a `.app`. CI starts
# this file from a read-only bundle to prove it.
#
# ## No updates from here
#
# On Windows this launcher's twin applies an update; a Mac app is replaced
# by hand for now (docs/macos.md). ALNASL_UPDATER=macos-app only tells the
# Setup page what kind of copy this is.
#
# ## Headless (CI)
#
# ALNASL_LAUNCHER_NO_UI=1 skips every window and the browser, logs to
# standard output, and waits for the server.

set -u

contents=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
app="$contents/Resources/app"
release="$app/bin/alnasl"

PORT=${PORT:-4040}
url="http://localhost:$PORT"
ALNASL_DATA=${ALNASL_DATA:-"$HOME/Library/Application Support/AlnaslData"}
headless=${ALNASL_LAUNCHER_NO_UI:-}

version=$(cat "$app/VERSION" 2>/dev/null)
title="Alnasl${version:+ $version}"

case "$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p')" in
  *'"nl'* | *' nl'*) dutch=1 ;;
  *) dutch= ;;
esac

# say <English> <Dutch>
say() { if [ -n "$dutch" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

t_running=$(say "Alnasl is running at $url." "Alnasl draait op $url.")
t_running_hint=$(say \
  "Leave this window open: stopping Alnasl stops reading the boards." \
  "Laat dit venster open: als je Alnasl stopt, worden de borden niet meer gelezen.")
t_open=$(say "Open in browser" "Openen in browser")
t_stop=$(say "Stop Alnasl" "Alnasl stoppen")
t_keep=$(say "Keep running" "Laten draaien")
t_confirm=$(say \
  "Stop Alnasl? The boards are not read while it is stopped: moves played meanwhile have to be put right by hand." \
  "Alnasl stoppen? Zolang het gestopt is, worden de borden niet gelezen: zetten die intussen gespeeld worden, moet je achteraf met de hand rechtzetten.")
t_ok=$(say "OK" "OK")

# A dialog with one button. Texts go in as arguments, never into the
# script: a path with a quote in it must not become AppleScript.
tell() {
  if [ "$headless" = 1 ]; then
    echo "$1" >&2
    return
  fi
  osascript - "$1" "$title" "$t_ok" >/dev/null 2>&1 <<'EOF'
on run argv
  activate
  display dialog (item 1 of argv) with title (item 2 of argv) buttons {item 3 of argv} default button 1 with icon caution
end run
EOF
}

# Two buttons; prints the one chosen (nothing if the dialog went away).
ask() {
  osascript - "$1" "$title" "$2" "$3" 2>/dev/null <<'EOF'
on run argv
  activate
  set reply to display dialog (item 1 of argv) with title (item 2 of argv) buttons {item 3 of argv, item 4 of argv} default button 2
  return button returned of reply
end run
EOF
}

answers() {
  curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/help" 2>/dev/null
}

if [ ! -x "$release" ]; then
  tell "$(say \
    "Alnasl is incomplete: the program is missing from inside the app. Download it again and replace this copy." \
    "Alnasl is onvolledig: het programma ontbreekt in de app. Download hem opnieuw en vervang deze kopie.")"
  exit 1
fi

# Already running: show it, do not start a second one that cannot bind.
if answers; then
  [ "$headless" = 1 ] || open "$url"
  exit 0
fi

if ! mkdir -p "$ALNASL_DATA"; then
  tell "$(say "Alnasl cannot create its data folder: $ALNASL_DATA" \
    "Alnasl kan zijn gegevensmap niet maken: $ALNASL_DATA")"
  exit 1
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
cd "$ALNASL_DATA" || exit 1

if [ "$headless" = 1 ]; then
  log=/dev/stdout
  "$release" start &
else
  log="$ALNASL_DATA/launcher.log"
  {
    echo
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') $title from $contents"
  } >>"$log"
  "$release" start >>"$log" 2>&1 &
fi
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

trap 'stop_server; exit 0' TERM INT HUP

waited=0
until answers; do
  if ! kill -0 "$pid" 2>/dev/null; then
    tell "$(say "Alnasl could not start. The reason is at the end of this file: $log" \
      "Alnasl kon niet starten. De reden staat aan het einde van dit bestand: $log")"
    exit 1
  fi
  if [ "$waited" -ge 120 ]; then
    stop_server
    tell "$(say "Alnasl did not answer within two minutes, and has been stopped. This file says how far it got: $log" \
      "Alnasl antwoordde niet binnen twee minuten en is gestopt. In dit bestand staat hoe ver het kwam: $log")"
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done

if [ "$headless" = 1 ]; then
  echo "Alnasl answers on $url"
  wait "$pid"
  exit $?
fi

open "$url"

# The status window, for as long as the server runs. A dialog that cannot
# be shown at all (no window server) fails at once; three in a row and the
# launcher stops trying and simply waits.
answer_file="$RELEASE_TMP/launcher-answer.$$"
quick_failures=0
while kill -0 "$pid" 2>/dev/null; do
  started=$(date +%s)
  ask "$t_running

$t_running_hint" "$t_stop" "$t_open" >"$answer_file" &
  dialog=$!

  while kill -0 "$dialog" 2>/dev/null; do
    if ! kill -0 "$pid" 2>/dev/null; then
      kill "$dialog" 2>/dev/null
      break
    fi
    sleep 1
  done
  wait "$dialog" 2>/dev/null
  reply=$(cat "$answer_file" 2>/dev/null)

  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$answer_file"
    tell "$(say "Alnasl has stopped by itself. The reason is at the end of this file: $log" \
      "Alnasl is vanzelf gestopt. De reden staat aan het einde van dit bestand: $log")"
    exit 1
  fi

  case "$reply" in
    "$t_stop")
      if [ "$(ask "$t_confirm" "$t_keep" "$t_stop")" = "$t_stop" ]; then
        rm -f "$answer_file"
        stop_server
        exit 0
      fi
      ;;
    "$t_open")
      quick_failures=0
      open "$url"
      ;;
    *)
      if [ $(($(date +%s) - started)) -lt 3 ]; then
        quick_failures=$((quick_failures + 1))
      else
        quick_failures=0
      fi
      if [ "$quick_failures" -ge 3 ]; then
        rm -f "$answer_file"
        wait "$pid"
        exit $?
      fi
      sleep 1
      ;;
  esac
done

rm -f "$answer_file"
exit 0
