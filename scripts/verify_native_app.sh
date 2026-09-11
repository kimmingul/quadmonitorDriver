#!/bin/bash
# Read-only runtime/package dependency check in an unrelated temporary directory.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/build/Quad Monitor.app}"
stage="$(mktemp -d /tmp/quad-native-relocation.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Quad Monitor.app"
app="$stage/Quad Monitor.app"
codesign --verify --deep --strict "$app"
if find "$app" \( -iname '*python*' -o -name '*.py' -o -name '*.pyc' \) -print | grep -q .; then
  echo 'Unexpected Python dependency' >&2; exit 1
fi
for binary in "$app/Contents/MacOS/QuadMonitor" "$app/Contents/Helpers/VerifiedSession" "$app/Contents/Helpers/VerifiedCapture" "$app/Contents/Helpers/VerifiedDesktopHost" "$app/Contents/Frameworks/libusb-1.0.0.dylib"; do
  file "$binary"
  while IFS= read -r dependency; do
    case "$dependency" in /System/Library/*|/usr/lib/*|@executable_path/*|@rpath/libusb-1.0.0.dylib) ;;
      *) echo "External dependency: $dependency" >&2; exit 1 ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
done
mkdir "$stage/empty"
cd "$stage/empty"
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$stage" "$app/Contents/Helpers/VerifiedSession" --runtime-check --control-dir "$stage/control"
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$stage" "$app/Contents/Helpers/VerifiedSession" --device-presence --control-dir "$stage/control"
echo 'Native app relocation verified; no Python runtime or project path required.'
