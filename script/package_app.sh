#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <swift-bin-directory> <output-app>" >&2
  exit 2
fi

BIN_DIR="$1"
OUTPUT_APP="$2"
APP_NAME="AnokhaLauncher"
BUNDLE_ID="com.anokha.launcher"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/anokha-package.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP_BUNDLE="$STAGING_ROOT/AnokhaLauncher.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_HELPERS"
cp "$BIN_DIR/AnokhaLauncher" "$APP_MACOS/AnokhaLauncher"
cp "$BIN_DIR/AnokhaJobRunner" "$APP_HELPERS/AnokhaJobRunner"
chmod +x "$APP_MACOS/AnokhaLauncher" "$APP_HELPERS/AnokhaJobRunner"

cat >"$APP_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Anokha Launcher</string>
  <key>CFBundleExecutable</key>
  <string>AnokhaLauncher</string>
  <key>CFBundleIdentifier</key>
  <string>com.anokha.launcher</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AnokhaLauncher</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Anokha Launcher contributors.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$APP_CONTENTS/Info.plist" >/dev/null
xattr -cr "$APP_BUNDLE"

SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:--}"
SIGN_ARGUMENTS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGUMENTS+=(--timestamp)
fi
codesign "${SIGN_ARGUMENTS[@]}" "$APP_HELPERS/AnokhaJobRunner"
codesign "${SIGN_ARGUMENTS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

rm -rf "$OUTPUT_APP"
mkdir -p "$(dirname "$OUTPUT_APP")"
ditto --norsrc --noextattr "$APP_BUNDLE" "$OUTPUT_APP"
codesign --verify --deep --strict "$OUTPUT_APP"
