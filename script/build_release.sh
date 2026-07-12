#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-production}"
if [[ "$MODE" != "production" && "$MODE" != "--local" ]]; then
  echo "usage: $0 [--local]" >&2
  exit 2
fi
if [[ "$MODE" == "production" ]]; then
  if [[ -z "${DEVELOPER_ID_APPLICATION:-}" || -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Production releases require DEVELOPER_ID_APPLICATION and NOTARY_PROFILE. Use --local for an ad-hoc verification archive." >&2
    exit 2
  fi
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/dist/release"
APP_BUNDLE="$OUTPUT_DIR/AnokhaLauncher.app"
ARCHIVE="$OUTPUT_DIR/AnokhaLauncher-0.1.0-universal.zip"

export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/swift-module-cache"

cd "$ROOT_DIR"
swift build --disable-sandbox -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build --disable-sandbox -c release --arch arm64 --arch x86_64 --show-bin-path)"
"$ROOT_DIR/script/package_app.sh" "$BIN_DIR" "$APP_BUNDLE"

lipo -info "$APP_BUNDLE/Contents/MacOS/AnokhaLauncher"
lipo -info "$APP_BUNDLE/Contents/Helpers/AnokhaJobRunner"

rm -f "$ARCHIVE"
ditto -c -k --keepParent --norsrc --noextattr "$APP_BUNDLE" "$ARCHIVE"

if [[ "$MODE" == "production" ]]; then
  xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
  rm -f "$ARCHIVE"
  ditto -c -k --keepParent --norsrc --noextattr "$APP_BUNDLE" "$ARCHIVE"
fi

VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/anokha-release-verify.XXXXXX")"
trap 'rm -rf "$VERIFY_ROOT"' EXIT
ditto -x -k "$ARCHIVE" "$VERIFY_ROOT"
DELIVERED_APP="$VERIFY_ROOT/AnokhaLauncher.app"
codesign --verify --deep --strict "$DELIVERED_APP"
plutil -lint "$DELIVERED_APP/Contents/Info.plist" >/dev/null
lipo "$DELIVERED_APP/Contents/MacOS/AnokhaLauncher" -verify_arch x86_64 arm64
lipo "$DELIVERED_APP/Contents/Helpers/AnokhaJobRunner" -verify_arch x86_64 arm64
if [[ "$MODE" == "production" ]]; then
  xcrun stapler validate "$DELIVERED_APP"
  spctl --assess --type execute --verbose=4 "$DELIVERED_APP"
fi

echo "$ARCHIVE"
