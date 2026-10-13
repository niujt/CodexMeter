#!/usr/bin/env bash
# Build ONLY a disposable ad-hoc candidate; do not install or migrate user data.
set -euo pipefail
[[ "$#" -eq 1 && "$(uname -s)" == Darwin ]] || { echo 'Requires macOS and one new absolute output directory.' >&2; exit 2; }
ROOT="$1"
[[ "$ROOT" == /* && ! -e "$ROOT" ]] || { echo 'Output must be a new absolute directory; no existing files will be removed.' >&2; exit 1; }
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/output" "$ROOT/image" "$ROOT/mounted"

xcodebuild -project "$PROJECT/CodexMeter.xcodeproj" -scheme CodexMeter \
  -configuration Release -destination 'generic/platform=macOS' \
  -xcconfig "$PROJECT/Resources/Updates.xcconfig" \
  -derivedDataPath "$ROOT/derived-data" -clonedSourcePackagesDirPath "$ROOT/packages" \
  -archivePath "$ROOT/CodexHealth.xcarchive" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
  archive

APP="$ROOT/image/Codex Health.app"
ditto "$ROOT/CodexHealth.xcarchive/Products/Applications/Codex Health.app" "$APP"
python3 "$PROJECT/script/validate_update_config.py" "$APP"
python3 - "$PROJECT" "$ROOT" "$APP" <<'PY'
import json, plistlib, re, sys
from pathlib import Path
project, root, app = map(Path, sys.argv[1:])
def read(path):
    return plistlib.loads(path.read_bytes())
info = read(app / 'Contents/Info.plist')
widget = read(app / 'Contents/PlugIns/CodexMeterWidget.appex/Contents/Info.plist')
key = 'txWavHI0vv7xM5j0CrtW8pkoRWmChw8hHjUxa1BL1So='
assert info['SUPublicEDKey'] == key, 'Unexpected public update key'
version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version), 'Invalid version'
assert build.isascii() and build.isdigit() and int(build) > 16, 'Increment build past the pre-updater version'
for field in ('CFBundleVersion', 'CFBundleShortVersionString', 'AppGroupIdentifier'):
    assert widget[field] == info[field], f'App/Widget {field} differ'
assert info['AppGroupIdentifier'] == 'com.codexmeter.CodexMeter', 'Ad-hoc App Group must have no Team prefix'
for source, destination in [('CodexMeter.entitlements', 'app.entitlements'), ('CodexMeterWidget.entitlements', 'widget.entitlements')]:
    # Resolve the existing local ad-hoc path; do not add/remove capabilities.
    data = (project / 'Resources' / source).read_bytes().replace(b'$(TeamIdentifierPrefix)', b'')
    entitlements = plistlib.loads(data)
    assert entitlements['com.apple.security.application-groups'] == [info['AppGroupIdentifier']]
    assert not entitlements.get('com.apple.security.cs.disable-library-validation', False)
    (root / destination).write_bytes(data)
assert read(root / 'widget.entitlements')['com.apple.security.app-sandbox'] is True
sparkle = app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist'
assert read(sparkle)['CFBundleShortVersionString'] == '2.10.0'
name = f'CodexMeter-{version}-macos-CANDIDATE-ADHOC.dmg'
(root / 'metadata.json').write_text(json.dumps(dict(version=version, build=build, archive=name,
    public_key=key, url=f'https://github.com/niujt/CodexMeter/releases/download/v{version}/{name}')))
PY

FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE="$FRAMEWORK/Versions/B"
WIDGET="$APP/Contents/PlugIns/CodexMeterWidget.appex"
# Preserve Sparkle's existing entitlements and runtime flags. Sign from inside
# out; --deep is used ONLY for verification, never to sign nested code.
for nested in "$SPARKLE/XPCServices/Downloader.xpc" "$SPARKLE/XPCServices/Installer.xpc" \
  "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$FRAMEWORK"; do
  codesign --force --sign - --preserve-metadata=identifier,entitlements,flags "$nested"
done
codesign --force --sign - --entitlements "$ROOT/widget.entitlements" "$WIDGET"
codesign --force --sign - --entitlements "$ROOT/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

for pair in app widget; do
  bundle="$APP"
  [[ "$pair" != widget ]] || bundle="$WIDGET"
  codesign --display --entitlements - "$bundle" > "$ROOT/$pair.signed-entitlements.plist"
  codesign --display --verbose=4 "$bundle" 2> "$ROOT/$pair.signature.txt"
  grep -F 'Signature=adhoc' "$ROOT/$pair.signature.txt" > /dev/null
done
python3 - "$ROOT" <<'PY'
import plistlib, sys
from pathlib import Path
root = Path(sys.argv[1])
for target in ('app', 'widget'):
    expected = plistlib.loads((root / f'{target}.entitlements').read_bytes())
    actual = plistlib.loads((root / f'{target}.signed-entitlements.plist').read_bytes())
    assert actual == expected, f'{target} signed entitlements differ from reviewed entitlements'
PY
for binary in "$APP/Contents/MacOS/CodexMeter" "$WIDGET/Contents/MacOS/CodexMeterWidget" \
  "$SPARKLE/Sparkle" "$SPARKLE/Autoupdate"; do
  xcrun lipo "$binary" -verify_arch arm64 x86_64
done
for bundle in "$SPARKLE/Updater.app" "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/XPCServices/Downloader.xpc"; do
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"
  [[ -n "$executable" && "$executable" != */* && "$executable" != . && "$executable" != .. ]]
  xcrun lipo "$bundle/Contents/MacOS/$executable" -verify_arch arm64 x86_64
done
for architecture in arm64 x86_64; do
  xcrun otool -arch "$architecture" -L "$APP/Contents/MacOS/CodexMeter" \
    | grep -F '@rpath/Sparkle.framework/Versions/B/Sparkle' > /dev/null
done

ln -s /Applications "$ROOT/image/Applications"
DMG_NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive"])' "$ROOT/metadata.json")"
hdiutil create -volname 'Codex Health TEST CANDIDATE' -srcfolder "$ROOT/image" -format UDZO "$ROOT/output/$DMG_NAME"
hdiutil verify "$ROOT/output/$DMG_NAME"
hdiutil attach -readonly -nobrowse -mountpoint "$ROOT/mounted" "$ROOT/output/$DMG_NAME"
trap 'hdiutil detach "$ROOT/mounted" >/dev/null' EXIT
test -d "$ROOT/mounted/Codex Health.app"
test "$(readlink "$ROOT/mounted/Applications")" = /Applications
codesign --verify --deep --strict "$ROOT/mounted/Codex Health.app"
hdiutil detach "$ROOT/mounted"
trap - EXIT
echo 'PASS: universal ad-hoc candidate, matching App Groups, nested signatures and DMG layout'
echo 'NOT PROVEN: Gatekeeper acceptance, Widget registration, data migration, install or restart'
