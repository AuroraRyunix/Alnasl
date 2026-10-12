#!/bin/sh
# Installs Alnasl on a Linux box - a small PC or a Raspberry Pi in the hall -
# as a service that starts with the machine.
#
#   curl -fsSL https://github.com/AuroraRyunix/Alnasl/releases/latest/download/install.sh | sudo sh
#
# or, in a hall without internet, from a release unpacked on a stick:
#
#   tar -xzf alnasl-linux-x86_64.tar.gz && sudo sh alnasl/install.sh
#
# Options (after `sh -s --` when piped):
#   --lan             let other machines in the hall reach the site from the
#                     first start (a box without a screen). Set a PIN at once.
#   --version X.Y.Z   that release instead of the latest
#
# What it does, and nothing more:
#   /opt/alnasl            the program, owned by root; replaced by updates
#   /var/lib/alnasl        the data, owned by the user "alnasl"; never
#                          replaced, never removed - not by an update, not by
#                          uninstall.sh
#   /etc/alnasl/alnasl.env the two settings of the service (port, network);
#                          written once and then left to you
#   a system user "alnasl" in the group "dialout" (the serial ports)
#   alnasl.service, alnasl-update.path, alnasl-update.service
#
# Run it again to repair an installation; it changes no setting and no data.
#
# Needs: a 64-bit system (x86_64 or arm64) with systemd and glibc 2.35 or
# newer - Debian 12, Ubuntu 22.04, Raspberry Pi OS (64-bit) "Bookworm", or
# later. The runtime is inside; nothing else is installed.

set -eu

REPO="AuroraRyunix/Alnasl"
INSTALL_DIR="/opt/alnasl"
DATA_DIR="/var/lib/alnasl"
CONF_DIR="/etc/alnasl"
SERVICE_USER="alnasl"

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "install.sh: $*" >&2; exit 1; }

main() {
    lan=0
    wanted=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --lan) lan=1; shift ;;
            --version) wanted="$2"; shift 2 ;;
            -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done

    [ "$(id -u)" = 0 ] || die "run this as root (sudo)."
    [ "$(uname -s)" = Linux ] || die "this installs on Linux. For Windows there is Alnasl-Setup.exe."
    command -v systemctl >/dev/null 2>&1 || die "this needs systemd, and found none."

    for tool in curl tar sha256sum getent useradd; do
        command -v "$tool" >/dev/null 2>&1 || die "this needs '$tool', which is not installed."
    done

    case "$(uname -m)" in
        x86_64 | amd64) cpu=x86_64 ;;
        aarch64 | arm64) cpu=aarch64 ;;
        armv7l | armv6l) die "this is a 32-bit system ($(uname -m)). Alnasl is built for 64-bit only: install the 64-bit Raspberry Pi OS." ;;
        *) die "there is no build for this processor ($(uname -m))." ;;
    esac

    # The runtime inside the release was built against glibc 2.35. On an
    # older system it dies at start with a line about GLIBC_2.3x; better to
    # say so here, in words.
    libc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    if [ -n "$libc" ]; then
        major=${libc%%.*}
        minor=${libc#*.}
        minor=${minor%%.*}
        if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 35 ]; }; then
            die "this system's C library is glibc $libc; Alnasl needs 2.35 or newer (Debian 12, Ubuntu 22.04, Raspberry Pi OS Bookworm)."
        fi
    else
        die "this system does not use glibc (Alpine?). There is no build for it."
    fi

    # A release this script stands in, or one to fetch.
    here=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo "")
    tmp=""
    trap 'if [ -n "$tmp" ]; then rm -rf "$tmp"; fi' EXIT

    if [ -z "$wanted" ] && [ -n "$here" ] && [ -x "$here/bin/alnasl" ] && [ -r "$here/VERSION" ]; then
        src="$here"
        say "Installing the release in $src."
    else
        file="alnasl-linux-$cpu.tar.gz"
        if [ -n "$wanted" ]; then
            base="https://github.com/$REPO/releases/download/v$wanted"
        else
            base="https://github.com/$REPO/releases/latest/download"
        fi

        tmp=$(mktemp -d /tmp/alnasl-install.XXXXXX)
        say "Downloading $base/$file"
        curl -fsSL --retry 2 -o "$tmp/$file" "$base/$file" || die "the download did not succeed."
        curl -fsSL --retry 2 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || die "the checksums could not be downloaded."
        (cd "$tmp" && grep " $file\$" SHA256SUMS | sha256sum -c - >/dev/null 2>&1) ||
            die "the download does not match its checksum."
        tar -xzf "$tmp/$file" -C "$tmp"
        src="$tmp/alnasl"
    fi

    [ -x "$src/bin/alnasl" ] || die "that is not an Alnasl release: no bin/alnasl in it."

    # The user the service runs as. No shell, no password; its home is the
    # data directory.
    if ! getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --user-group --home-dir "$DATA_DIR" --no-create-home \
            --shell /usr/sbin/nologin "$SERVICE_USER"
    fi

    if getent group dialout >/dev/null 2>&1; then
        usermod -aG dialout "$SERVICE_USER"
    else
        say "Note: this system has no group 'dialout'. Give the user '$SERVICE_USER' access to the serial ports yourself."
    fi

    install -d -o root -g root -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/releases" "$CONF_DIR"
    install -d -o root -g root -m 0755 /var/lib/alnasl-update
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$DATA_DIR"
    # Where the Setup page leaves its request for an update.
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$DATA_DIR/update"

    # Written once. An installation that is repaired or updated keeps what
    # the arbiter made of it.
    if [ ! -e "$CONF_DIR/alnasl.env" ]; then
        {
            echo "# Settings of the Alnasl service. Restart it after a change:"
            echo "#   sudo systemctl restart alnasl"
            echo "PORT=4040"
            echo ""
            echo "# Who may open the management site. Without this line the switch on"
            echo "# Setup (\"Access from other machines\") decides, and a new box answers"
            echo "# only itself. With it, the line decides: lan or local."
            if [ "$lan" = 1 ]; then
                echo "ALNASL_LISTEN=lan"
            else
                echo "#ALNASL_LISTEN=lan"
            fi
        } >"$CONF_DIR/alnasl.env"
        chmod 0644 "$CONF_DIR/alnasl.env"
    fi

    # The release, the units and the two scripts: update.sh knows how, and
    # is how it is done every time after this one.
    sh "$src/update.sh" --from "$src" --no-restart

    systemctl daemon-reload
    systemctl enable alnasl.service alnasl-update.path >/dev/null 2>&1
    systemctl restart alnasl-update.path
    systemctl restart alnasl.service

    version=$(tr -d ' \t\r\n' <"$src/VERSION")
    say ""
    say "Alnasl $version is installed and running."
    say "  The site:    http://localhost:4040 on this box"
    if [ "$lan" = 1 ]; then
        say "               and http://<this box's address>:4040 from the hall's network."
        say "               There is no PIN yet: open Setup and set one now."
    else
        say "               (Setup, \"Access from other machines\", opens it to the hall's network.)"
    fi
    say "  The data:    $DATA_DIR"
    say "  The program: $INSTALL_DIR"
    say "  Its log:     journalctl -u alnasl"
    say "  Update:      on the Setup page, or: sudo $INSTALL_DIR/update.sh"
    say "  Remove:      sudo $INSTALL_DIR/uninstall.sh   (keeps the data)"
}

main "$@"
