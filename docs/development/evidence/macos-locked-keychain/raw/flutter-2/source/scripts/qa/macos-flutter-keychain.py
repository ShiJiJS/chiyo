#!/usr/bin/env python3
"""Release Flutter + real Keychain + SQLCipher in a dedicated source copy.

The copy changes app identity, Keychain service, and QA-only fixture methods.
--locked-keychain additionally targets read/add queries at an owned file keychain;
all other store/adapter/startup/storage/lifetime code stays exact.
Never read/delete production Keychain items; never export keys/private fixture
associations/databases. No physical keyboard/menu or login-Keychain claim.
"""
import argparse
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--locked-keychain', action='store_true', help='Real private file-keychain lock/unlock and SQLCipher recovery; never locks login keychain')
    parser.add_argument('--owner-access', action='store_true', help='Owner recovery UI with explicitly simulated system decisions; no authorization prompt')
    parser.add_argument('--backups', action='store_true', help='Real Keychain source export, source-key loss, fresh target restore/reopen')
    args = parser.parse_args()
    if sum([args.owner_access, args.backups, args.locked_keychain]) > 1:
        parser.error('Choose one scenario')
    if sys.platform != 'darwin':
        parser.error('Requires macOS')
    output = args.output.resolve()
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
    result['scenario'] = 'locked-private-keychain' if args.locked_keychain else 'owner-access-fixtures' if args.owner_access else 'backups' if args.backups else 'keychain-failures'
    roots, processes = set(), []
    private_cleaned = set()
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
        if (code != 0 or facts.get('failed') or facts.get('flutterErrors') != 0 or
                not facts.get('nativeTerminationRequested')):
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
        names = sorted(set(filter(None, names)) | {ENTRY, INJECTION, 'scripts/qa/macos-flutter-keychain.py',
            'apps/desktop/integration_test/support/macos_keychain_backup.dart',
            'scripts/qa/macos-locked-keychain-fixture.swift'})
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
        if text.count(original) != 1 or text.split('let backupFiles =', 1)[0].count('if call.method == "read" || call.method == "readWithInteraction" {') != 1:
            raise RuntimeError('Native injection anchor changed; review source')
        text = text.replace('import Cocoa\n', 'import Cocoa\nimport Security\n', 1)
        text = text.replace(original, 'let databaseKeys = NativeDatabaseKeyStore(service: "' + service + '")')
        text = text.replace('if call.method == "read" || call.method == "readWithInteraction" {', '''if ["qaDelete", "qaMalformed", "qaWrong"].contains(call.method) {
          try mutateOwnedKeychainFixture(call.method)
          reply(nil)
        } else if call.method == "readWithInteraction",
                  let mode = ProcessInfo.processInfo.environment["INFO_MAC_KEYCHAIN_MODE"],
                  mode.hasPrefix("access-") {
          // Simulated system decisions only. Never enable Security UI in QA.
          if mode == "access-success" {
            guard let key = try databaseKeys.read() else {
              throw DatabaseKeyFailure(code: "key_unavailable", status: nil)
            }
            reply(FlutterStandardTypedData(bytes: key))
          } else {
            if mode == "access-quit" || mode == "access-close" {
              print("MAC_KEYCHAIN_SIMULATED_WAIT_STARTED")
              fflush(stdout)
              Thread.sleep(forTimeInterval: 30)
            }
            throw DatabaseKeyFailure(code: "key_unavailable", status: nil)
          }
        } else if call.method == "read" || call.method == "readWithInteraction" {''', 1)
        text += '\n' + (ROOT / INJECTION).read_text().replace('@SERVICE@', service)
        if args.locked_keychain:
            text = text.replace('import Security\n', 'import Security\nimport CryptoKit\n', 1)
            anchor = 'if ["qaDelete", "qaMalformed", "qaWrong"].contains(call.method) {'
            assert text.count(anchor) == 1
            text = text.replace(anchor, '''if call.method.hasPrefix("qaPrivate") {
          reply(try privateKeychainFixture(call.method, call.arguments))
        } else '''+anchor, 1)
            text += '\n' + (ROOT / 'scripts/qa/macos-locked-keychain-fixture.swift').read_text()
        window.write_text(text)
        config = source / 'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig'
        text = config.read_text()
        original = 'PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop'
        if text.count(original) != 1:
            raise RuntimeError('Bundle identity anchor changed')
        config.write_text(text.replace(original, 'PRODUCT_BUNDLE_IDENTIFIER = ' + identity))
        modified = [window, config]
        if args.locked_keychain:
            store = source / 'apps/desktop/macos/Runner/DatabaseKeyStore.swift'
            text = store.read_text()
            read = '      request[kSecReturnData as String] = true'
            add = '      request[kSecValueData as String] = data'
            assert text.count(read) == 1 and text.count(add) == 1
            text = text.replace(read, '      request[kSecMatchSearchList as String] = [try ownedPrivateKeychain()]\n'+read)
            text = text.replace(add, '      request[kSecUseKeychain as String] = try ownedPrivateKeychain()\n'+add)
            store.write_text(text)
            modified.append(store)
        result['copyModifications'] = {str(p.relative_to(source)): digest(p) for p in modified}
        # Assert all copied application logic remains byte-identical except the
        # explicit QA injection files, before any generation/build step.
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
        if args.locked_keychain:
            for mode in ['locked-recover', 'locked-exit']:
                root = launch(mode, mode)
                launch('locked-cleanup', mode + '-private-cleanup', root)
                if mode == 'locked-exit' and result['cases'][-1].get('lockedBeforeDelete') is not True:
                    raise RuntimeError('Private Keychain did not remain locked across normal process exit')
                private_cleaned.add(root)
        elif args.owner_access:
            root = launch('create', 'owner-access-create')
            for mode in ['access-denied', 'access-quit', 'access-close', 'access-success']:
                launch(mode, mode, root)
                case = result['cases'][-1]
                if mode in ['access-quit', 'access-close']:
                    if case['seconds'] >= 15 or 'MAC_KEYCHAIN_SIMULATED_WAIT_STARTED' not in (logs / (mode + '.txt')).read_text():
                        raise RuntimeError('Native exit did not interrupt the simulated 30-second key wait')
                    case['nativeExitBeforeSimulatedKeyWaitReturned'] = True
            launch('reopen', 'owner-access-normal-reopen', root)
        elif args.backups:
            root = launch('backup-export', 'backup-export')
            backup = root / '中文 完整备份.aimbackup'
            source_db = root / 'library/library.db'
            result['exportedBackupSha256'] = digest(backup)
            result['closedSourceDatabaseSha256'] = digest(source_db)
            launch('cleanup', 'delete-source-key', root)
            launch('missing', 'source-unavailable-before-restore', root)
            launch('backup-restore', 'new-target-restore', root)
            launch('backup-reopen', 'target-process-reopen', root)
            if (digest(backup) != result['exportedBackupSha256'] or
                    digest(source_db) != result['closedSourceDatabaseSha256']):
                raise RuntimeError('Original backup or closed source database changed')
            result['sourceDatabaseAndBackupBytesPreserved'] = True
        else:
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
            result['upgradeAccess'] = result['cases'][-1]['upgradeAccess']
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
                if args.locked_keychain:
                    for index, root in enumerate(sorted(roots)):
                        if root not in private_cleaned:
                            launch('locked-cleanup', 'final-private-cleanup-' + str(index), root)
                            private_cleaned.add(root)
                    result['ownedKeyCleanupVerified'] = bool(roots) and private_cleaned == roots
                else:
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
