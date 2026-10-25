#!/usr/bin/env python3
"""Reject Widget archives whose version differs from macOS extension registration."""
import plistlib
import re
import sys
from pathlib import Path


def validate(app, widget):
    errors = []
    version = app.get("CFBundleShortVersionString")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        errors.append("App version must contain major, minor and patch numbers")
    if widget.get("CFBundleShortVersionString") != version:
        errors.append("App and Widget marketing versions must match")
    # LSPlugInKitProxy exposes the extension's short version as bundleVersion.
    # WidgetKit rejects an archive with a different CFBundleVersion even when
    # the extension generated its timeline successfully.
    if widget.get("CFBundleVersion") != version:
        errors.append("Widget CFBundleVersion must match its registered short version")
    build = app.get("CFBundleVersion")
    if not isinstance(build, str) or not build.isascii() or not build.isdigit() or int(build) <= 0:
        errors.append("App update build must remain a positive integer")
    return errors


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate_widget_version.py APP_BUNDLE")
    app = Path(sys.argv[1])
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    with (app / "Contents/PlugIns/CodexMeterWidget.appex/Contents/Info.plist").open("rb") as source:
        widget = plistlib.load(source)
    errors = validate(info, widget)
    if errors:
        raise SystemExit("Widget version validation failed:\n- " + "\n- ".join(errors))
    print(f"PASS: Widget archive/registration version {widget['CFBundleVersion']}; app update build {info['CFBundleVersion']}")


if __name__ == "__main__":
    main()
