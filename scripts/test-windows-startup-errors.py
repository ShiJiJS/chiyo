"""Observe packaged startup failures with synthetic DPAPI/SQLCipher profiles.

Requires an operator (human or Computer Use) to inspect each error window and
close it. No UI inputs, screenshots, default profile, registry or Codex changes
are automated by this harness. Evidence markers describe actual observations.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time


def digest(path):
    return ({'exists': True, 'bytes': path.stat().st_size,
             'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
            if path.is_file() else {'exists': False})


def main():
    if os.name != 'nt':
        raise RuntimeError('This harness requires Windows')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--delivery', type=Path, required=True)
    parser.add_argument('--dart', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    delivery = args.delivery.resolve(strict=True)
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((delivery/'manifest.json').read_text(encoding='utf-8-sig'))
    assert manifest['architecture'] == 'windows-x64' and not manifest['sourceDirty']
    for entry in manifest['files']:
        target = (delivery/entry['path']).resolve(strict=True)
        assert target.is_relative_to(delivery)
        assert digest(target) == {'exists': True, 'bytes': entry['bytes'],
                                  'sha256': entry['sha256']}, entry['path']
    executable = delivery/'app/info_desktop.exe'
    temporary = Path(tempfile.mkdtemp(prefix='aim-packaged-startup-')).resolve()
    env = os.environ.copy()
    env.update(PUB_HOSTED_URL='https://pub.flutter-io.cn',
               FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn')
    locks = {root/p/'pubspec.lock': (root/p/'pubspec.lock').read_bytes() for p in
             ['packages/info_cli', 'packages/info_core', 'packages/info_storage', 'apps/desktop']}
    normalize = lambda b: b.replace(b'https://pub.flutter-io.cn', b'https://pub.dev').replace(b'\r\n', b'\n')
    process = None
    facts = {'release': manifest['release'], 'sourceCommit': manifest['sourceCommit'],
             'executable': str(executable), 'executableSha256': digest(executable)['sha256'],
             'cases': [], 'complete': False}
    try:
        for path, original in locks.items():
            path.write_bytes(original.replace(b'https://pub.dev', b'https://pub.flutter-io.cn'))
        package = root/'packages/info_storage'
        with (evidence/'prepare.txt').open('wb') as log:
            for command in [
                [str(args.dart), 'pub', 'get', '--enforce-lockfile', '--offline'],
                [str(args.dart), 'run', 'test/support/packaged_startup_fixture.dart', str(temporary)],
            ]:
                result = subprocess.run(command, cwd=package, env=env,
                                        stdout=log, stderr=subprocess.STDOUT)
                assert result.returncode == 0, 'Synthetic fixture preparation failed'
        shutil.copyfile(temporary/'fixtures.json', evidence/'fixtures.json')
        fixtures = json.loads((temporary/'fixtures.json').read_text())['cases']
        for fixture in fixtures:
            name = fixture['case']
            local = Path(fixture['localAppData']).resolve(strict=True)
            assert local.is_relative_to(temporary)
            assert {p: digest(local/p) for p in fixture['protectedFiles']} == fixture['protectedFiles']
            child_env = env.copy()
            child_env['LOCALAPPDATA'] = str(local)
            with (evidence/(name+'-app.txt')).open('wb') as log:
                startup = subprocess.STARTUPINFO()
                startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                startup.wShowWindow = 0  # The app shows its own failure window.
                process = subprocess.Popen([str(executable)], cwd=executable.parent,
                                           env=child_env, stdin=subprocess.DEVNULL,
                                           stdout=log, stderr=subprocess.STDOUT,
                                           startupinfo=startup)
                phase = {'stage': 'observe-and-close', 'case': name, 'pid': process.pid,
                         'executable': str(executable), 'localAppData': str(local)}
                (evidence/'phase.json').write_text(json.dumps(phase, indent=2), encoding='utf-8')
                print(json.dumps(phase), flush=True)
                try:
                    code = process.wait(timeout=120)
                except subprocess.TimeoutExpired:
                    raise RuntimeError('No bounded observation/close for '+name)
                observed_path = evidence/(name+'-observed.json')
                receipt_deadline = time.monotonic()+20
                while time.monotonic() < receipt_deadline:
                    if observed_path.is_file():
                        break
                    time.sleep(0.1)
                assert observed_path.is_file(), 'No actual GUI observation recorded for '+name
                observed = json.loads(observed_path.read_text(encoding='utf-8'))
                assert observed['case'] == name and observed['pid'] == process.pid
                assert observed['errorHeading'] == '无法打开信息库'
                assert observed['originalDataProtectionText'] is True
                assert observed['retryVisible'] is True
                assert observed['closedThroughUi'] is True and code == 0
                after = {p: digest(local/p) for p in fixture['protectedFiles']}
                assert after == fixture['protectedFiles'], 'Protected original changed for '+name
                facts['cases'].append({'case': name, 'pid': process.pid, 'exitCode': code,
                                       'protectedFilesUnchanged': True, 'observation': observed})
                process = None
                print(json.dumps({'case': name, 'state': 'verified'}), flush=True)
        facts['complete'] = True
    finally:
        if process is not None and process.poll() is None:
            process.terminate()  # Only the exact child created by this harness.
            process.wait(timeout=10)
        unexpected = []
        for path, original in locks.items():
            if normalize(path.read_bytes()) == normalize(original):
                path.write_bytes(original)
            else:
                unexpected.append(str(path))
        facts['unexpectedLocks'] = unexpected
        actual = temporary.resolve(strict=True)
        assert actual.parent == Path(tempfile.gettempdir()).resolve()
        assert actual.name.startswith('aim-packaged-startup-')
        for path in actual.rglob('*'):
            assert path.resolve().is_relative_to(actual)
            assert not path.is_symlink() and not path.is_junction()
        shutil.rmtree(actual)
        facts['fixtureRemoved'] = not actual.exists()
        (evidence/'result.json').write_text(json.dumps(facts, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        assert not unexpected, unexpected


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    main()
