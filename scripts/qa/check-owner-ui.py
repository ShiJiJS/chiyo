#!/usr/bin/env python3
"""Check the complete owner shell with a verified candidate CLI and two owner processes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True, help='Complete AgentInfoManage payload')
    parser.add_argument('--report', type=Path, required=True, help='New JSON under build/')
    args = parser.parse_args()
    payload = args.package.resolve(strict=True)
    manifest = json.loads((payload / 'manifest.json').read_text())
    cli = payload / 'cli/info'
    expected = next(row['sha256'] for row in manifest['files'] if row['path'] == 'cli/info')
    if digest(cli) != expected:
        raise RuntimeError('CLI differs from the candidate manifest')
    report = args.report.resolve()
    report.relative_to(ROOT / 'build')
    if report.exists():
        raise RuntimeError('Refusing to overwrite an existing report')
    report.parent.mkdir(parents=True, exist_ok=True)
    owner_paths = ['apps/desktop/lib', 'apps/desktop/macos', 'packages/info_core/lib',
                   'packages/info_storage/lib', 'packages/info_cli/lib']
    owner_paths += [f'{package}/{name}'
                    for package in ['apps/desktop', 'packages/info_core', 'packages/info_storage', 'packages/info_cli']
                    for name in ['pubspec.yaml', 'pubspec.lock']]
    owner_matches = subprocess.run(['git', 'diff', '--quiet', manifest['sourceCommit'], '--', *owner_paths],
                                   cwd=ROOT, check=False).returncode == 0
    owner_untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '--',
                                               *owner_paths], cwd=ROOT, text=True).strip()
    owner_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    phases = []
    with tempfile.TemporaryDirectory(prefix='owner-ui-', dir=ROOT / '.cache/tmp') as temporary:
        fixture = Path(temporary)
        (fixture / 'fixture-marker').write_text('disposable-owner-ui-v1')
        for phase in ['live', 'reopen']:
            env = dict(os.environ, OWNER_UI_ROOT=str(fixture), OWNER_UI_CLI=str(cli), OWNER_UI_PHASE=phase)
            subprocess.run([str(ROOT / 'scripts/dev-macos.sh'), 'flutter', 'test', '--no-pub',
                            'tool/check_owner_ui.dart', '--reporter', 'expanded'],
                           cwd=ROOT / 'apps/desktop', env=env, check=True, timeout=240)
            result = json.loads((fixture / f'{phase}-result.json').read_text())
            if result.get('passed') is not True or result.get('phase') != phase:
                raise RuntimeError('Missing UI phase evidence')
            phases.append(result)
        if phases[0]['pid'] == phases[1]['pid']:
            raise RuntimeError('Owner reopen needs another process')
    report.write_text(json.dumps({'passed': True, 'candidateSource': manifest['sourceCommit'],
        'ownerSourceCommit': owner_commit, 'ownerImplementationMatchesCandidate': owner_matches and not owner_untracked,
        'cliSha256': expected, 'probeSha256': digest(ROOT / 'apps/desktop/tool/check_owner_ui.dart'),
        'phases': phases, 'fixtureRemoved': True,
        'scope': 'complete owner Flutter UI + HTTP + SQLCipher + shipped CLI; platform fixture, not native or actual AI host'},
        ensure_ascii=False, indent=2) + '\n')
    print('Full owner UI and shipped CLI checks passed')


if __name__ == '__main__':
    main()
