#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build-release}"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Codex Health"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
BUILT_APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
DMG_PATH="$DIST_DIR/CodexMeter-$VERSION-macos.dmg"
SIGNING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexmeter-distribution.XXXXXX")"
IMAGE_ROOT="$SIGNING_DIR/image"
trap 'rm -rf "$SIGNING_DIR"' EXIT

source "$ROOT_DIR/script/signing.sh"
codexmeter_select_signing

UPDATE_BUILD_ARGS=(-project "$ROOT_DIR/CodexMeter.xcodeproj")
if [[ -n "${UPDATE_XCCONFIG:-}" ]]; then
  [[ -f "$UPDATE_XCCONFIG" ]] || { echo "Missing UPDATE_XCCONFIG: $UPDATE_XCCONFIG" >&2; exit 1; }
  UPDATE_BUILD_ARGS+=(-xcconfig "$UPDATE_XCCONFIG")
fi

xcodebuild "${UPDATE_BUILD_ARGS[@]}" \
  -scheme CodexMeter \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  build "${CODEX_XCODE_SIGNING_ARGS[@]}"

rm -rf "$APP_BUNDLE"
mkdir -p "$DIST_DIR"
ditto "$BUILT_APP" "$APP_BUNDLE"

WIDGET_BUNDLE="$APP_BUNDLE/Contents/PlugIns/CodexMeterWidget.appex"
if [[ "$CODEX_SIGNING_MODE" == "adhoc" ]]; then
  # Resolve the group identifier for an ad-hoc local build. A signed build with
  # a development team uses Xcode's expanded entitlements instead.
  sed 's/\$(TeamIdentifierPrefix)//g' \
    "$ROOT_DIR/Resources/CodexMeter.entitlements" > "$SIGNING_DIR/app.entitlements"
  sed 's/\$(TeamIdentifierPrefix)//g' \
    "$ROOT_DIR/Resources/CodexMeterWidget.entitlements" > "$SIGNING_DIR/widget.entitlements"

  codesign --force --deep --sign - --entitlements "$SIGNING_DIR/app.entitlements" "$APP_BUNDLE"
  codesign --force --deep --sign - --entitlements "$SIGNING_DIR/widget.entitlements" "$WIDGET_BUNDLE"
  codesign --force --sign - --entitlements "$SIGNING_DIR/app.entitlements" "$APP_BUNDLE"
fi
codesign --verify --deep --strict "$APP_BUNDLE"

if [[ "${REQUIRE_APP_UPDATES:-0}" == "1" ]]; then
  python3 "$ROOT_DIR/script/validate_update_config.py" "$APP_BUNDLE"
fi

mkdir -p "$IMAGE_ROOT"
ditto "$APP_BUNDLE" "$IMAGE_ROOT/$APP_NAME.app"
ln -s /Applications "$IMAGE_ROOT/Applications"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$IMAGE_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Built $DMG_PATH"
