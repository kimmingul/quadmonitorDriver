#!/bin/bash
# Self-contained Swift/C app. Python, uv and Python frameworks are not used.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(cat "$root/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid VERSION' >&2; exit 2; }
identity="${QUAD_MONITOR_SIGN_IDENTITY:-}"
skip=0
output="$root/build"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-build) skip=1; shift ;;
    --standalone) output="$root/build/standalone"; shift ;;
    --sign-identity) identity="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$identity" ]; then
  identities=()
  while IFS= read -r digest; do [ -z "$digest" ] || identities+=("$digest"); done < <(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ {print $2}')
  [ "${#identities[@]}" -eq 1 ] || { echo 'Select one Developer ID Application with --sign-identity' >&2; exit 2; }
  identity="${identities[0]}"
fi
if [ "$skip" -eq 0 ]; then
  for product in QuadMonitor VerifiedCapture VerifiedDesktopHost VerifiedSession; do
    swift build --package-path "$root/App" -c release --product "$product"
  done
fi
mkdir -p "$output"
stage="$(mktemp -d "$output/.native-app.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Quad Monitor.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Helpers" "$contents/Frameworks" "$contents/Resources"
release="$root/App/.build/release"
cp "$release/QuadMonitor" "$contents/MacOS/QuadMonitor"
for helper in VerifiedCapture VerifiedDesktopHost VerifiedSession; do cp "$release/$helper" "$contents/Helpers/$helper"; done
bundle=QuadMonitor_QuadMonitor.bundle
for language in en ko zh-hans; do test -f "$release/$bundle/$language.lproj/Localizable.strings"; done
cp -R "$release/$bundle" "$contents/Resources/"
cp "$root/config/panel-layout.json" "$contents/Resources/panel-layout.json"
cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>QuadMonitor</string>
<key>CFBundleIdentifier</key><string>com.quadmonitor.desktop</string>
<key>CFBundleName</key><string>Quad Monitor</string>
<key>CFBundleDisplayName</key><string>Quad Monitor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string><string>zh-Hans</string></array>
<key>LSUIElement</key><true/><key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
printf '%s\n' '{"packaged":"true","engine":"native"}' > "$contents/Resources/desktop-config.json"
libusb="$(otool -L "$contents/MacOS/QuadMonitor" | awk '/libusb-1.0.0.dylib / {print $1}')"
[ -f "$libusb" ] || { echo 'Cannot locate linked libusb' >&2; exit 1; }
cp "$libusb" "$contents/Frameworks/libusb-1.0.0.dylib"
cp "$(dirname "$(dirname "$libusb")")/COPYING" "$contents/Resources/libusb-COPYING.txt"
install_name_tool -id '@rpath/libusb-1.0.0.dylib' "$contents/Frameworks/libusb-1.0.0.dylib"
for binary in "$contents/MacOS/QuadMonitor" "$contents/Helpers/VerifiedCapture" "$contents/Helpers/VerifiedSession"; do
  install_name_tool -change "$libusb" '@executable_path/../Frameworks/libusb-1.0.0.dylib' "$binary"
done
sign() {
  target="$1"; name="$2"; kind="$3"
  args=(--force --sign "$identity" --identifier "$name")
  if [ "$identity" != '-' ]; then
    args+=(--timestamp)
    [ "$kind" != executable ] || args+=(--options runtime)
  fi
  codesign "${args[@]}" "$target"
  codesign --verify --deep --strict "$target"
}
sign "$contents/Frameworks/libusb-1.0.0.dylib" com.quadmonitor.libusb library
for helper in VerifiedCapture VerifiedDesktopHost VerifiedSession; do
  sign "$contents/Helpers/$helper" "com.quadmonitor.desktop.$helper" executable
done
(cd "$root" && rg --files App/Sources | LC_ALL=C sort | xargs shasum -a 256) > "$contents/Resources/build-sources.sha256"
sign "$app" com.quadmonitor.desktop executable
plutil -lint "$contents/Info.plist"
if find "$app" \( -iname '*python*' -o -name '*.py' -o -name '*.pyc' \) -print | grep -q .; then
  echo 'Unexpected Python content in native app' >&2; exit 1
fi
installed="$output/Quad Monitor.app"
backup=''
if [ -e "$installed" ]; then
  mkdir -p "$root/build/archive"
  backup="$(mktemp -d "$root/build/archive/quad-previous-native.XXXXXX")/Quad Monitor.app"
  mv "$installed" "$backup"
fi
if ! mv "$app" "$installed"; then
  [ -z "$backup" ] || mv "$backup" "$installed"
  exit 1
fi
printf 'App: %s\n' "$installed"
[ -z "$backup" ] || printf 'Previous app: %s\n' "$backup"
