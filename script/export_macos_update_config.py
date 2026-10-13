#!/usr/bin/env python3
"""Run in trusted CI: reuse a secret without writing/exporting any private material."""
import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

FEED = 'https://raw.githubusercontent.com/niujt/CodexMeter/main/updates/macos/appcast.xml'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--public-key-tool', required=True)
    parser.add_argument('--sign-tool', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    encoded = os.environ.pop('SPARKLE_PRIVATE_KEY', '').strip()
    try:
        secret = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise SystemExit('SPARKLE_PRIVATE_KEY is not a Sparkle exported key.')
    if len(secret) not in (32, 96) or not any(secret):
        raise SystemExit('SPARKLE_PRIVATE_KEY must be a 32-byte seed or a 96-byte legacy Sparkle export.')
    # Child processes receive the key only on stdin, never through argv, environment or disk.
    child_env = dict(os.environ)
    key_input = (encoded + '\n').encode('ascii')
    public = subprocess.run([args.public_key_tool], input=key_input, env=child_env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if public.returncode:
        raise SystemExit('The public key could not be derived from the existing Secret.')
    public_key = public.stdout.decode('ascii').strip()
    try:
        decoded_public = base64.b64decode(public_key, validate=True)
    except (ValueError, binascii.Error):
        raise SystemExit('Public key tool returned invalid data.')
    if len(decoded_public) != 32 or not any(decoded_public):
        raise SystemExit('Public key tool returned an invalid Ed25519 public key.')
    args.output.mkdir(parents=True, exist_ok=False)
    feed = args.output / 'appcast.xml'
    # Re-exporting configuration must preserve any already published update items.
    template = Path('updates/macos/appcast.xml')
    if template.is_file():
        feed.write_bytes(template.read_bytes())
    else:
        # A bootstrap feed advertises no unreleased installation packages.
        feed.write_text('<?xml version="1.0" encoding="utf-8"?>\n'
                    '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
                    '  <channel>\n    <title>Codex Health macOS</title>\n'
                    '    <link>https://github.com/niujt/CodexMeter</link>\n'
                    '    <description>Signed macOS update feed. No newer package is published yet.</description>\n'
                        '    <language>zh-cn</language>\n  </channel>\n</rss>\n', encoding='utf-8')
    update_count = len(ET.fromstring(feed.read_bytes()).findall('./channel/item'))

    def invoke(path, verify=False):
        command = [args.sign_tool, '--ed-key-file', '-']
        if verify:
            command.append('--verify')
        return subprocess.run(command + [str(path)], input=key_input, env=child_env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    if invoke(feed).returncode or invoke(feed, verify=True).returncode:
        raise SystemExit('Official Sparkle feed signing/verification failed; no public configuration is usable.')
    tampered = args.output.parent / (args.output.name + '-tampered.xml')
    signed = feed.read_bytes()
    modified = signed.replace(b'Codex Health macOS', b'Codex Xealth macOS', 1)
    if modified == signed:
        raise SystemExit('Could not construct the tampering test.')
    tampered.write_bytes(modified)
    if invoke(tampered, verify=True).returncode == 0:
        raise SystemExit('Tampered feed was unexpectedly accepted.')
    (args.output / 'public-key.txt').write_text(public_key + '\n', encoding='ascii')
    (args.output / 'Updates.xcconfig').write_text(
        '// Public configuration only; private signing material stays in GitHub Actions.\n'
        'CODEX_HEALTH_UPDATE_FEED_URL = https:/$()/raw.githubusercontent.com/niujt/CodexMeter/main/updates/macos/appcast.xml\n'
        'CODEX_HEALTH_UPDATE_PUBLIC_KEY = ' + public_key + '\n', encoding='utf-8')
    (args.output / 'verification.json').write_text(json.dumps({
        'feedURL': FEED, 'publicKey': public_key, 'signingToolVersion': '2.10.0',
        'feedVerified': True, 'tamperingRejected': True, 'publishedUpdateCount': update_count,
        'appcastSHA256': hashlib.sha256(signed).hexdigest(),
    }, indent=2) + '\n', encoding='utf-8')
    print('Existing Secret reused; public configuration and signed feed verified; tampering rejected.')


if __name__ == '__main__':
    main()
