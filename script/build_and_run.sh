#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
TARGET_NAME="CodexMeter"
APP_NAME="Codex Health"
EXECUTABLE_NAME="CodexMeter"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build"
BUILT_APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"

# When launching from Xcode, the debugger owns the process. Avoid terminating it
# here; quitting the existing menu-bar instance before running is sufficient.
xcodebuild \
  -project "$ROOT_DIR/CodexMeter.xcodeproj" \
  -scheme "$TARGET_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  build CODE_SIGNING_ALLOWED=NO

codesign --force --sign - "$BUILT_APP/Contents/MacOS/$EXECUTABLE_NAME"
codesign --force --deep --sign - "$BUILT_APP"

rm -rf "$APP_BUNDLE"
mkdir -p "$ROOT_DIR/dist"
ditto "$BUILT_APP" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem CONTAINS \"CodexMeter\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$EXECUTABLE_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
