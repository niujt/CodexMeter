#!/usr/bin/env python3
"""Validate public updater configuration in a built app without accessing Keychain."""
import base64
import binascii
import plistlib
import sys
from pathlib import Path

FEED = "https://raw.githubusercontent.com/niujt/CodexMeter/main/updates/macos/appcast.xml"


def validate(info):
    errors = []
    feed = info.get("SUFeedURL", "")
    if feed != FEED:
        errors.append("SUFeedURL must be the approved HTTPS macOS appcast URL")
    try:
        key = base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)
        if len(key) != 32 or not any(key):
            raise ValueError("not a public Ed25519 key")
    except (ValueError, TypeError, binascii.Error):
        errors.append("SUPublicEDKey must contain the real 32-byte public Ed25519 key")
    for setting in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
        if info.get(setting) is not True:
            errors.append(f"{setting} must be enabled")
    if info.get("SUSignedFeedFailureExpirationInterval") != 0:
        errors.append("SUSignedFeedFailureExpirationInterval must be zero (never bypass feed signature failures)")
    version = info.get("CFBundleVersion", "")
    if not isinstance(version, str) or not version.isdigit() or int(version) <= 0:
        errors.append("CFBundleVersion must be a positive increasing build number")
    return errors


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: python3 script/validate_update_config.py /path/to/Codex\\ Health.app")
    app = Path(sys.argv[1])
    with (app / "Contents/Info.plist").open("rb") as handle:
        errors = validate(plistlib.load(handle))
    if not (app / "Contents/Frameworks/Sparkle.framework/Sparkle").is_file():
        errors.append("Sparkle.framework is not embedded in the built app")
    if errors:
        raise SystemExit("Update configuration incomplete:\n- " + "\n- ".join(errors))
    print("PASS: updater public configuration and embedded framework. Signatures and the live feed still require verification on macOS.")


if __name__ == "__main__":
    main()
