#!/usr/bin/env python3
"""Build an isolated Release for actual CUA backup panels, then clean artifacts.

No personal Keychain/profile; synthetic owner API fixture and real native file
panels. A private controller only coordinates source/target/finish. Files are
selected through CUA; the driver never substitutes file-dialog return values.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
ENTRY = 'apps/desktop/integration_test/macos_backup_manual.dart'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if os.uname().sysname != 'Darwin':
        parser.error('macOS required')
    output = args.output.resolve()
    output.relative_to(ROOT / 'build/macos-adaptation')
    output.mkdir(parents=True, exist_ok=False)
    source = output / 'source'
    logs = output / 'logs'
    source.mkdir()
    logs.mkdir()
    (output / 'exports').mkdir()
    owner = uuid.uuid4().hex
    identity = 'org.shijijs.agent-info-manage.qa.backup.' + uuid.uuid4().hex
    state = {'complete': False, 'scope': __doc__, 'commands': [],
             'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             'bundleIdentifier': identity, 'stagingObservations': []}
    process, root, app = None, None, None
    controller = output / 'controller.json'

    def save():
        (output / 'result.json').write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')

    def run(label, command, cwd=source):
        with (logs / (label + '.txt')).open('wb') as log:
            result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=900)
        state['commands'].append({'label': label, 'exitCode': result.returncode, 'command': command})
        save()
        print(label, result.returncode, flush=True)
        if result.returncode:
            raise RuntimeError(label + ' failed')

    try:
        names = subprocess.check_output(['git', 'ls-files', '-z', 'apps/desktop', 'packages', 'scripts', 'integrations', 'third_party'], cwd=ROOT).decode().split('\0')
        state['inputSourceHashes'] = {}
        for name in sorted(set(filter(None, names)) | {ENTRY, 'scripts/qa/macos-backup-panels.py'}):
            path = ROOT / name
            assert path.is_file() and not path.is_symlink()
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
            state['inputSourceHashes'][name] = digest(path)
        (source / '.tools').symlink_to(ROOT / '.tools', target_is_directory=True)
        (source / '.cache').mkdir()
        (source / '.cache/pub').symlink_to(ROOT / '.cache/pub', target_is_directory=True)
        config = source / 'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig'
        original = 'PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop'
        assert config.read_text().count(original) == 1
        config.write_text(config.read_text().replace(original, 'PRODUCT_BUNDLE_IDENTIFIER = ' + identity))
        state['copyModifications'] = {str(config.relative_to(source)): digest(config)}
        save()
        launcher = str(source / 'scripts/dev-macos.sh')
        for package in ['info_core', 'info_cli', 'info_storage']:
            run('pub-' + package, [launcher, 'dart', 'pub', 'get', '--enforce-lockfile'], source / 'packages' / package)
        desktop = source / 'apps/desktop'
        run('pub-desktop', [launcher, 'flutter', 'pub', 'get', '--enforce-lockfile'], desktop)
        run('analyze', [launcher, 'flutter', 'analyze', '--no-pub', '--fatal-infos', '--fatal-warnings'], desktop)
        run('build-release', [launcher, 'build', '--target=integration_test/macos_backup_manual.dart'])
        app = desktop / 'build/macos/Build/Products/Release/info_desktop.app'
        run('signature', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        run('entitlements', ['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)])
        binary = app / 'Contents/MacOS/info_desktop'
        state['binarySha256'] = digest(binary)
        environment = os.environ.copy()
        environment['MAC_BACKUP_QA_OWNER'] = owner
        with (logs / 'application.txt').open('wb') as log:
            process = subprocess.Popen([str(binary)], cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT)
        state['pid'] = process.pid
        state['running'] = True
        save()
        deadline = time.monotonic() + 1800
        observed = set()
        while process.poll() is None:
            text = (logs / 'application.txt').read_text(errors='replace')
            matches = re.findall(r'MAC_BACKUP_ROOT=([^\r\n]+)', text)
            if matches and root is None:
                candidate = Path(matches[-1])
                assert candidate.is_absolute() and candidate.name.startswith('aim-mac-backup-panel-') and not candidate.is_symlink()
                assert (candidate / '.qa-owner').read_text() == owner
                root = candidate.resolve()
                fd = os.open(controller, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                with os.fdopen(fd, 'w') as stream:
                    json.dump({'owner': owner, 'root': str(root), 'app': str(app), 'pid': process.pid}, stream)
                state['controllerReady'] = True
                save()
                print('MAC_BACKUP_PANEL_READY', flush=True)
            if root is not None:
                for path in sorted(root.glob('staging-observation-*.json')):
                    if path.name in observed:
                        continue
                    observation = json.loads(path.read_text())
                    destination = Path(observation['destinationParent'])
                    staging = Path(observation['directory'])
                    assert destination.resolve() == (output / 'exports').resolve(), 'Unexpected selected output parent'
                    assert staging.is_dir() and not staging.is_symlink()
                    devices = [os.stat(destination).st_dev, os.stat(staging).st_dev]
                    assert devices[0] == devices[1], 'Native staging is not on destination volume'
                    state['stagingObservations'].append({'index': len(observed) + 1, 'destinationDevice': devices[0],
                                                         'stagingDevice': devices[1], 'sameVolume': True})
                    observed.add(path.name)
                    (root / path.name.replace('staging-observation-', 'staging-observed-').removesuffix('.json')).touch(exist_ok=False)
                    save()
                result = root / 'result.json'
                if result.exists() and not (output / 'panel-result.json').exists():
                    shutil.copyfile(result, output / 'panel-result.json')
                    state['panelFlowPassed'] = True
                    save()
                    print('MAC_BACKUP_PANEL_FLOW_PASSED', flush=True)
            if time.monotonic() > deadline:
                raise TimeoutError('Actual panel acceptance deadline')
            time.sleep(0.1)
        state['running'] = False
        state['exitCode'] = process.returncode
        state['complete'] = process.returncode == 0 and state.get('panelFlowPassed', False)
        state['ownedFixtureRemoved'] = root is not None and not root.exists()
        assert state['complete'] and state['ownedFixtureRemoved'], 'Actual panel run did not complete cleanly'
    except Exception as error:
        state['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=10)
            state['forcedFailureCleanup'] = True
        if root is not None and root.exists():
            assert (root / '.qa-owner').read_text() == owner and not root.is_symlink()
            shutil.rmtree(root)
            state['ownedFailureFixtureRemoved'] = True
        controller.unlink(missing_ok=True)
        if app is not None and app.exists():
            result = subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(app)], capture_output=True, timeout=30)
            state['unregisterExitCode'] = result.returncode
        removed = []
        for tail in ['apps/desktop/build', 'apps/desktop/.dart_tool/flutter_build', 'apps/desktop/.dart_tool/hooks_runner']:
            path = source / tail
            if path.exists():
                assert path.resolve().is_relative_to(source) and not path.is_symlink()
                shutil.rmtree(path)
                removed.append(tail)
        state['generatedArtifactsRemoved'] = removed
        save()
    print(json.dumps({'complete': state['complete'], 'exitCode': state['exitCode'], 'generatedArtifactsRemoved': bool(state['generatedArtifactsRemoved'])}), flush=True)


if __name__ == '__main__':
    main()
