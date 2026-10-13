#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Each run owns a fresh output directory; existing releases are never replaced.
mkdir -p "$ROOT_DIR/dist"
DIST_DIR="${DIST_DIR:-$(mktemp -d "$ROOT_DIR/dist/release.XXXXXX")}"
if [[ -e "$DIST_DIR/Codex Health.app" || -L "$DIST_DIR/Codex Health.app" ]]; then
  echo "Refusing to replace an existing app in $DIST_DIR. Choose a fresh DIST_DIR." >&2
  exit 2
fi
mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
BUILD_DIR="${BUILD_DIR:-$DIST_DIR/build}"
SOURCE_PACKAGES_DIR="${SOURCE_PACKAGES_DIR:-$ROOT_DIR/output/macos/source-packages}"
mkdir -p "$SOURCE_PACKAGES_DIR"

APP_NAME="Codex Health"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
BUILT_APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
DMG_PATH="$DIST_DIR/CodexMeter-$VERSION-macos.dmg"
if [[ -e "$DMG_PATH" || -L "$DMG_PATH" || -e "$DMG_PATH.sha256" || -L "$DMG_PATH.sha256" || -e "$DIST_DIR/release-info.txt" || -L "$DIST_DIR/release-info.txt" ]]; then
  echo "Refusing to replace existing release outputs in $DIST_DIR." >&2
  exit 2
fi
SIGNING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexmeter-distribution.XXXXXX")"
IMAGE_ROOT="$SIGNING_DIR/image"
# Keep temporary signing/image inputs for inspection; cleanup requires confirmation.
echo "Packaging scratch: $SIGNING_DIR"

source "$ROOT_DIR/script/signing.sh"
codexmeter_select_signing

UPDATE_BUILD_ARGS=(-project "$ROOT_DIR/CodexMeter.xcodeproj")
if [[ -z "${UPDATE_XCCONFIG:-}" && -f "$ROOT_DIR/Resources/Updates.xcconfig" ]]; then
  UPDATE_XCCONFIG="$ROOT_DIR/Resources/Updates.xcconfig"
fi
if [[ -n "${UPDATE_XCCONFIG:-}" ]]; then
  [[ -f "$UPDATE_XCCONFIG" ]] || { echo "Missing UPDATE_XCCONFIG: $UPDATE_XCCONFIG" >&2; exit 1; }
  UPDATE_BUILD_ARGS+=(-xcconfig "$UPDATE_XCCONFIG")
fi

xcodebuild "${UPDATE_BUILD_ARGS[@]}" \
  -scheme CodexMeter \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
  build "${CODEX_XCODE_SIGNING_ARGS[@]}"

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
"$ROOT_DIR/script/validate_distribution.sh" --app "$APP_BUNDLE"

if [[ -n "${UPDATE_XCCONFIG:-}" || "${REQUIRE_APP_UPDATES:-0}" == "1" ]]; then
  python3 "$ROOT_DIR/script/validate_update_config.py" "$APP_BUNDLE"
fi

mkdir -p "$IMAGE_ROOT"
ditto "$APP_BUNDLE" "$IMAGE_ROOT/$APP_NAME.app"
ln -s /Applications "$IMAGE_ROOT/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$IMAGE_ROOT" \
  -format UDZO \
  "$DMG_PATH"

"$ROOT_DIR/script/validate_distribution.sh" --dmg "$DMG_PATH"
(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256"
  shasum -a 256 -c "$(basename "$DMG_PATH").sha256"
)
{
  echo "Codex Health $VERSION"
  echo "Signing mode: $CODEX_SIGNING_MODE"
  echo "DMG: $(basename "$DMG_PATH")"
  echo "Commit: $(git -C "$ROOT_DIR" rev-parse --short HEAD)"
  echo "Working tree: $(git -C "$ROOT_DIR" status --porcelain --untracked-files=no | wc -l | tr -d ' ') changed tracked files"
  echo "Built at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Validation: app/widget versions, executable files, signatures, App Groups, DMG integrity and Applications shortcut"
} > "$DIST_DIR/release-info.txt"
echo "Built and validated $DMG_PATH"
echo "SHA-256: $DMG_PATH.sha256"
echo "Build and scratch artifacts are retained. No installed app was changed."
