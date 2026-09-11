#!/bin/bash
# Build the installable native app without a Python interpreter.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
skip=0
installer_identity="${QUAD_MONITOR_INSTALLER_IDENTITY:-}"
app_args=(--standalone)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-build) skip=1; shift ;;
    --sign-identity) app_args+=(--sign-identity "$2"); shift 2 ;;
    --installer-identity) installer_identity="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[ "$skip" -eq 1 ] || "$root/scripts/build_native_app.sh" "${app_args[@]}"
app="$root/build/standalone/Quad Monitor.app"
codesign --verify --deep --strict "$app"
[ "$(plutil -extract engine raw "$app/Contents/Resources/desktop-config.json")" = native ]
team="$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ -n "$team" ] && [ "$team" != not\ set ]
identities=()
while IFS= read -r row; do
  digest="${row%%|*}"; name="${row#*|}"
  if [ -z "$installer_identity" ] || [ "$installer_identity" = "$digest" ] || [ "$installer_identity" = "$name" ]; then
    [[ "$name" == *"($team)" ]] && identities+=("$digest")
  fi
done < <(security find-identity -v -p basic | sed -n 's/.* \([A-Fa-f0-9]\{40\}\) "\(Developer ID Installer:.*\)"/\1|\2/p')
[ "${#identities[@]}" -eq 1 ] || { echo 'Select an Installer identity matching the app team' >&2; exit 2; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
stage="$(mktemp -d "$root/build/.native-pkg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/payload/Applications"
ditto "$app" "$stage/payload/Applications/Quad Monitor.app"
pkgbuild --analyze --root "$stage/payload" "$stage/components.plist"
index=0
while /usr/libexec/PlistBuddy -c "Print :$index" "$stage/components.plist" >/dev/null 2>&1; do
  /usr/libexec/PlistBuddy -c "Set :$index:BundleIsRelocatable false" "$stage/components.plist"
  /usr/libexec/PlistBuddy -c "Set :$index:BundleIsVersionChecked true" "$stage/components.plist"
  /usr/libexec/PlistBuddy -c "Set :$index:BundleHasStrictIdentifier true" "$stage/components.plist"
  index=$((index + 1))
done
pkgbuild --root "$stage/payload" --component-plist "$stage/components.plist" --identifier com.quadmonitor.desktop --version "$version" --install-location / "$stage/QuadMonitor-component.pkg"
cat > "$stage/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Quad Monitor</title>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <allowed-os-versions><os-version min="26.0"/></allowed-os-versions>
  <domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/>
  <choices-outline><line choice="default"><line choice="com.quadmonitor.desktop"/></line></choices-outline>
  <choice id="default"/>
  <choice id="com.quadmonitor.desktop" visible="false"><pkg-ref id="com.quadmonitor.desktop"/></choice>
  <pkg-ref id="com.quadmonitor.desktop" version="$version" onConclusion="none">QuadMonitor-component.pkg<must-close><app id="com.quadmonitor.desktop"/></must-close></pkg-ref>
</installer-gui-script>
XML
output="$root/build/QuadMonitor-$version-arm64.pkg"
productbuild --distribution "$stage/Distribution.xml" --package-path "$stage" --sign "${identities[0]}" --timestamp "$stage/installer.pkg"
pkgutil --check-signature "$stage/installer.pkg"
mv "$stage/installer.pkg" "$output"
shasum -a 256 "$output"
