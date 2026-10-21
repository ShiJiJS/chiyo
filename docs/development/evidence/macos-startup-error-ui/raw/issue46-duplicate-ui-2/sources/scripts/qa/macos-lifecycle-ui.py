#!/usr/bin/env python3
"""Actual CUA close/reopen/quit paths in an isolated signed Flutter application.

The three ui-hold processes exit only through the native/menu/settings UI.
Synthetic in-memory keys and owner fixture; no production library or Keychain.
Each successful UI exit is followed by another process checking persisted facts.
Generated apps/caches and private fixtures are removed at the end.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import socket
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
ENTRY = 'apps/desktop/integration_test/macos_lifecycle_probe.dart'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    scenario = parser.add_mutually_exclusive_group()
    scenario.add_argument('--startup', action='store_true',
                          help='Actual UI close of startup errors and quit during opening')
    scenario.add_argument('--duplicate-only', action='store_true',
                          help='Only actual duplicate error close, holder quit and recovery')
    args = parser.parse_args()
    if os.uname().sysname != 'Darwin':
        parser.error('macOS required')
    output = args.output.resolve()
    output.relative_to(ROOT / 'build/macos-adaptation')
    output.mkdir(parents=True, exist_ok=False)
    source, logs = output / 'source', output / 'logs'
    source.mkdir()
    logs.mkdir()
    owner = uuid.uuid4().hex
    identity = 'org.shijijs.agent-info-manage.qa.lifecycle.' + uuid.uuid4().hex
    state = {'complete': False, 'scope': __doc__, 'commands': [], 'cases': [],
             'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             'bundleIdentifier': identity}
    processes, roots = [], set()
    app, duplicate_app = None, None
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

    def wait_for(check, process, timeout=60):
        deadline = time.monotonic() + timeout
        while True:
            value = check()
            if value:
                return value
            if process.poll() is not None:
                raise RuntimeError('Application exited before expected evidence')
            if time.monotonic() > deadline:
                raise TimeoutError('Application observation deadline')
            time.sleep(0.1)

    def read_report(root, mode):
        try:
            return json.loads((root / (mode + '-result.json')).read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    def launch(mode, label, root=None):
        environment = os.environ.copy()
        environment.update(INFO_MAC_LIFECYCLE_MODE=mode, INFO_MAC_LIFECYCLE_OWNER=owner)
        environment.pop('INFO_MAC_LIFECYCLE_ROOT', None)
        if root is not None:
            environment['INFO_MAC_LIFECYCLE_ROOT'] = str(root)
        path = logs / (label + '.txt')
        executable = duplicate_app / 'Contents/MacOS/info_desktop' if mode == 'ui-duplicate' else binary
        with path.open('wb') as log:
            process = subprocess.Popen([str(executable)], cwd=source, env=environment,
                                       stdout=log, stderr=subprocess.STDOUT)
        processes.append(process)

        def locate():
            found = re.findall(r'MAC_LIFECYCLE_ROOT=([^\r\n]+)', path.read_text(errors='replace'))
            if not found:
                return None
            candidate = Path(found[-1])
            assert candidate.is_absolute() and not candidate.is_symlink()
            assert candidate.name.startswith('aim-mac-lifecycle-')
            assert (candidate / '.qa-owner').read_text() == owner
            if root is not None:
                assert candidate.resolve() == root
            return candidate.resolve()
        actual = wait_for(locate, process)
        roots.add(actual)
        return process, actual

    def reachable(port):
        with socket.socket() as connection:
            connection.settimeout(1)
            return connection.connect_ex(('127.0.0.1', port)) == 0

    def collect(process, root, mode, label, closes=1):
        code = process.wait(timeout=1800 if mode != 'ui-recover' else 60)
        facts = read_report(root, mode)
        assert code == 0 and facts and not facts.get('failed'), 'Actual lifecycle failed'
        assert facts.get('nativeTerminationRequested') and facts['libraryCloses'] == closes
        if 'port' in facts:
            assert not reachable(facts['port']), 'Endpoint remained after process exit'
        record = {'label': label, 'exitCode': code,
                  'portClosedAfterExit': True if 'port' in facts else None, **facts}
        state['cases'].append(record)
        (output / (label + '.json')).write_text(json.dumps(record, indent=2) + '\n')
        save()
        return facts

    def expose(process, root, label, ready, selected_app=None):
        fd = os.open(controller, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump({'owner': owner, 'root': str(root), 'app': str(selected_app or app),
                       'pid': process.pid, 'case': label, 'port': ready.get('port')}, stream)
        state['waitingForActualUI'] = label
        save()
        print('MAC_LIFECYCLE_UI_READY=' + label, flush=True)

    def startup_cases():
        for mode in ([] if args.duplicate_only else ['ui-key-failure', 'ui-port-busy', 'ui-quit-opening']):
            process, root = launch(mode, mode)
            ready = wait_for(lambda: read_report(root, mode), process)
            assert ready['startup'] == ('opening' if mode == 'ui-quit-opening' else 'failed')
            expose(process, root, mode, ready)
            facts = collect(process, root, mode, mode, closes=0 if mode == 'ui-key-failure' else 1)
            assert ('quit' if mode == 'ui-quit-opening' else 'closeWindow') in facts['nativeEvents']
            if mode == 'ui-key-failure':
                assert facts['keyCreates'] == 0
            if mode == 'ui-quit-opening':
                assert facts['quitWaitedForOpening']
            controller.unlink()
            print('MAC_LIFECYCLE_UI_PASSED=' + mode, flush=True)
        holder, root = launch('ui-hold', 'duplicate-holder')
        ready = wait_for(lambda: read_report(root, 'ui-hold'), holder)
        assert ready['startup'] == 'ready' and reachable(ready['port'])
        before = digest(root / 'library/library.db')
        duplicate, _ = launch('ui-duplicate', 'duplicate-error', root)
        failure = wait_for(lambda: read_report(root, 'ui-duplicate'), duplicate)
        assert failure['startup'] == 'failed' and failure['keyReads'] == 0
        expose(duplicate, root, 'ui-duplicate', failure, duplicate_app)
        facts = collect(duplicate, root, 'ui-duplicate', 'duplicate-error', closes=0)
        assert 'closeWindow' in facts['nativeEvents']
        assert digest(root / 'library/library.db') == before
        assert holder.poll() is None and reachable(ready['port'])
        state['duplicatePreservedHolderDatabaseAndService'] = True
        controller.unlink()
        expose(holder, root, 'duplicate-holder-quit', ready)
        facts = collect(holder, root, 'ui-hold', 'duplicate-holder-quit')
        assert 'quit' in facts['nativeEvents']
        controller.unlink()
        recovered, _ = launch('ui-recover', 'duplicate-holder-reopen', root)
        facts = collect(recovered, root, 'ui-recover', 'duplicate-holder-reopen')
        assert facts['oldAuthorityRefused'] and facts['endedGrantAndAllowedReadPreserved']

    try:
        names = subprocess.check_output(['git', 'ls-files', '-z', 'apps/desktop', 'packages', 'scripts', 'integrations', 'third_party'], cwd=ROOT).decode().split('\0')
        state['inputSourceHashes'] = {}
        for name in sorted(set(filter(None, names)) | {ENTRY, 'scripts/qa/macos-lifecycle-ui.py'}):
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
        run('build-release', [launcher, 'build', '--target=integration_test/macos_lifecycle_probe.dart'])
        app = desktop / 'build/macos/Build/Products/Release/info_desktop.app'
        run('signature', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        binary = app / 'Contents/MacOS/info_desktop'
        state['binarySha256'] = digest(binary)
        if args.startup or args.duplicate_only:
            # Same sandbox/container identity, separately addressable bundle URL
            # and display name. No change to production startup or lock code.
            duplicate_app = app.parent / 'Mac Duplicate QA.app'
            shutil.copytree(app, duplicate_app, symlinks=True)
            plist = duplicate_app / 'Contents/Info.plist'
            contents = plistlib.loads(plist.read_bytes())
            contents['CFBundleName'] = 'Mac Duplicate QA'
            contents['CFBundleDisplayName'] = 'Mac Duplicate QA'
            plist.write_bytes(plistlib.dumps(contents))
            run('sign-duplicate', ['/usr/bin/codesign', '--force', '--sign', '-',
                                   '--preserve-metadata=entitlements,requirements,flags,runtime', str(duplicate_app)])
            run('signature-duplicate', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(duplicate_app)])
            run('entitlements-duplicate', ['/usr/bin/codesign', '-d', '--entitlements', ':-', str(duplicate_app)])
            state['duplicateBundle'] = {'path': str(duplicate_app), 'sameBundleIdentifier': contents['CFBundleIdentifier'],
                                        'displayName': contents['CFBundleDisplayName'], 'binarySha256': digest(duplicate_app / 'Contents/MacOS/info_desktop')}
            startup_cases()
        for label in ([] if args.startup or args.duplicate_only else ['close-reopen-menu-quit', 'command-q', 'settings-quit']):
            process, root = launch('ui-hold', label)
            ready = wait_for(lambda: read_report(root, 'ui-hold'), process)
            assert ready.get('startup') == 'ready' and ready['tray'] and reachable(ready['port'])
            expose(process, root, label, ready)
            facts = collect(process, root, 'ui-hold', label)
            if label == 'close-reopen-menu-quit':
                assert facts['nativeEvents'].count('closeWindow') >= 2
                assert facts['nativeEvents'].count('openApprovals') >= 2
                assert 'quit' in facts['nativeEvents']
            elif label == 'command-q':
                assert 'quit' in facts['nativeEvents']
            controller.unlink()
            recovered, _ = launch('ui-recover', label + '-reopen', root)
            checked = collect(recovered, root, 'ui-recover', label + '-reopen')
            assert checked['oldAuthorityRefused'] and checked['storedInformationPreserved']
            assert checked['endedGrantAndAllowedReadPreserved']
            print('MAC_LIFECYCLE_UI_PASSED=' + label, flush=True)
        state.pop('waitingForActualUI', None)
        state['complete'] = True
    except Exception as error:
        state['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
                state['forcedFailureCleanup'] = True
        for root in roots:
            if root.exists():
                assert not root.is_symlink() and (root / '.qa-owner').read_text() == owner
                shutil.rmtree(root)
        state['ownedFixturesRemoved'] = all(not root.exists() for root in roots)
        controller.unlink(missing_ok=True)
        for bundle in [app, duplicate_app]:
            if bundle is not None and bundle.exists():
                result = subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(bundle)], capture_output=True, timeout=30)
                state.setdefault('unregisterExitCodes', []).append(result.returncode)
        removed = []
        for tail in ['apps/desktop/build', 'apps/desktop/.dart_tool/flutter_build', 'apps/desktop/.dart_tool/hooks_runner']:
            path = source / tail
            if path.exists():
                assert path.resolve().is_relative_to(source) and not path.is_symlink()
                shutil.rmtree(path)
                removed.append(tail)
        state['generatedArtifactsRemoved'] = removed
        save()
    print(json.dumps({'complete': state['complete'], 'cases': len(state['cases'])}), flush=True)


if __name__ == '__main__':
    main()
