#!/bin/bash
# Native shell packaging; this is a source handoff, not a Windows installer.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build"
stage="$(mktemp -d /tmp/quad-windows-source.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
cd "$root"
zip -q -r "$stage/source.zip" windows App/Sources/CFrameEncoder
unzip -t "$stage/source.zip"
mv "$stage/source.zip" "$root/build/QuadMonitor-Windows-ARM64-source.zip"
shasum -a 256 "$root/build/QuadMonitor-Windows-ARM64-source.zip"
