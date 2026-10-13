#!/usr/bin/env bash
# Structural checks only for the deliberately unconfigured, unsigned CI archive.
# This script does not launch/install the app, read credentials or relax security.
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: bash script/ci_validate_macos_bundle.sh /path/to/Codex\\ Health.app" >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo "macOS with Xcode is required to inspect Mach-O architectures and linkage." >&2
  exit 1
fi

APP="$1"
WIDGET="$APP/Contents/PlugIns/CodexMeterWidget.appex"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"

python3 - "$APP" <<'PY'
import plistlib
import sys
from pathlib import Path

app = Path(sys.argv[1])

def read_info(path):
    with path.open("rb") as source:
        return plistlib.load(source)

def require(condition, message):
    if not condition:
        raise SystemExit(message)

info = read_info(app / "Contents/Info.plist")
widget = read_info(app / "Contents/PlugIns/CodexMeterWidget.appex/Contents/Info.plist")
sparkle = read_info(app / "Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist")

require(info.get("CFBundleIdentifier") == "com.codexmeter.CodexMeter", "Unexpected app identifier")
require(widget.get("CFBundleIdentifier") == "com.codexmeter.CodexMeter.WidgetV4", "Unexpected Widget identifier")
require(info.get("CFBundleExecutable") == "CodexMeter", "Unexpected app executable")
require(widget.get("CFBundleExecutable") == "CodexMeterWidget", "Unexpected Widget executable")
for field in ("CFBundleVersion", "CFBundleShortVersionString"):
    value = info.get(field)
    require(isinstance(value, str) and bool(value), f"Missing app {field}")
    require(widget.get(field) == value, f"App and Widget {field} differ")
build = info["CFBundleVersion"]
require(build.isascii() and build.isdigit() and int(build) > 0, "Invalid app build number")
require(info.get("LSMinimumSystemVersion") == "15.0", "Unexpected minimum macOS version")
require(sparkle.get("CFBundleShortVersionString") == "2.10.0", "Expected embedded Sparkle 2.10.0")

# The secret-free workflow must stay genuinely unconfigured, with no fake public
# key and no real feed contact. Do not run the production configuration gate here.
for field in ("SUFeedURL", "SUPublicEDKey"):
    require(info.get(field, "") == "", f"Unsigned CI must have an empty {field}")
for field in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
    require(info.get(field) is True, f"{field} must stay enabled")
expiration = info.get("SUSignedFeedFailureExpirationInterval")
require(type(expiration) is int and expiration == 0, "Signed-feed fallback must remain disabled")
for field in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUEnableSystemProfiling"):
    require(info.get(field) is False, f"{field} must stay disabled")
print("PASS: matching app/Widget versions, Sparkle 2.10.0 and fail-closed updater policy")
PY

# Validate every shipped code component, not just the outer framework. Preserve
# the framework's versioned symlinks; no copying or re-signing is done here.
BINARIES=(
  "$APP/Contents/MacOS/CodexMeter"
  "$WIDGET/Contents/MacOS/CodexMeterWidget"
  "$SPARKLE/Sparkle"
  "$SPARKLE/Autoupdate"
)
for bundle in \
  "$SPARKLE/Updater.app" \
  "$SPARKLE/XPCServices/Installer.xpc" \
  "$SPARKLE/XPCServices/Downloader.xpc"; do
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"
  case "$executable" in
    ''|*/*|.|..) echo "Invalid executable name in $bundle" >&2; exit 1 ;;
  esac
  BINARIES+=("$bundle/Contents/MacOS/$executable")
done
test -f "$APP/Contents/Frameworks/Sparkle.framework/Sparkle"
for binary in "${BINARIES[@]}"; do
  test -f "$binary"
  xcrun lipo -verify_arch arm64 x86_64 "$binary"
done

# Check both slices link to the embedded framework through a bundle-relative path.
for architecture in arm64 x86_64; do
  xcrun otool -arch "$architecture" -L "$APP/Contents/MacOS/CodexMeter" \
    | grep -F '@rpath/Sparkle.framework/Versions/B/Sparkle' > /dev/null
done
echo "PASS: app, Widget and Sparkle helpers contain arm64/x86_64; app links embedded Sparkle"
echo "NOT CHECKED: code-signing trust, notarization, live feed, UI, installation or restart"
