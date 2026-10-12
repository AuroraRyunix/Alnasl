#!/bin/sh
# One step of `mix alnasl.link_e2e` on the OpenPairings side: runs
# tools/link_e2e_openpairings.exs <step> inside an OpenPairings checkout.
#
#   OPENPAIRINGS_DIR         the checkout (required)
#   PORT                     the port that OpenPairings serves on (for the codes it prints)
#   OPENPAIRINGS_BUILD_PATH  its MIX_BUILD_PATH, when it has one of its own
#   OPENPAIRINGS_DEPS_PATH   its MIX_DEPS_PATH, when it has one of its own
#
# Mix's own variables are not inherited from the caller: they are Alnasl's.
here=$(cd "$(dirname "$0")" && pwd)
cd "${OPENPAIRINGS_DIR:?set OPENPAIRINGS_DIR to the OpenPairings checkout}" || exit 1
unset MIX_BUILD_PATH MIX_DEPS_PATH MIX_ENV
[ -n "$OPENPAIRINGS_BUILD_PATH" ] && export MIX_BUILD_PATH="$OPENPAIRINGS_BUILD_PATH"
[ -n "$OPENPAIRINGS_DEPS_PATH" ] && export MIX_DEPS_PATH="$OPENPAIRINGS_DEPS_PATH"
exec mix run "$here/link_e2e_openpairings.exs" "$1"
