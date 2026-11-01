#!/usr/bin/env python3
"""Two signed sandbox processes, real scope recovery, and an external deny canary."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New directory under this checkout build/')
    args = parser.parse_args()
    out = args.output.resolve()
    out.relative_to(ROOT / 'build')
    out.mkdir(parents=True, exist_ok=False)
    identity = 'com.example.infoDesktop.backupScopeQA.' + uuid.uuid4().hex
    container = Path.home() / 'Library/Containers' / identity
    if container.exists() or container.is_symlink():
        raise RuntimeError('Refuse existing test container')
    app = out / 'ScopeProbe.app'
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    executable = contents / 'MacOS/ScopeProbe'
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': identity, 'CFBundleExecutable': 'ScopeProbe',
        'CFBundlePackageType': 'APPL', 'CFBundleName': 'BackupScopeSyntheticProbe', 'CFBundleVersion': '1',
    }))
    canary = out / 'external-deny-canary.txt'
    canary.write_bytes(b'synthetic-only')
    canary.chmod(0o600)
    report = {'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'registrySha256': hashlib.sha256((ROOT/'apps/desktop/macos/Runner/BackupStagingRegistry.swift').read_bytes()).hexdigest(),
              'probeSha256': hashlib.sha256((ROOT/'apps/desktop/macos/backup_files/tests/SandboxScopeChecks.swift').read_bytes()).hexdigest(),
              'complete': False, 'identity': identity, 'phases': [],
              'limits': ['Container-contained output; no NSOpenPanel/NSSavePanel',
                         'No external-volume grant or stale-bookmark App acceptance',
                         'Standalone signed helper, not the Flutter App']}
    def run(name, command, env=None):
        with (out / (name + '.log')).open('w') as log:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        report['phases'].append({'name': name, 'exit': result.returncode})
        if result.returncode:
            raise RuntimeError(name + ' failed; inspect log')
    try:
        run('compile', ['swiftc', str(ROOT/'apps/desktop/macos/Runner/BackupStagingRegistry.swift'),
                        str(ROOT/'apps/desktop/macos/backup_files/tests/SandboxScopeChecks.swift'), '-o', str(executable)])
        run('sign', ['codesign', '--force', '--sign', '-', '--entitlements',
                     str(ROOT/'apps/desktop/macos/Runner/Release.entitlements'), str(app)])
        run('verify-signature', ['codesign', '--verify', '--strict', str(app)])
        entitlement_data = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL)
        entitlements = plistlib.loads(entitlement_data)
        for key in ['com.apple.security.app-sandbox', 'com.apple.security.files.bookmarks.app-scope']:
            if entitlements.get(key) is not True:
                raise RuntimeError('Missing sandbox/scope entitlement')
        report['entitlements'] = entitlements
        env = dict(os.environ, BACKUP_QA_DENIED=str(canary))
        for phase, marker in [('seed', 'SANDBOX_SCOPE_SEED_PASS'), ('recover', 'SANDBOX_SCOPE_REOPEN_PASS')]:
            run(phase, [str(executable), phase], env=env)
            output = (out / (phase + '.log')).read_text()
            if marker not in output or 'SANDBOX_OUTSIDE_READ_DENIED' not in output:
                raise RuntimeError('Missing sandbox enforcement/recovery proof')
        if canary.read_bytes() != b'synthetic-only':
            raise RuntimeError('External canary changed')
        # Exact random identity was absent before this run. The two probe
        # processes are terminal; only their newly created container is removed.
        if container.is_symlink() or not container.is_dir():
            raise RuntimeError('Synthetic container changed')
        if (container/'Data/Library/Application Support/BackupScopeSynthetic').exists():
            raise RuntimeError('Probe did not finish cleanup')
        try:
            shutil.rmtree(container)
        except PermissionError:
            # macOS protects containermanagerd metadata even after all probe
            # data is gone. Preserve it; never escalate or weaken protection.
            report['cleanupWarning'] = 'macOS retained protected test-container metadata'
        report['containerRemoved'] = not container.exists()
        shutil.rmtree(app)
        canary.unlink()
        report['temporaryAppRemoved'] = not app.exists()
        report['complete'] = True
    finally:
        (out/'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(report, ensure_ascii=False))

if __name__ == '__main__':
    main()
