#!/usr/bin/env python3
"""Integration checks with a synthetic seed and the pinned official signing tool.

Fixtures are retained; this script never reads a real release signing key.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--public-key-tool', required=True)
    parser.add_argument('--sign-tool', required=True)
    args = parser.parse_args()
    export = Path(__file__).with_name('export_macos_update_config.py').resolve()
    root = Path(tempfile.mkdtemp(prefix='codex-health-release-export-fixtures-'))
    env = dict(os.environ)
    env['SPARKLE_PRIVATE_KEY'] = base64.b64encode(bytes([1]) * 32).decode()
    public = subprocess.check_output([args.public_key_tool], input=(env['SPARKLE_PRIVATE_KEY'] + '\n').encode()).decode().strip()
    (root / 'Resources').mkdir()
    config = root / 'Resources/Updates.xcconfig'
    config.write_text('CODEX_HEALTH_UPDATE_PUBLIC_KEY = ' + public + '\n')
    package = root / 'CodexMeter-1.0.9-macos.dmg'
    package.write_bytes(b'Synthetic archive bytes, not an installable package.\n')
    digest = hashlib.sha256(package.read_bytes()).hexdigest()

    def invoke(name, expected_digest=digest, build='18'):
        result = subprocess.run(['python3', str(export), '--public-key-tool', args.public_key_tool,
            '--sign-tool', args.sign_tool, '--output', str(root / name), '--package', str(package),
            '--release-tag', 'macos-v1.0.9', '--version', '1.0.9', '--build', build,
            '--expected-sha256', expected_digest], cwd=root, env=env, capture_output=True)
        # Never forward tool stdout/stderr; assert only safe outcomes.
        return result.returncode

    assert invoke('first') == 0, 'Synthetic package/feed signing failed'
    verification = json.loads((root / 'first/verification.json').read_text())
    assert verification['feedVerified'] and verification['tamperingRejected']
    assert verification['package']['packageVerified'] and verification['package']['packageTamperingRejected']
    assert verification['package']['sha256'] == digest
    assert verification['publishedUpdateCount'] == 1
    sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    item = ET.parse(root / 'first/appcast.xml').find('./channel/item')
    assert item.findtext(sparkle + 'version') == '18'
    assert item.find('enclosure').get('url').endswith('/macos-v1.0.9/CodexMeter-1.0.9-macos.dmg')
    assert invoke('bad-digest', expected_digest='0' * 64) != 0, 'Incorrect digest accepted'
    assert not (root / 'bad-digest').exists()
    config.write_text('CODEX_HEALTH_UPDATE_PUBLIC_KEY = ' + base64.b64encode(bytes([2]) * 32).decode() + '\n')
    assert invoke('wrong-trust') != 0, 'Public key change accepted'
    assert not (root / 'wrong-trust').exists()
    config.write_text('CODEX_HEALTH_UPDATE_PUBLIC_KEY = ' + public + '\n')
    (root / 'updates/macos').mkdir(parents=True)
    (root / 'updates/macos/appcast.xml').write_bytes((root / 'first/appcast.xml').read_bytes())
    assert invoke('duplicate-build') != 0, 'Duplicate published build accepted'
    assert invoke('next', build='19') == 0, 'Next build could not preserve the previous item'
    assert json.loads((root / 'next/verification.json').read_text())['publishedUpdateCount'] == 2
    print('PASS: synthetic package/feed signatures, tampering rejection, digest and trust guards, monotonic builds and existing-item preservation.')
    print('Retained synthetic fixtures:', root)


if __name__ == '__main__':
    main()
