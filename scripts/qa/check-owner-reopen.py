#!/usr/bin/env python3
"""Check real owner persistence in five independent, sequential test processes.

Uses disposable synthetic data and a test-only key; never starts the installed
App or accesses Keychain. Native platform calls are fixtures, not UI evidence.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    cache = ROOT / '.cache' / 'tmp'
    cache.mkdir(parents=True, exist_ok=True)
    results = []
    with tempfile.TemporaryDirectory(prefix='owner-reopen-', dir=cache) as temp:
        fixture = Path(temp)
        (fixture / 'fixture-marker').write_text('disposable-owner-reopen-v1')
        for phase in ['seed', 'edit', 'read', 'restore', 'restored-read']:
            env = dict(os.environ, OWNER_REOPEN_ROOT=str(fixture), OWNER_REOPEN_PHASE=phase)
            subprocess.run(
                [str(ROOT / 'scripts/dev-macos.sh'), 'flutter', 'test', '--no-pub',
                 'tool/check_owner_reopen.dart', '--reporter', 'expanded'],
                cwd=ROOT / 'apps/desktop', env=env, check=True, timeout=180,
            )
            result = json.loads((fixture / f'{phase}-result.json').read_text())
            if result['phase'] != phase or result['passed'] is not True:
                raise RuntimeError('Missing phase completion')
            results.append(result)
        if len({row['pid'] for row in results}) != len(results):
            raise RuntimeError('Processes were not independent')
    print(json.dumps({'passed': True, 'phases': results, 'fixtureRemoved': True}))


if __name__ == '__main__':
    main()
