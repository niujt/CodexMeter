#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--build-only) ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--build-only]" >&2; exit 2 ;;
esac
TARGET_NAME="CodexMeter"
APP_NAME="Codex Health"
EXECUTABLE_NAME="CodexMeter"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT_DIR/dist"
OUTPUT_DIR="${OUTPUT_DIR:-$(mktemp -d "$ROOT_DIR/dist/debug.XXXXXX")}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
DERIVED_DATA="${BUILD_DIR:-$OUTPUT_DIR/build}"
SOURCE_PACKAGES_DIR="${SOURCE_PACKAGES_DIR:-$ROOT_DIR/output/macos/source-packages}"
mkdir -p "$SOURCE_PACKAGES_DIR"
BUILT_APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
  echo "Refusing to replace $APP_BUNDLE. Choose a fresh OUTPUT_DIR." >&2
  exit 2
fi
SIGNING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexmeter-signing.XXXXXX")"
echo "Signing scratch retained: $SIGNING_DIR"

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

# When launching from Xcode, the debugger owns the process. Avoid terminating it
# here; quitting the existing menu-bar instance before running is sufficient.
xcodebuild "${UPDATE_BUILD_ARGS[@]}" \
  -scheme "$TARGET_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
  build "${CODEX_XCODE_SIGNING_ARGS[@]}"

WIDGET_BUNDLE="$BUILT_APP/Contents/PlugIns/CodexMeterWidget.appex"
if [[ "$CODEX_SIGNING_MODE" == "adhoc" ]]; then
  sed 's/\$(TeamIdentifierPrefix)//g' \
    "$ROOT_DIR/Resources/CodexMeter.entitlements" > "$SIGNING_DIR/app.entitlements"
  sed 's/\$(TeamIdentifierPrefix)//g' \
    "$ROOT_DIR/Resources/CodexMeterWidget.entitlements" > "$SIGNING_DIR/widget.entitlements"

  codesign --force --deep --sign - --entitlements "$SIGNING_DIR/app.entitlements" "$BUILT_APP"
  if [[ -d "$WIDGET_BUNDLE" ]]; then
    codesign --force --deep --sign - --entitlements "$SIGNING_DIR/widget.entitlements" "$WIDGET_BUNDLE"
  fi
  codesign --force --sign - --entitlements "$SIGNING_DIR/app.entitlements" "$BUILT_APP"
fi
codesign --verify --deep --strict "$BUILT_APP"

ditto "$BUILT_APP" "$APP_BUNDLE"
"$ROOT_DIR/script/validate_distribution.sh" --app "$APP_BUNDLE"
if [[ -n "${UPDATE_XCCONFIG:-}" || "${REQUIRE_APP_UPDATES:-0}" == "1" ]]; then
  python3 "$ROOT_DIR/script/validate_update_config.py" "$APP_BUNDLE"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

stop_existing_instances() {
  local pids
  pids="$(pgrep -f '/Codex Health\.app/Contents/MacOS/CodexMeter' || true)"
  if [[ -z "$pids" ]]; then
    return
  fi

  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill "$pid" 2>/dev/null || true
  done <<< "$pids"
  sleep 1
}

case "$MODE" in
  --build-only) echo "Built and validated $APP_BUNDLE" ;;
  run) stop_existing_instances; open_app ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" ;;
  --logs|logs)
    stop_existing_instances
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
    ;;
  --telemetry|telemetry)
    stop_existing_instances
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem CONTAINS \"CodexMeter\""
    ;;
  --verify|verify)
    stop_existing_instances
    open_app
    sleep 1
    pgrep -x "$EXECUTABLE_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
