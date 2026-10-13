#!/usr/bin/env bash
set -euo pipefail

validate_sparkle() {
  local app="$1" executable="$2"
  local framework="$app/Contents/Frameworks/Sparkle.framework"
  # Older releases do not link Sparkle. New builds must ship its full signed layout.
  if [[ ! -d "$framework" ]] && ! /usr/bin/otool -L "$app/Contents/MacOS/$executable" | /usr/bin/grep -F 'Sparkle.framework/' >/dev/null; then
    return 0
  fi
  local version_root="$framework/Versions/B" bundle helper executable_name
  [[ -f "$framework/Sparkle" && -f "$version_root/Autoupdate" ]] || {
    echo 'Missing embedded Sparkle framework or Autoupdate helper.' >&2; return 1;
  }
  codesign --verify --deep --strict "$framework"
  codesign --verify --strict "$version_root/Autoupdate"
  for bundle in "$version_root/Updater.app" "$version_root/XPCServices/Installer.xpc" "$version_root/XPCServices/Downloader.xpc"; do
    [[ -f "$bundle/Contents/Info.plist" ]] || {
      echo "Missing Sparkle helper bundle: $bundle" >&2; return 1;
    }
    executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"
    case "$executable_name" in
      ''|*/*|.|..) echo "Invalid Sparkle helper executable: $bundle" >&2; return 1 ;;
    esac
    helper="$bundle/Contents/MacOS/$executable_name"
    [[ -x "$helper" ]] || { echo "Missing Sparkle helper executable: $helper" >&2; return 1; }
    codesign --verify --deep --strict "$bundle"
  done
  echo 'Validated embedded Sparkle framework, updater and XPC helper signatures.'
}

validate_app() {
  local app="$1" widget="$1/Contents/PlugIns/CodexMeterWidget.appex"
  local app_plist="$app/Contents/Info.plist" widget_plist="$widget/Contents/Info.plist"
  [[ -d "$app" && -f "$app_plist" && -f "$widget_plist" ]] || {
    echo "Missing app bundle or WidgetKit extension: $app" >&2; return 1;
  }
  local executable version build minimum widget_executable widget_version widget_build
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_plist")"
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_plist")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_plist")"
  minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_plist")"
  widget_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$widget_plist")"
  widget_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$widget_plist")"
  widget_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$widget_plist")"
  [[ -x "$app/Contents/MacOS/$executable" && -x "$widget/Contents/MacOS/$widget_executable" ]] || {
    echo 'Missing bundle executable.' >&2; return 1;
  }
  [[ "$version" == "$widget_version" && "$build" == "$widget_build" ]] || {
    echo "App/widget version mismatch: $version ($build) / $widget_version ($widget_build)" >&2; return 1;
  }
  codesign --verify --deep --strict "$app"
  codesign --verify --strict "$widget"
  validate_sparkle "$app" "$executable"
  # Both bundles must resolve the same App Group after signing.
  local app_groups widget_groups configured_app_group configured_widget_group extension_point
  app_groups="$(codesign -d --entitlements :- "$app" 2>/dev/null | plutil -extract 'com\.apple\.security\.application-groups' json -o - -)"
  widget_groups="$(codesign -d --entitlements :- "$widget" 2>/dev/null | plutil -extract 'com\.apple\.security\.application-groups' json -o - -)"
  configured_app_group="$(/usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$app_plist")"
  configured_widget_group="$(/usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$widget_plist")"
  extension_point="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$widget_plist")"
  [[ "$app_groups" == "$widget_groups" && "$app_groups" != '[]' ]] || {
    echo 'App/widget App Group mismatch.' >&2; return 1;
  }
  [[ "$configured_app_group" == "$configured_widget_group" && "$app_groups" == "[\"$configured_app_group\"]" &&
      "$extension_point" == com.apple.widgetkit-extension ]] || {
    echo 'Runtime App Group configuration or WidgetKit extension point mismatch.' >&2; return 1;
  }
  echo "Validated Codex Health $version ($build), macOS $minimum+, app and WidgetKit signatures."
}

validate_dmg() {
  local dmg="$1" work mount
  [[ -f "$dmg" ]] || { echo "Missing DMG: $dmg" >&2; return 1; }
  hdiutil verify "$dmg"
  work="$(mktemp -d "${TMPDIR:-/tmp}/codexmeter-dmg-check.XXXXXX")"
  mount="$work/mount"
  mkdir "$mount"
  # Retain our scratch directory; only detach the read-only image on exit.
  trap 'hdiutil detach "$mount" >/dev/null 2>&1 || true' EXIT
  hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg" >/dev/null
  [[ -L "$mount/Applications" && "$(readlink "$mount/Applications")" == /Applications ]] || {
    echo 'DMG must include an Applications shortcut pointing to /Applications.' >&2; return 1;
  }
  validate_app "$mount/Codex Health.app"
  hdiutil detach "$mount" >/dev/null
  trap - EXIT
  echo "Validated drag-to-Applications DMG: $dmg"
}

case "${1:-}" in
  --app) [[ $# == 2 ]] && validate_app "$2" ;;
  --dmg) [[ $# == 2 ]] && validate_dmg "$2" ;;
  *) echo "usage: $0 --app APP_BUNDLE | --dmg DMG_PATH" >&2; exit 2 ;;
esac
