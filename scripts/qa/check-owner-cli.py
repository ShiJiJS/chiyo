#!/usr/bin/env python3
"""Check the owner UI adapters against separate compiled CLI processes.

All keys, hook inputs and association files belong to this disposable fixture.
No host hook registration/trust, personal library, Keychain or native UI calls.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TOOLS = [('info', 'info'), ('codex_info', 'info-codex'), ('codex_hook', 'info-codex-hook')]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools', type=Path, help='Use these precompiled package CLI files')
    parser.add_argument('--report', type=Path, required=True, help='New evidence JSON under build/')
    args = parser.parse_args()
    report = args.report.resolve()
    report.relative_to(ROOT / 'build')
    if report.exists():
        raise RuntimeError('Refusing to replace an existing report')
    report.parent.mkdir(parents=True, exist_ok=True)
    cache = ROOT / '.cache/tmp'
    cache.mkdir(parents=True, exist_ok=True)
    phases = []
    with tempfile.TemporaryDirectory(prefix='owner-cli-', dir=cache) as temporary:
        fixture = Path(temporary)
        (fixture / 'fixture-marker').write_text('disposable-owner-cli-v1')
        tools = args.tools.resolve(strict=True) if args.tools else fixture / 'cli'
        if args.tools is None:
            tools.mkdir()
            for entry, name in TOOLS:
                subprocess.run([str(ROOT / 'scripts/dev-macos.sh'), 'dart', 'compile', 'exe',
                                f'bin/{entry}.dart', '-o', str(tools / name)],
                               cwd=ROOT / 'packages/info_cli', check=True, timeout=180)
        binaries = {name: digest(tools / name) for _, name in TOOLS}
        for phase in ['live', 'reopen']:
            env = dict(os.environ, OWNER_CLI_ROOT=str(fixture), OWNER_CLI_TOOLS=str(tools),
                       OWNER_CLI_PHASE=phase)
            subprocess.run([str(ROOT / 'scripts/dev-macos.sh'), 'flutter', 'test', '--no-pub',
                            'tool/check_owner_cli.dart', '--reporter', 'expanded'],
                           cwd=ROOT / 'apps/desktop', env=env, check=True, timeout=240)
            result = json.loads((fixture / f'{phase}-result.json').read_text())
            if result.get('passed') is not True or result.get('phase') != phase:
                raise RuntimeError('Missing phase evidence')
            phases.append(result)
        if phases[0]['pid'] == phases[1]['pid']:
            raise RuntimeError('Owner reopen did not use another process')
    result = {'passed': True, 'phases': phases, 'cliSha256': binaries,
              'probeSha256': digest(ROOT / 'apps/desktop/tool/check_owner_cli.dart'),
              'fixtureRemoved': True,
              'scope': 'compiled CLI + HTTP + SQLCipher + owner controllers; synthetic hook input, not actual AI host or native UI acceptance'}
    report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
