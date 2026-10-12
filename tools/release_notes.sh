#!/bin/sh
# Prints the section of CHANGELOG.md for one version: what a release's page
# on GitHub says.
#
#   sh tools/release_notes.sh 0.2.0
#
# Exit 1, and nothing printed, when the changelog has no section
# "## [0.2.0]" or the section is empty. The release workflow takes that for
# "this version is not ready to be released" and publishes nothing.
set -eu

version="${1:?usage: release_notes.sh VERSION [CHANGELOG]}"
changelog="${2:-CHANGELOG.md}"

awk -v heading="## [$version]" '
    index($0, heading) == 1 { on = 1; next }
    on && index($0, "## [") == 1 { exit }
    on && /[^ \t\r]/ { seen = 1 }
    on && seen { print }
    END { exit seen ? 0 : 1 }
' "$changelog"
