#!/usr/bin/env python3
"""Verify application PE architectures and collect two NSIS installers."""
from pathlib import Path
import hashlib
import json
import shutil
import struct

ROOT = Path(__file__).resolve().parent
VERSION = json.loads((ROOT / 'src-tauri/tauri.conf.json').read_text())['version']
DEST = ROOT.parent / 'output' / 'windows' / VERSION
TARGETS = [('x64', 'x86_64-pc-windows-msvc', 0x8664),
           ('arm64', 'aarch64-pc-windows-msvc', 0xaa64)]

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def machine(path):
    with path.open('rb') as f:
        assert f.read(2) == b'MZ', 'Missing DOS header'
        f.seek(0x3c)
        offset = struct.unpack('<I', f.read(4))[0]
        f.seek(offset)
        assert f.read(4) == b'PE\0\0', 'Missing PE header'
        return struct.unpack('<H', f.read(2))[0]

entries = []
for arch, target, expected in TARGETS:
    release = ROOT / 'src-tauri/target' / target / 'release'
    app = release / 'codex-health-windows.exe'
    assert machine(app) == expected, f'{arch} executable has wrong architecture'
    installers = list((release / 'bundle/nsis').glob(f'*{VERSION}*-setup.exe'))
    assert len(installers) == 1, f'Expected one {arch} installer, found {len(installers)}'
    installer = installers[0]
    assert machine(installer) in (0x14c, expected), 'Unexpected NSIS stub architecture'
    DEST.mkdir(parents=True, exist_ok=True)
    package = DEST / f'Codex-Health-{VERSION}-windows-{arch}-setup.exe'
    shutil.copy2(installer, package)
    assert digest(package) == digest(installer), 'Copy verification failed'
    entries.append({'architecture': arch, 'target': target, 'applicationMachine': hex(expected),
                    'applicationSHA256': digest(app), 'installer': package.name,
                    'installerSHA256': digest(package), 'installerBytes': package.stat().st_size,
                    'signed': False, 'runtimeTestedOnWindows': False})
(DEST / 'manifest.json').write_text(json.dumps({'version': VERSION, 'packages': entries}, indent=2) + '\n')
(DEST / 'SHA256SUMS.txt').write_text(''.join(f"{e['installerSHA256']}  {e['installer']}\n" for e in entries))
for entry in entries:
    print(entry['architecture'], DEST / entry['installer'], entry['installerBytes'], 'bytes')
