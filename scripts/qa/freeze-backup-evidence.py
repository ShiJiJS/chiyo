"""Freeze D9 fixed-production-source evidence; retain failures and platform gaps."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / 'docs/development/evidence/31-backup-migration'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def receipt(path):
    return json.loads(next(line for line in reversed(path.read_text(encoding='utf-8').splitlines()) if line.startswith('{')))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True)
    args = parser.parse_args()
    source = subprocess.check_output(['git', 'rev-parse', args.source], cwd=ROOT, text=True).strip()
    subprocess.run(['git', 'diff', '--exit-code', source, '--', 'packages/info_cli/lib', 'packages/info_core/lib', 'packages/info_storage/lib', 'apps/desktop/lib'], cwd=ROOT, check=True)
    assert (ROOT / '.scratch/d9-aot/source.txt').read_text(encoding='utf-8-sig').strip() == source
    full = ROOT / '.d9-final-full-checks.log'
    full_text = full.read_text(encoding='utf-8')
    counts = list(map(int, re.findall(r'\+(\d+): All tests passed!', full_text)))
    assert counts == [54, 130, 61, 104], counts
    assert not re.search(r'\bskipped\b|\bSome tests failed\b|~\d+', full_text)
    for name, marker in [('native', 'D9_NATIVE_VERIFIED'), ('hosted-native', 'D8_NATIVE_VERIFIED')]:
        text = (ROOT / f'.d9-final-{name}-three.log').read_text(encoding='utf-8')
        assert text.count(marker) == 3
        assert len(re.findall(r'\+1: All tests passed!', text)) == 3
        assert 'Some tests failed' not in text
    for path in [full, ROOT / '.d9-final-hosted-native-three.log']:
        result = receipt(path)
        assert result['testExitCode'] == 0 and result['containerRemovedAfterRun'] is True
    legacy = receipt(ROOT / '.d9-legacy-release-upgrade.log')
    assert legacy['newSource'] == source
    assert legacy['oldSource'] == 'ad997289237b9666302251de3ba83d812f5f466e'
    assert len(legacy['markers']) == 4 and legacy['syntheticOnly'] is True
    supplemental = (ROOT / '.d9-backup-credential-only-guard.log').read_text(encoding='utf-8')
    assert '+2: All tests passed!' in supplemental and 'Some tests failed' not in supplemental
    assert '+8: All tests passed!' in (ROOT / '.d9-captures-r2.log').read_text(encoding='utf-8')
    pictures = sorted((DEST / 'r2').glob('*.png'))
    assert len(pictures) == 40
    for picture in pictures:
        data = picture.read_bytes()
        width, height = struct.unpack('>II', data[16:24])
        assert (width, height) in [(1440, 900), (1280, 800)]
    raw = DEST / 'raw'
    raw.mkdir(parents=True, exist_ok=True)
    for log in sorted(ROOT.glob('.d9-*.log')):
        target = raw / log.name.removeprefix('.')
        data = log.read_bytes()
        if target.exists() and target.read_bytes() != data:
            raise RuntimeError(f'Refusing to change frozen bytes: {target.name}')
        target.write_bytes(data)
        assert digest(target.read_bytes()) == digest(data)
    files = {}
    for folder in [raw, DEST / 'r2']:
        for file in sorted(folder.rglob('*')):
            if file.is_file():
                data = file.read_bytes()
                files[file.relative_to(DEST).as_posix()] = {'bytes': len(data), 'sha256': digest(data)}
    source_files = ['apps/desktop/lib/credential_migration.dart', 'apps/desktop/lib/backups.dart', 'apps/desktop/lib/credential_history.dart', 'apps/desktop/lib/credential_execution_receipt.dart', 'apps/desktop/tool/capture_credential_backup_migration.dart', 'apps/desktop/integration_test/backup_migration_native_test.dart', 'apps/desktop/integration_test/hosted_runtime_native_test.dart', 'packages/info_storage/test/credential_backup_test.dart', 'scripts/qa/check-legacy-backup-reader.py', 'docs/design/prototypes/round-05/lifecycle-surfaces.html', 'docs/design/prototypes/round-05/lifecycle.css']
    manifest = {
        'verifiedProductionCommit': source,
        'evidenceBaseCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'createdAtUtc': datetime.now(timezone.utc).isoformat(),
        'status': 'Windows implementation checkpoint; release and manual joint acceptance remain separate',
        'headlessCounts': dict(zip(['cli', 'core', 'storage', 'desktop'], counts)),
        'headlessTotal': sum(counts), 'skipped': 0,
        'backupNativePasses': 3, 'hostedRuntimeNativePasses': 3,
        'nativeScope': 'Real Windows runner/window, current-user DPAPI/SQLCipher and UI actions; injected file picker and inert notification/tray; no actual model agent or user profile',
        'actualOldRelease': legacy,
        'supplemental': 'Credential-only recipient rejection and preservation; added after the full fixed-source run, two targeted backup cases passed',
        'visual': '40 unedited Flutter offscreen PNGs, four themes, two sizes, 200% first/bottom; frozen Round05 shared surfaces; main-session review, no independent agent or browser/computer use',
        'sourceFilesSha256': {path: digest((ROOT / path).read_bytes()) for path in source_files},
        'aotBinariesSha256': {name: digest((ROOT / '.scratch/d9-aot' / name).read_bytes()) for name in ['info.exe', 'info-codex.exe', 'info-runtime-worker.exe']},
        'remaining': ['D8 one earlier native SSH completion timeout lacks stage evidence; later stress passes do not declare it resolved', 'Windows release package and SDK-free extracted verification', 'Clean-machine, actual OS notification click and user-arranged real Codex install/trust joint acceptance', 'Actual macOS/bidirectional restore deferred; server sync paused'],
        'files': files,
    }
    (DEST / 'verification.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'source': source, 'total': sum(counts), 'backupNative': 3, 'hostedNative': 3, 'pictures': len(pictures), 'rawLogs': len(list(raw.glob('*.log')))}))


if __name__ == '__main__':
    main()
