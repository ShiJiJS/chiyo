#!/usr/bin/env python3
"""Read only the retained package23 synthetic export, never the live library.

Three separate Flutter test processes restore, edit through the production
workspace adapter, then reopen and export/restore again. No native input,
Keychain access or installed Release upgrade is claimed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BACKUP = ROOT / 'local/private/mac-final-candidate-20261022/encrypted-backup/候选23升级后 完整备份.aimbackup'
KEY = ROOT / 'local/private/mac-upgrade-20261022/recovery-key/升级前 恢复密钥.txt'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.relative_to(ROOT / 'build/macos-adaptation')
    for path in (BACKUP, KEY):
        if (not path.is_file() or path.resolve() != path or
                path.stat().st_mode & 0o777 != 0o600):
            raise RuntimeError('Historical synthetic input unavailable or unsafe')
    # Only the encrypted archive fingerprint is persisted, never a key digest.
    before = {p: digest(p) for p in (BACKUP, KEY)}
    output.mkdir(parents=True, exist_ok=False)
    facts = {'scope': __doc__, 'passed': False, 'phases': [],
             'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             'historicalPackageSource': '7b19d34b61cf07d5a77db05adb8f0c9cdbf85805',
             'backupSha256': before[BACKUP], 'originalLibraryOpened': False,
             'keychainAccessed': False, 'nativeReleaseAcceptance': False}
    fixture = None
    try:
        cache = ROOT / '.cache/tmp'
        cache.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='owner-legacy-', dir=cache) as temp:
            fixture = Path(temp)
            (fixture / 'fixture-marker').write_text('disposable-owner-legacy-v1')
            for phase in ('restore', 'edit', 'reopen'):
                env = dict(os.environ, OWNER_LEGACY_ROOT=str(fixture), OWNER_LEGACY_PHASE=phase,
                           OWNER_LEGACY_BACKUP=str(BACKUP), OWNER_LEGACY_KEY=str(KEY))
                logpath = output / (phase + '.log')
                with logpath.open('xb') as log:
                    logpath.chmod(0o600)
                    process = subprocess.run([str(ROOT / 'scripts/dev-macos.sh'), 'flutter',
                        'test', '--no-pub', 'tool/check_owner_legacy_export.dart',
                        '--reporter', 'expanded'], cwd=ROOT / 'apps/desktop', env=env,
                        stdout=log, stderr=subprocess.STDOUT, timeout=180)
                print(phase, process.returncode, flush=True)
                if process.returncode:
                    raise RuntimeError('Legacy export phase failed: ' + phase)
                result = json.loads((fixture / (phase + '-result.json')).read_text())
                if result['phase'] != phase or result['passed'] is not True:
                    raise RuntimeError('Missing phase result')
                facts['phases'].append(result)
            if len({p['pid'] for p in facts['phases']}) != 3:
                raise RuntimeError('Processes were not independent')
            facts['passed'] = True
    finally:
        facts['inputsUnchanged'] = all(digest(p) == value for p, value in before.items())
        facts['fixtureRemoved'] = fixture is not None and not fixture.exists()
        facts['passed'] = facts['passed'] and facts['inputsUnchanged'] and facts['fixtureRemoved']
        facts['checkerSources'] = {name: digest(ROOT / name) for name in (
            'scripts/qa/check-owner-legacy-export.py',
            'apps/desktop/tool/check_owner_legacy_export.dart',
            'apps/desktop/integration_test/support/macos_keychain_backup.dart')}
        (output / 'result.json').write_text(json.dumps(facts, ensure_ascii=False, indent=2) + '\n')
    if not facts['passed']:
        raise RuntimeError('Legacy export check incomplete')


if __name__ == '__main__':
    main()
