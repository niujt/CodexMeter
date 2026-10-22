#!/usr/bin/env python3
"""Run in trusted CI: reuse a secret without writing/exporting any private material."""
import argparse
import base64
import binascii
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime

FEED = 'https://raw.githubusercontent.com/niujt/CodexMeter/main/updates/macos/appcast.xml'


def retain_latest_updates(feed, limit=2):
    """Prune only the staged feed, before signing; published feeds stay valid until replaced."""
    sparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
    tree = ET.fromstring(feed.read_bytes())
    channel = tree.find('channel')
    if channel is None:
        raise SystemExit('Published feed has no channel.')
    items = channel.findall('item')
    builds = [item.findtext(f'{{{sparkle}}}version') for item in items]
    if (any(not build or not build.isdecimal() or int(build) <= 0 for build in builds)
            or len(set(builds)) != len(builds)):
        raise SystemExit('Published feed has invalid or duplicate builds.')
    if len(items) <= limit:
        return
    retained = set(sorted(items, key=lambda item: int(item.findtext(f'{{{sparkle}}}version')), reverse=True)[:limit])
    for item in items:
        if item not in retained:
            channel.remove(item)
    ET.register_namespace('sparkle', sparkle)
    ET.indent(tree)
    feed.write_bytes(ET.tostring(tree, encoding='utf-8', xml_declaration=True) + b'\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--public-key-tool', required=True)
    parser.add_argument('--sign-tool', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--package', type=Path)
    parser.add_argument('--release-tag')
    parser.add_argument('--version')
    parser.add_argument('--build', type=int)
    parser.add_argument('--expected-sha256')
    parser.add_argument('--release-notes', type=Path)
    args = parser.parse_args()
    package_metadata = None
    if args.package:
        notes = (args.release_notes.read_text(encoding='utf-8').strip() if args.release_notes
                 else f'Codex Health {args.version} macOS update. Apple Development signed; not notarized.')
        if not notes or len(notes) > 10_000:
            raise SystemExit('Release notes must contain between 1 and 10000 characters.')
        if (not args.version or not re.fullmatch(r'\d+\.\d+\.\d+', args.version)
                or args.release_tag != 'macos-v' + args.version or not args.build or args.build <= 0
                or args.package.name != f'CodexMeter-{args.version}-macos.dmg'
                or not re.fullmatch(r'[0-9a-f]{64}', args.expected_sha256 or '')):
            raise SystemExit('Invalid release package metadata.')
        package_digest = hashlib.sha256(args.package.read_bytes()).hexdigest()
        if package_digest != args.expected_sha256:
            raise SystemExit('Release package SHA-256 mismatch.')
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
    if args.package:
        configured = Path('Resources/Updates.xcconfig').read_text(encoding='utf-8')
        expected_key = re.search(r'^CODEX_HEALTH_UPDATE_PUBLIC_KEY\s*=\s*(\S+)', configured, re.MULTILINE)
        if not expected_key or expected_key.group(1) != public_key:
            raise SystemExit('Existing Secret does not match the published app public key; refusing a trust change.')
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
    def invoke(path, verify=False, signature=None):
        command = [args.sign_tool, '--ed-key-file', '-']
        if verify:
            command.append('--verify')
        return subprocess.run(command + [str(path)] + ([signature] if signature else []), input=key_input, env=child_env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    if args.package:
        signed_package = invoke(args.package)
        signature = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', signed_package.stdout.decode('utf-8', errors='replace'))
        length = re.search(r'length="(\d+)"', signed_package.stdout.decode('utf-8', errors='replace'))
        if (signed_package.returncode or not signature or not length
                or int(length.group(1)) != args.package.stat().st_size
                or invoke(args.package, verify=True, signature=signature.group(1)).returncode):
            raise SystemExit('Official Sparkle package signing/verification failed.')
        tampered_package = args.output.parent / (args.output.name + '-tampered.dmg')
        payload = args.package.read_bytes()
        tampered_package.write_bytes(bytes([payload[0] ^ 1]) + payload[1:])
        if invoke(tampered_package, verify=True, signature=signature.group(1)).returncode == 0:
            raise SystemExit('Tampered package was unexpectedly accepted.')
        sparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
        ET.register_namespace('sparkle', sparkle)
        tree = ET.fromstring(feed.read_bytes())
        channel = tree.find('channel')
        if channel is None:
            raise SystemExit('Published feed has no channel.')
        for existing in channel.findall('item'):
            version = existing.findtext(f'{{{sparkle}}}version')
            if not version or not version.isdecimal() or int(version) >= args.build:
                raise SystemExit('Release build must increase monotonically; existing builds are immutable.')
        item = ET.Element('item')
        ET.SubElement(item, 'title').text = f'Codex Health {args.version}'
        ET.SubElement(item, f'{{{sparkle}}}version').text = str(args.build)
        ET.SubElement(item, f'{{{sparkle}}}shortVersionString').text = args.version
        ET.SubElement(item, f'{{{sparkle}}}minimumSystemVersion').text = '15.0.0'
        ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
        ET.SubElement(item, 'description').text = notes
        download_url = f'https://github.com/niujt/CodexMeter/releases/download/{args.release_tag}/{args.package.name}'
        ET.SubElement(item, 'enclosure', {'url': download_url, 'length': length.group(1),
            'type': 'application/octet-stream', f'{{{sparkle}}}edSignature': signature.group(1)})
        channel.insert(0, item)
        channel.find('description').text = 'Codex Health signed macOS updates.'
        ET.indent(tree)
        feed.write_bytes(ET.tostring(tree, encoding='utf-8', xml_declaration=True) + b'\n')
        package_metadata = {'file': args.package.name, 'version': args.version, 'build': args.build,
            'url': download_url, 'sha256': package_digest, 'length': int(length.group(1)),
            'edSignature': signature.group(1), 'packageVerified': True, 'packageTamperingRejected': True}
        (args.output / (args.package.name + '.sig')).write_text(signature.group(1) + '\n', encoding='ascii')

    retain_latest_updates(feed)
    update_count = len(ET.fromstring(feed.read_bytes()).findall('./channel/item'))

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
        'package': package_metadata,
    }, indent=2) + '\n', encoding='utf-8')
    print('Existing Secret reused; public configuration and signed feed verified; tampering rejected.')


if __name__ == '__main__':
    main()
