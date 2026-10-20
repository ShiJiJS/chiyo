#!/usr/bin/env python3
"""Release Flutter + real Keychain + SQLCipher in a dedicated source copy.

Only the copy's app identity, Keychain service, and QA-only fixture methods are
changed. Production store/adapter/startup/storage/lifetime sources stay exact.
Never read/delete production Keychain items; never export keys/private fixture
associations/databases. No physical keyboard/menu/locked-Keychain claim.
"""
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
ENTRY = 'apps/desktop/integration_test/macos_keychain_probe.dart'
INJECTION = 'scripts/qa/macos-flutter-keychain-injection.swift'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if sys.platform != 'darwin' or len(sys.argv) != 2:
        raise SystemExit('Usage on macOS: macos-flutter-keychain.py NEW_OUTPUT_DIRECTORY')
    output = Path(sys.argv[1]).resolve()
    output.relative_to(ROOT / 'build/macos-adaptation')
    output.mkdir(parents=True, exist_ok=False)
    logs = output / 'logs'
    logs.mkdir()
    source = output / 'source'
    source.mkdir()
    owner = uuid.uuid4().hex
    service = 'org.shijijs.agent-info-manage.qa.' + str(uuid.uuid4())
    identity = 'org.shijijs.agent-info-manage.qa.flutterkeychain'
    result = {'complete': False, 'baseCommit': subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'service': service, 'bundleIdentifier': identity, 'commands': [], 'cases': [],
        'scope': 'isolated Release Flutter copy; real Keychain and SQLCipher; injected failure conditions/events'}
    roots, processes = set(), []
    binary = None

    def save():
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')

    def run(label, command, cwd=source, timeout=900):
        started = time.monotonic()
        with (logs / (label + '.txt')).open('wb') as log:
            process = subprocess.Popen(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
                code = 124
        result['commands'].append({'label': label, 'command': command, 'exit': code,
                                   'seconds': round(time.monotonic() - started, 3)})
        save()
        print(label, code, flush=True)
        if code:
            raise RuntimeError(label + ' failed; inspect log')

    def launch(mode, label, root=None, executable=None):
        environment = os.environ.copy()
        environment.update(INFO_MAC_KEYCHAIN_MODE=mode, INFO_MAC_KEYCHAIN_OWNER=owner)
        if root is None:
            environment.pop('INFO_MAC_KEYCHAIN_ROOT', None)
        else:
            environment['INFO_MAC_KEYCHAIN_ROOT'] = str(root)
            (root / (mode + '-result.json')).unlink(missing_ok=True)
        log_path = logs / (label + '.txt')
        started = time.monotonic()
        with log_path.open('wb') as log:
            process = subprocess.Popen([str(executable or binary)], cwd=source, env=environment,
                                       stdout=log, stderr=subprocess.STDOUT)
        processes.append(process)
        actual = None
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            for line in log_path.read_text(errors='replace').splitlines():
                if line.startswith('MAC_KEYCHAIN_ROOT='):
                    candidate = Path(line.split('=', 1)[1])
                    if (not candidate.is_absolute() or candidate.is_symlink() or
                            not candidate.name.startswith('aim-mac-keychain-') or
                            (candidate / '.qa-owner').read_text() != owner):
                        raise RuntimeError('Foreign fixture root')
                    actual = candidate.resolve()
                    roots.add(actual)
                    break
            if actual is not None or process.poll() is not None:
                break
            time.sleep(0.05)
        if actual is None or (root is not None and actual != root):
            raise RuntimeError(label + ': no valid QA root')
        try:
            code = process.wait(timeout=max(1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
            code = 124
        report = actual / (mode + '-result.json')
        facts = json.loads(report.read_text()) if report.exists() else {}
        case = {'label': label, 'exit': code, 'seconds': round(time.monotonic() - started, 3), **facts}
        result['cases'].append(case)
        (output / (label + '.json')).write_text(json.dumps(case, indent=2) + '\n')
        save()
        print(label, code, flush=True)
        if code != 0 or facts.get('failed') or not facts.get('nativeTerminationRequested'):
            raise RuntimeError(label + ': failed or no native termination')
        if facts.get('port'):
            with socket.socket() as connection:
                connection.settimeout(1)
                if connection.connect_ex(('127.0.0.1', facts['port'])) == 0:
                    raise RuntimeError(label + ': endpoint survives native exit')
            case['portClosedAfterExit'] = True
        return actual

    try:
        names = subprocess.check_output(['git', 'ls-files', '-z', 'apps/desktop', 'packages',
                                         'scripts', 'integrations', 'third_party'], cwd=ROOT).decode().split('\0')
        names = sorted(set(filter(None, names)) | {ENTRY, INJECTION, 'scripts/qa/macos-flutter-keychain.py'})
        hashes = {}
        for name in names:
            origin = ROOT / name
            if not origin.is_file() or origin.is_symlink():
                raise RuntimeError('Unexpected source file: ' + name)
            destination = source / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(origin, destination)
            hashes[name] = digest(origin)
        result['inputSourceHashes'] = hashes
        (source / '.tools').symlink_to(ROOT / '.tools', target_is_directory=True)
        (source / '.cache').mkdir()
        (source / '.cache/pub').symlink_to(ROOT / '.cache/pub', target_is_directory=True)
        window = source / 'apps/desktop/macos/Runner/MainFlutterWindow.swift'
        text = window.read_text()
        original = 'let databaseKeys = NativeDatabaseKeyStore()'
        if text.count(original) != 1 or text.split('let backupFiles =', 1)[0].count('if call.method == "read" {') != 1:
            raise RuntimeError('Native injection anchor changed; review source')
        text = text.replace('import Cocoa\n', 'import Cocoa\nimport Security\n', 1)
        text = text.replace(original, 'let databaseKeys = NativeDatabaseKeyStore(service: "' + service + '")')
        text = text.replace('if call.method == "read" {', '''if ["qaDelete", "qaMalformed", "qaWrong"].contains(call.method) {
          try mutateOwnedKeychainFixture(call.method)
          result(nil)
        } else if call.method == "read" {''', 1)
        text += '\n' + (ROOT / INJECTION).read_text().replace('@SERVICE@', service)
        window.write_text(text)
        config = source / 'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig'
        text = config.read_text()
        original = 'PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop'
        if text.count(original) != 1:
            raise RuntimeError('Bundle identity anchor changed')
        config.write_text(text.replace(original, 'PRODUCT_BUNDLE_IDENTIFIER = ' + identity))
        result['copyModifications'] = {str(p.relative_to(source)): digest(p) for p in [window, config]}
        # Assert all copied application logic remains byte-identical except the
        # two explicit QA injection files, before any generation/build step.
        for name, expected in hashes.items():
            if name not in result['copyModifications'] and digest(source / name) != expected:
                raise RuntimeError('Unexpected copied source modification: ' + name)
        save()
        launcher = str(source / 'scripts/dev-macos.sh')
        for package in ['info_core', 'info_cli', 'info_storage']:
            run('pub-' + package, [launcher, 'dart', 'pub', 'get', '--enforce-lockfile'],
                source / 'packages' / package)
        desktop = source / 'apps/desktop'
        run('pub-desktop', [launcher, 'flutter', 'pub', 'get', '--enforce-lockfile'], desktop)
        run('analyze', [launcher, 'flutter', 'analyze', '--fatal-infos', '--no-pub'], desktop)
        run('build-release', [launcher, 'build', '--target=integration_test/macos_keychain_probe.dart'])
        app = desktop / 'build/macos/Build/Products/Release/info_desktop.app'
        binary = app / 'Contents/MacOS/info_desktop'
        run('signature', ['codesign', '--verify', '--deep', '--strict', str(app)], timeout=30)
        run('signature-details', ['codesign', '-d', '--verbose=4', '--entitlements', ':-', str(app)], timeout=30)
        result['binarySha256'] = digest(binary)
        for scenario in ['reopen', 'missing', 'malformed', 'wrong', 'corrupt']:
            root = launch('create', scenario + '-create')
            launch(scenario, scenario + '-check', root)
            launch('cleanup', scenario + '-cleanup', root)
        upgraded = output / 'Changed-Version.app'
        shutil.copytree(app, upgraded, symlinks=True)
        info = upgraded / 'Contents/Info.plist'
        data = plistlib.loads(info.read_bytes())
        data['CFBundleVersion'] = str(int(data['CFBundleVersion']) + 1)
        info.write_bytes(plistlib.dumps(data))
        run('sign-changed-version', ['codesign', '--force', '--sign', '-', '--entitlements',
            str(source / 'apps/desktop/macos/Runner/Release.entitlements'), str(upgraded)], timeout=30)
        run('signature-changed-version', ['codesign', '--verify', '--deep', '--strict', str(upgraded)], timeout=30)
        run('signature-details-changed-version', ['codesign', '-d', '--verbose=4', str(upgraded)], timeout=30)
        changed_binary = upgraded / 'Contents/MacOS/info_desktop'
        result['changedVersionBinarySha256'] = digest(changed_binary)
        if result['changedVersionBinarySha256'] == result['binarySha256']:
            raise RuntimeError('Changed version did not change code signature')
        root = launch('create', 'upgrade-create')
        launch('upgrade', 'upgrade-changed-signature', root, changed_binary)
        launch('reopen', 'upgrade-original-reopen', root)
        launch('cleanup', 'upgrade-cleanup', root)
        result['complete'] = True
    except Exception as error:
        result['failure'] = str(error)
        raise
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
                result['forcedFailureCleanup'] = True
        if binary and binary.exists():
            # Cleanup belongs to the exact same signed program that created the
            # item. Do not delete its executable or root if cleanup is refused.
            try:
                cleanup_root = next(iter(roots), None)
                launch('cleanup', 'final-owned-key-cleanup', cleanup_root)
                result['ownedKeyCleanupVerified'] = True
            except Exception as error:
                result['cleanupFailure'] = str(error)
                result['complete'] = False
        if result.get('complete') and result.get('ownedKeyCleanupVerified'):
            for root in roots:
                if not root.is_symlink() and (root / '.qa-owner').read_text() == owner:
                    shutil.rmtree(root)
            result['privateFixtureRootsRemoved'] = True
        else:
            result['retainedPrivateFixtureRoots'] = [str(root) for root in sorted(roots)]
        save()
    if not result.get('complete'):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
