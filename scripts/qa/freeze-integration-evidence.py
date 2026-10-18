"""Freeze D8 checkpoint evidence, retaining the unresolved native timeout."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / 'docs/development/evidence/30-integration'

def sha(data):
    return hashlib.sha256(data).hexdigest()

def final_receipt(path):
    lines = path.read_text(encoding='utf-8').splitlines()
    receipt = json.loads(next(line for line in reversed(lines) if line.startswith('{')))
    assert receipt['testExitCode'] == 0 and receipt['containerRemovedAfterRun'] is True
    return receipt

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True)
    parser.add_argument('--native-test-source', required=True)
    args = parser.parse_args()
    source = subprocess.check_output(['git', 'rev-parse', args.source], cwd=ROOT, text=True).strip()
    subprocess.run(['git', 'diff', '--exit-code', source, '--', 'packages', 'apps/desktop/lib', 'apps/desktop/test'], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    native_source = subprocess.check_output(['git', 'rev-parse', args.native_test_source], cwd=ROOT, text=True).strip()
    test_path = 'apps/desktop/integration_test/hosted_runtime_native_test.dart'
    archived_test = subprocess.check_output(['git', 'show', f'{native_source}:{test_path}'], cwd=ROOT)
    assert archived_test.replace(b'\r\n', b'\n') == (ROOT / test_path).read_bytes().replace(b'\r\n', b'\n')
    aot = ROOT / '.scratch/d8-aot'
    assert (aot / 'source.txt').read_text(encoding='utf-8-sig').strip() == source
    full = ROOT / '.d8-final-full-checks.log'
    counts = list(map(int, re.findall(r'\+(\d+): All tests passed!', full.read_text(encoding='utf-8'))))
    assert counts == [54, 130, 56, 103], counts
    assert not re.search(r'\bskipped\b|\bSome tests failed\b|~\d+', full.read_text(encoding='utf-8'))
    stress = ROOT / '.d8-final-cli-three.log'
    stress_text = stress.read_text(encoding='utf-8')
    assert list(map(int, re.findall(r'\+(\d+): All tests passed!', stress_text))) == [54, 54, 54]
    assert not re.search(r'\bskipped\b|\bSome tests failed\b|~\d+', stress_text)
    native = ROOT / '.d8-native-repeat-diagnostic.log'
    native_text = native.read_text(encoding='utf-8')
    assert native_text.count('D8_NATIVE_VERIFIED') == 3
    assert len(re.findall(r'\+1: All tests passed!', native_text)) == 3
    receipts = {'cliThreePasses': final_receipt(stress), 'headless': final_receipt(full), 'native': final_receipt(native)}
    assert len(list((DEST / 'history-r4').glob('*.png'))) == 32
    for report in (DEST / 'compare-history-r4').glob('*/report.json'):
        assert not any(item.get('issues') for item in json.loads(report.read_text(encoding='utf-8')))
    raw = DEST / 'raw'
    raw.mkdir(parents=True, exist_ok=True)
    for log in sorted(ROOT.glob('.d8-*.log')):
        data = log.read_bytes()
        target = raw / log.name.removeprefix('.')
        if target.exists() and target.read_bytes() != data:
            raise RuntimeError(f'Refusing to overwrite frozen bytes: {target.name}')
        target.write_bytes(data)
        assert sha(target.read_bytes()) == sha(data)
    files = {}
    for folder in ['raw', 'history-r4', 'compare-history-r4', 'reference-history']:
        for file in sorted((DEST / folder).rglob('*')):
            if file.is_file():
                data = file.read_bytes()
                files[file.relative_to(DEST).as_posix()] = {'bytes': len(data), 'sha256': sha(data)}
    manifest = {
        'sourceCommit': source,
        'nativeTestSourceCommit': native_source,
        'status': 'checkpoint; unresolved prior native completion timeout retained',
        'createdAtUtc': datetime.now(timezone.utc).isoformat(),
        'headlessCounts': dict(zip(['cli', 'core', 'storage', 'desktop'], counts)),
        'headlessTotal': sum(counts), 'skipped': 0,
        'cliRepeatedPasses': 3,
        'nativeRepeatedPasses': 3,
        'nativeScope': 'Real Windows window, resident host, independent AOT adapters, default worker, localhost OpenSSH, Runtime stop and SQLCipher/DPAPI reopen; test runner itself remains alive',
        'fixtures': receipts,
        'aotBinaries': {name: sha((aot / name).read_bytes()) for name in ['info.exe', 'info-codex.exe', 'info-runtime-worker.exe']},
        'review': 'Main-session self-check; no independent agents',
        'computerUse': False,
        'visualEvidence': '32 offscreen captures and two comparisons; source PNGs unmodified; different test content and row counts mean diff percentages are not pixel-identity claims',
        'remaining': ['One prior native SSH completion timeout lacks stage evidence and is not declared resolved by later green runs', 'D9 full credential backup and explicit field migration continues separately', 'Clean Windows install/upgrade and release package acceptance', 'Actual OS notification click', 'User-arranged real Codex install/trust acceptance; no model agent invoked', 'Mac deferred; server sync paused'],
        'files': files,
    }
    (DEST / 'verification.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'source': source, 'total': sum(counts), 'nativePasses': 3, 'rawLogs': len(list(raw.glob('*.log'))), 'files': len(files)}))

if __name__ == '__main__':
    main()
