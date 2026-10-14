#!/bin/sh
# Builds Alnasl.app around a finished release, on a Mac.
#
#   rel/macos/build_app.sh <release dir> <output dir>
#
# Run from the repository root by .github/workflows/release.yml on the macOS
# runners; it works the same on any Mac with the Xcode command line tools.
# Writes <output dir>/Alnasl.app, ad-hoc signed. Developer ID signing and
# notarisation are a separate step (sign_and_notarize.sh) that only runs
# when the certificate exists.
#
#   Alnasl.app/Contents/Info.plist         rel/macos/Info.plist, filled in
#   Alnasl.app/Contents/MacOS/Alnasl       rel/macos/launcher.sh
#   Alnasl.app/Contents/Resources/app/     the release, whole
#   Alnasl.app/Contents/Resources/Alnasl.icns   from rel/windows/Alnasl.ico
#
# Checked here, because nothing after this would notice until somebody's Mac
# refused to start the program:
#
#   * the serial library is in the release - an app that cannot open a
#     serial port is a simulator;
#   * every Mach-O file links only to the system (/usr/lib, /System) or to
#     itself. The runner has Homebrew; the arbiter's Mac does not;
#   * the oldest macOS every Mach-O file accepts (`minos`). The newest of
#     those goes into LSMinimumSystemVersion and the log.

set -eu

payload=${1:?usage: build_app.sh <release dir> <output dir>}
out=${2:?usage: build_app.sh <release dir> <output dir>}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

[ -x "$payload/bin/alnasl" ] || {
  echo "::error::$payload is not an Alnasl release (no bin/alnasl)" >&2
  exit 1
}
ls "$payload"/lib/circuits_uart-*/priv/circuits_uart >/dev/null 2>&1 || {
  echo "::error::the release has no serial program (circuits_uart); build with ALNASL_UART=1" >&2
  exit 1
}

# The release's own version, which mix.exs gave it - never a second copy.
version=$(tr -d '[:space:]' <"$payload/VERSION")
[ -n "$version" ] || {
  echo "::error::no version in $payload/VERSION" >&2
  exit 1
}

app="$out/Alnasl.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# ditto, not cp -R: it keeps modes, symlinks and extended attributes.
ditto "$payload" "$app/Contents/Resources/app"
cp "$here/launcher.sh" "$app/Contents/MacOS/Alnasl"
chmod 755 "$app/Contents/MacOS/Alnasl"

# The icon, from the Windows one (its largest picture). Cosmetic: a failure
# leaves Finder's generic icon and a warning, not a failed build.
make_icon() {
  sips -s format png "$1" --out "$2/source.png" >/dev/null || return 1
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$2/source.png" --out "$2/icon_${size}x${size}.png" >/dev/null ||
      return 1
    sips -z $((size * 2)) $((size * 2)) "$2/source.png" \
      --out "$2/icon_${size}x${size}@2x.png" >/dev/null || return 1
  done
  rm -f "$2/source.png"
  iconutil -c icns "$2" -o "$3"
}

iconset="$out/Alnasl.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
if make_icon rel/windows/Alnasl.ico "$iconset" "$app/Contents/Resources/Alnasl.icns"; then
  echo "Icon made from rel/windows/Alnasl.ico"
else
  echo "::warning::could not make Alnasl.icns; the app gets the generic icon"
fi
rm -rf "$iconset"

# Links and minimum system, per Mach-O file.
bad=0
minimum=11.0
found=$(mktemp)
find "$app" -type f -print0 | xargs -0 file | grep 'Mach-O' | cut -d: -f1 >"$found"
while IFS= read -r binary; do
  # Only what it loads: `otool -L` also prints a library's own id, which
  # for a precompiled NIF is a path on the machine that built it.
  libs=$(otool -l "$binary" | awk '/cmd LC_(LOAD|LOAD_WEAK|REEXPORT|LAZY_LOAD)_DYLIB$/ {f=1; next} f && $1 == "name" {print $2; f=0}')
  for lib in $libs; do
    case "$lib" in
      /usr/lib/* | /System/Library/* | @rpath/* | @loader_path/* | @executable_path/*) ;;
      *)
        echo "::error::$binary links to $lib, which a Mac without it does not have"
        bad=1
        ;;
    esac
  done

  minos=$(otool -l "$binary" | awk '
    /LC_BUILD_VERSION/ { want = "minos" }
    /LC_VERSION_MIN_MACOSX/ { want = "version" }
    want != "" && $1 == want { print $2; want = "" }' | head -1)
  if [ -n "$minos" ] && [ "$(printf '%s\n%s\n' "$minimum" "$minos" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$minos" ]; then
    minimum=$minos
  fi
done <"$found"
echo "Mach-O files: $(wc -l <"$found" | tr -d ' '), oldest macOS all of them accept: $minimum"
rm -f "$found"
[ "$bad" = 0 ] || exit 1

sed -e "s/__VERSION__/$version/g" -e "s/__MINIMUM_SYSTEM__/$minimum/g" \
  "$here/Info.plist" >"$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"

# Ad-hoc: every Mach-O carries a signature, which Apple Silicon requires
# before it runs anything, and the bundle is sealed. Gatekeeper still does
# not know who made it; see docs/macos.md.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

echo "Built $app ($version, macOS $minimum or newer)"
