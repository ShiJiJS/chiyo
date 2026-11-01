#!/usr/bin/env python3
"""Independent synthetic classification reopen/backup and genuine old reader.

No GUI, Keychain, personal library, App build, hooks or model calls. Temporary
old source, executable and fixture are removed; retain bounded checks and logs.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASELINE = '77dc8b66114199f41336ddef80e3fa9368707179'
LAUNCHER = str(ROOT / 'scripts/dev-macos.sh')


def main():
    output = ROOT / 'build/macos-adaptation/m08-classification-process'
    output.mkdir(exist_ok=False)
    facts = {'complete': False, 'oldReaderSource': BASELINE, 'phases': [],
             'personalLibraryUsed': False, 'keychainUsed': False,
             'appOrDsymBuilt': False, 'windowsCiRun': False}

    def run(name, args, cwd, timeout=180):
        log = output / (name + '.log')
        with log.open('wb') as stream:
            result = subprocess.run(args, cwd=cwd, stdout=stream,
                                    stderr=subprocess.STDOUT, timeout=timeout,
                                    env=dict(os.environ, TMPDIR=str((ROOT / '.cache/tmp').resolve()) + '/'))
        facts['phases'].append({'name': name, 'exit': result.returncode,
                                'logSha256': hashlib.sha256(log.read_bytes()).hexdigest()})
        if result.returncode:
            raise RuntimeError(f'{name} failed; see {log}')
        print(json.dumps({'phase': name, 'exit': 0}), flush=True)
        return log

    try:
        with tempfile.TemporaryDirectory(prefix='credential-classification-process-', dir=ROOT / '.cache/tmp') as fixture_name, \
                tempfile.TemporaryDirectory(prefix='old-source-', dir=output) as snapshot_name:
            fixture = Path(fixture_name).resolve()
            (fixture / 'fixture-marker').write_text('synthetic-classification-v1')
            snapshot = Path(snapshot_name).resolve()
            archive = subprocess.check_output(['git', 'archive', BASELINE,
                                               'packages/info_core', 'packages/info_storage'], cwd=ROOT)
            with tarfile.open(fileobj=io.BytesIO(archive)) as source:
                for member in source.getmembers():
                    if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
                        raise RuntimeError('Unexpected source archive entry')
                    target = snapshot / member.name
                    target.resolve().relative_to(snapshot)
                    if member.isdir():
                        target.mkdir(parents=True, exist_ok=True)
                    else:
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(source.extractfile(member).read())
            package = snapshot / 'packages/info_storage'
            library = package / 'lib/info_storage.dart'
            if 'const _portableFocusedFillLibraryFormat = 39;' not in library.read_text() or '_credentialClassificationLibraryFormat' in library.read_text():
                raise RuntimeError('Unexpected genuine baseline format')
            facts['oldStorageSourceSha256'] = hashlib.sha256(library.read_bytes()).hexdigest()
            entry = package / 'bin/pre_classification_reader.dart'
            entry.parent.mkdir(exist_ok=True)
            entry.write_bytes((ROOT / 'packages/info_storage/test/support/pre_classification_reader.dart').read_bytes())
            run('old-offline-resolution', [LAUNCHER, 'dart', 'pub', 'get', '--offline', '--enforce-lockfile'], package)
            run('old-reader-build', [LAUNCHER, 'dart', 'build', 'cli', '--target-os', 'macos', '--target-arch', 'arm64', '--target', 'bin/pre_classification_reader.dart', '--output', str(snapshot / 'reader')], package)
            executable = snapshot / 'reader/bundle/bin/pre_classification_reader'
            if not executable.is_file():
                raise RuntimeError('Missing genuine old reader')
            facts['oldReaderExecutableSha256'] = hashlib.sha256(executable.read_bytes()).hexdigest()
            current = ROOT / 'packages/info_storage'
            results = []
            for phase in ['seed', 'read']:
                run(phase, [LAUNCHER, 'dart', 'run', 'tool/check_credential_classification.dart', str(fixture), phase], current)
                results.append(json.loads((fixture / (phase + '-result.json')).read_text()))
            before = hashlib.sha256((fixture / 'source/library.db').read_bytes()).hexdigest()
            for action in ['library', 'backup']:
                log = run('old-' + action, [str(executable), str(fixture), action], current)
                results.append(json.loads(log.read_text().strip().splitlines()[-1]))
            if hashlib.sha256((fixture / 'source/library.db').read_bytes()).hexdigest() != before:
                raise RuntimeError('Old reader changed protected source library')
            for phase in ['restore', 'restored-read']:
                run(phase, [LAUNCHER, 'dart', 'run', 'tool/check_credential_classification.dart', str(fixture), phase], current)
                results.append(json.loads((fixture / (phase + '-result.json')).read_text()))
            if len({r['pid'] for r in results}) != len(results):
                raise RuntimeError('Phases were not independent processes')
            facts.update(results=results, oldReaderSourceDatabaseUnchanged=True)
        facts.update(complete=True, temporaryFixtureSourceAndExecutableRemoved=True)
    finally:
        (output / 'verification.json').write_text(json.dumps(facts, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'complete': True, 'independentProcesses': len(results),
                      'temporaryFixtureSourceAndExecutableRemoved': True}), flush=True)


if __name__ == '__main__':
    main()
