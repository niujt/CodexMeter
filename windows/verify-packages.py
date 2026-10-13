#!/usr/bin/env python3
"""Verify application PE architectures and collect two NSIS installers."""
from pathlib import Path
import hashlib
import json
import shutil
import struct
import argparse
import datetime
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--architecture', choices=['all', 'x64', 'arm64'], default='all')
args = parser.parse_args()

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
    if args.architecture != 'all' and arch != args.architecture:
        continue
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
    signature = Path(str(installer) + '.sig')
    assert signature.is_file() and signature.stat().st_size > 0, 'Missing updater signature'
    shutil.copy2(signature, Path(str(package) + '.sig'))
    application_copy = DEST / f'Codex-Health-{VERSION}-windows-{arch}.exe'
    shutil.copy2(app, application_copy)
    assert digest(application_copy) == digest(app)
    entries.append({'architecture': arch, 'target': target, 'applicationMachine': hex(expected),
                    'applicationSHA256': digest(app), 'installer': package.name,
                    'installerSHA256': digest(package), 'installerBytes': package.stat().st_size,
                    'signed': False, 'updaterSigned': True, 'runtimeTestedOnWindows': False})
suffix = '' if args.architecture == 'all' else f'-{args.architecture}'
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
(DEST / f'manifest{suffix}.json').write_text(json.dumps({'version': VERSION, 'sourceCommit': commit, 'packages': entries}, indent=2) + '\n')
(DEST / f'SHA256SUMS{suffix}.txt').write_text(''.join(f"{e['installerSHA256']}  {e['installer']}\n" for e in entries))
platforms = {}
for entry in entries:
    key = 'windows-x86_64' if entry['architecture'] == 'x64' else 'windows-aarch64'
    platforms[key] = {'signature': (DEST / (entry['installer'] + '.sig')).read_text().strip(),
                      'url': f"https://github.com/niujt/CodexMeter/releases/download/windows-v{VERSION}/{entry['installer']}"}
(DEST / f'latest{suffix}.json').write_text(json.dumps({'version': VERSION,
    'notes': '额度独立解析、采样时间与旧数据提示；设置 → 关于支持检查、下载并安装签名更新。',
    'pub_date': datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
    'platforms': platforms}, ensure_ascii=False, indent=2) + '\n')
for entry in entries:
    print(entry['architecture'], DEST / entry['installer'], entry['installerBytes'], 'bytes')
