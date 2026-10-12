#!/bin/sh
# Removes the Alnasl program from a box installed with install.sh.
#
#   sudo /opt/alnasl/uninstall.sh
#
# It removes the service, its units and /opt/alnasl. It does NOT remove the
# data, the service's settings or the user that owns the data: games, PGN,
# captures, relay keys and connect codes are still there when Alnasl is
# installed again, and they are yours to delete. The last lines say how.

set -eu

INSTALL_DIR="/opt/alnasl"
DATA_DIR="/var/lib/alnasl"
UNIT_DIR="/etc/systemd/system"

main() {
    [ "$(id -u)" = 0 ] || { echo "run this as root: sudo $0" >&2; exit 1; }

    for unit in alnasl-update.path alnasl-update.service alnasl.service; do
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        rm -f "$UNIT_DIR/$unit"
    done
    systemctl daemon-reload || true

    # The program, and what the updater noted about its last run. Nothing
    # else: the two paths are spelled out so that no variable can be empty.
    rm -rf /opt/alnasl
    rm -rf /var/lib/alnasl-update

    echo "Alnasl is removed from $INSTALL_DIR."
    echo "Your data is untouched, in $DATA_DIR, and so are the settings in /etc/alnasl."
    echo "Installing Alnasl again finds both."
    echo "To delete the data for good - there is no way back - that is yours to do:"
    echo "  the folder $DATA_DIR, the folder /etc/alnasl, and the user 'alnasl'."
}

main "$@"
