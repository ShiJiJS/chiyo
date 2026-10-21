#!/usr/bin/env python3
"""Two signed Flutter hosts: actual legacy schema20 + real QA Keychain upgrade.

--prepare-only builds without launching or requesting system access. --resume
uses those exact binaries, requires real owner approval in the production
recovery UI, then checks old-reader refusal and current-process reopening.
The legacy Mac host is current native scaffolding with pinned old core/storage;
there was no released legacy Mac app. No production profile/key is accessed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[2]
LEGACY = 'dbb94ac1427b95c5a7bfee5011e414876c22c63e'
IDENTITY = 'org.shijijs.agent-info-manage.qa.schemakeychain20261021'
OLD_ENTRY = 'apps/desktop/integration_test/macos_legacy_keychain_seed.dart'
NEW_ENTRY = 'apps/desktop/integration_test/macos_schema_keychain_upgrade.dart'
HELPER = 'scripts/qa/macos-schema-upgrade-probe.dart'
DRIVER = 'scripts/qa/macos-schema-keychain.py'
INJECTION = 'scripts/qa/macos-flutter-keychain-injection.swift'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--prepare-only', action='store_true')
    modes.add_argument('--resume', action='store_true')
    modes.add_argument('--archive-prepared', action='store_true',
                       help='Archive prepared unlaunched apps and remove generated app/cache duplicates')
    modes.add_argument('--verify-prepared', action='store_true',
                       help='Restore and verify exact prepared apps, then clean them without launch or Keychain access')
    args = parser.parse_args()
    if os.uname().sysname != 'Darwin':
        parser.error('macOS required')
    out = args.output.resolve()
    out.relative_to(ROOT / 'build/macos-adaptation')
    if not (args.resume or args.archive_prepared or args.verify_prepared):
        out.mkdir(parents=True, exist_ok=False)
        (out / 'logs').mkdir()
        private = {'owner': uuid.uuid4().hex,
                   'service': 'org.shijijs.agent-info-manage.qa.schema.' + str(uuid.uuid4())}
        fd = os.open(out / 'private-controller.json', os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w') as file:
            json.dump(private, file)
        state = {'complete': False, 'prepared': False, 'commands': [], 'cases': [],
                 'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                 'legacyCommit': LEGACY, 'identity': IDENTITY, 'scope': __doc__, 'sources': {}}
    else:
        state = json.loads((out / 'result.json').read_text())
        private = json.loads((out / 'private-controller.json').read_text())
        assert state['prepared'] and not state['complete'] and not state['cases'], 'Already launched; inspect existing run before resuming'
    apps = {label: out / label / 'apps/desktop/build/macos/Build/Products/Release/info_desktop.app'
            for label in ['legacy', 'current']}
    processes = []
    root = None

    def save():
        (out / 'result.json').write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')

    def run(label, command, cwd=ROOT, timeout=900):
        with (out / 'logs' / (label + '.txt')).open('wb') as log:
            result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        state['commands'].append({'label': label, 'command': command, 'exitCode': result.returncode})
        save()
        print(label, result.returncode, flush=True)
        assert result.returncode == 0, label

    def remove_generated():
        state['removedGeneratedArtifacts'] = []
        for label in apps:
            if apps[label].exists():
                subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                                '-u', str(apps[label])], capture_output=True, timeout=30)
            for tail in ['apps/desktop/build', 'apps/desktop/.dart_tool/flutter_build', 'apps/desktop/.dart_tool/hooks_runner']:
                path = out / label / tail
                if path.exists():
                    assert not path.is_symlink() and path.resolve().is_relative_to(out)
                    shutil.rmtree(path)
                    state['removedGeneratedArtifacts'].append(label + '/' + tail)

    def launch(label, mode, case):
        nonlocal root
        app = apps[label]
        assert digest(app / 'Contents/MacOS/info_desktop') == state['sources'][label]['binarySha256']
        env = os.environ.copy()
        env.update(MAC_SCHEMA_MODE=mode, MAC_SCHEMA_OWNER=private['owner'])
        if root is not None:
            env['MAC_SCHEMA_ROOT'] = str(root)
        log_path = out / 'logs' / (case + '.txt')
        with log_path.open('wb') as log:
            process = subprocess.Popen([str(app / 'Contents/MacOS/info_desktop')], cwd=out / label,
                                       env=env, stdout=log, stderr=subprocess.STDOUT)
        processes.append(process)
        if mode == 'upgrade':
            private.update(pid=process.pid, app=str(app), root=str(root))
            (out / 'private-controller.json').write_text(json.dumps(private))
            print('MAC_SCHEMA_OWNER_UI_PID', process.pid, flush=True)
        deadline = time.monotonic() + (1860 if mode == 'upgrade' else 90)
        while root is None:
            found = re.findall(r'MAC_SCHEMA_ROOT=([^\r\n]+)', log_path.read_text(errors='replace'))
            if found:
                candidate = Path(found[-1])
                assert candidate.is_absolute() and not candidate.is_symlink()
                assert candidate.name.startswith('aim-mac-schema-keychain-')
                assert (candidate / '.qa-owner').read_text() == private['owner']
                root = candidate
            if process.poll() is not None or time.monotonic() >= deadline:
                break
            time.sleep(.1)
        assert root is not None, 'No owned synthetic root'
        code = process.wait(timeout=max(1, deadline - time.monotonic()))
        facts = json.loads((root / (mode + '-result.json')).read_text())
        state['cases'].append({'label': case, 'exitCode': code, **facts})
        save()
        print(case, code, flush=True)
        assert code == 0 and not facts.get('failed')
        assert facts['nativeTerminationRequested'] and facts['flutterErrors'] == 0
        if label == 'current':
            assert facts['complete'] and facts['keyCreates'] == 0 and facts['libraryCloses'] == 1
            with socket.socket() as s:
                s.settimeout(1)
                assert s.connect_ex(('127.0.0.1', facts['port'])) != 0
        return facts

    try:
        if not (args.resume or args.archive_prepared or args.verify_prepared):
            names = subprocess.check_output(['git', 'ls-files', '-z', 'apps/desktop', 'packages',
                                             'scripts', 'third_party', 'integrations'], cwd=ROOT).decode().split('\0')
            names = sorted(set(filter(None, names)) | {OLD_ENTRY, NEW_ENTRY, HELPER, DRIVER, INJECTION})
            for label, entry in [('legacy', OLD_ENTRY), ('current', NEW_ENTRY)]:
                source = out / label
                source.mkdir()
                inputs = {}
                for name in names:
                    origin = ROOT / name
                    assert origin.is_file() and not origin.is_symlink()
                    target = source / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(origin, target)
                    inputs[name] = digest(origin)
                if label == 'legacy':
                    for package in ['info_core', 'info_storage']:
                        shutil.rmtree(source / 'packages' / package)
                    archive = out / 'legacy-packages.zip'
                    run('legacy-source-archive', ['git', 'archive', '--format=zip', '--output', str(archive), LEGACY,
                                                  'packages/info_core', 'packages/info_storage'])
                    with zipfile.ZipFile(archive) as z:
                        for item in z.infolist():
                            (source / item.filename).resolve().relative_to(source)
                        z.extractall(source)
                    legacy_inputs = {}
                    for name in subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', LEGACY, '--',
                                                         'packages/info_core', 'packages/info_storage'], cwd=ROOT, text=True).splitlines():
                        exact = subprocess.check_output(['git', 'show', LEGACY + ':' + name], cwd=ROOT)
                        assert (source / name).read_bytes() == exact
                        legacy_inputs[name] = digest(source / name)
                    inputs = {name: value for name, value in inputs.items()
                              if not name.startswith(('packages/info_core/', 'packages/info_storage/'))}
                    inputs.update(legacy_inputs)
                (source / '.tools').symlink_to(ROOT / '.tools', target_is_directory=True)
                (source / '.cache').mkdir()
                (source / '.cache/pub').symlink_to(ROOT / '.cache/pub', target_is_directory=True)
                config = source / 'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig'
                text = config.read_text()
                anchor = 'PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop'
                assert text.count(anchor) == 1
                config.write_text(text.replace(anchor, 'PRODUCT_BUNDLE_IDENTIFIER = ' + IDENTITY))
                window = source / 'apps/desktop/macos/Runner/MainFlutterWindow.swift'
                text = window.read_text()
                anchor = 'let databaseKeys = NativeDatabaseKeyStore()'
                assert text.count(anchor) == 1
                text = text.replace('import Cocoa\n', 'import Cocoa\nimport Security\n', 1)
                text = text.replace(anchor, 'let databaseKeys = NativeDatabaseKeyStore(service: "' + private['service'] + '")')
                anchor = 'if call.method == "read" || call.method == "readWithInteraction" {'
                assert text.count(anchor) == 1
                text = text.replace(anchor, 'if call.method == "qaDelete" {\n            try mutateOwnedKeychainFixture(call.method)\n            reply(nil)\n          } else ' + anchor)
                window.write_text(text + '\n' + (ROOT / INJECTION).read_text().replace('@SERVICE@', private['service']))
                modifications = {str(p.relative_to(source)): digest(p) for p in [window, config]}
                if label == 'legacy':
                    # The seed host never runs credential operations. Its pinned
                    # old core cannot compile the current worker; no fake worker
                    # is inserted and no production build phase is changed.
                    project = source / 'apps/desktop/macos/Runner.xcodeproj/project.pbxproj'
                    text = project.read_text()
                    anchor = '\t\t\t\t9D0A7E010020000000000001 /* Bundle credential worker */,\n'
                    assert text.count(anchor) == 1
                    project.write_text(text.replace(anchor, ''))
                    modifications[str(project.relative_to(source))] = digest(project)
                state['sources'][label] = {'productionInputs': inputs, 'copyModifications': modifications,
                                           'nativeKeyStoreUnchangedSha256': digest(source / 'apps/desktop/macos/Runner/DatabaseKeyStore.swift')}
                save()
                launcher = str(source / 'scripts/dev-macos.sh')
                for package in ['info_core', 'info_storage'] + (['info_cli'] if label == 'current' else []):
                    run(label + '-pub-' + package, [launcher, 'dart', 'pub', 'get', '--enforce-lockfile', '--offline'],
                        source / 'packages' / package)
                desktop = source / 'apps/desktop'
                run(label + '-pub-desktop', [launcher, 'flutter', 'pub', 'get', '--enforce-lockfile', '--offline'], desktop)
                run(label + '-analyze', [launcher, 'flutter', 'analyze', '--no-pub', '--fatal-infos', '--fatal-warnings',
                                        str(source / entry)], desktop)
                run(label + '-build', [launcher, 'flutter', 'build', 'macos', '--release', '--no-pub',
                                      '--target=' + entry.removeprefix('apps/desktop/')], desktop)
                run(label + '-signature', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(apps[label])])
                run(label + '-signature-details', ['/usr/bin/codesign', '-d', '--verbose=4', '--entitlements', ':-', str(apps[label])])
                state['sources'][label]['binarySha256'] = digest(apps[label] / 'Contents/MacOS/info_desktop')
                save()
            assert state['sources']['legacy']['binarySha256'] != state['sources']['current']['binarySha256']
            state['prepared'] = True
            save()
        if args.prepare_only or args.archive_prepared:
            state['preparedAppArchives'] = {}
            for label, app in apps.items():
                assert digest(app / 'Contents/MacOS/info_desktop') == state['sources'][label]['binarySha256']
                archive = out / ('prepared-' + label + '.zip')
                assert not archive.exists(), 'Do not overwrite an existing prepared archive'
                run('archive-prepared-' + label, ['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)])
                state['preparedAppArchives'][label] = {'file': archive.name, 'sha256': digest(archive), 'bytes': archive.stat().st_size}
            state['preparationArchiveDriverSha256'] = digest(ROOT / DRIVER)
            remove_generated()
            state['preparedWithoutLaunchingOrKeychainAccess'] = True
            save()
            print('MAC_SCHEMA_PREPARED_NO_LAUNCH', flush=True)
            return
        state['resumeDriverSha256'] = digest(ROOT / DRIVER)
        for label, app in apps.items():
            if not app.exists():
                archive = state['preparedAppArchives'][label]
                path = out / archive['file']
                assert path.name == 'prepared-' + label + '.zip' and digest(path) == archive['sha256']
                app.parent.mkdir(parents=True, exist_ok=True)
                run('restore-prepared-' + label, ['/usr/bin/ditto', '-x', '-k', str(path), str(app.parent)])
        for label in apps:
            assert digest(apps[label] / 'Contents/MacOS/info_desktop') == state['sources'][label]['binarySha256']
            for name, expected in state['sources'][label]['productionInputs'].items():
                assert digest(out / label / name) == state['sources'][label]['copyModifications'].get(name, expected), name
            run(label + '-resume-signature', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(apps[label])])
        if args.verify_prepared:
            state['archivesRestoredAndSignaturesVerifiedWithoutLaunch'] = True
            save()
            print('MAC_SCHEMA_PREPARED_ARCHIVES_VERIFIED_NO_LAUNCH', flush=True)
            return
        seeded = launch('legacy', 'seed', 'legacy-real-keychain-schema20')
        assert seeded['fixtureResult']['schema'] == 20
        upgraded = launch('current', 'upgrade', 'current-owner-allowed-migration')
        assert upgraded['actualOwnerAccessAttempts'] >= 1
        migrated_hash = digest(root / 'library/library.db')
        launch('legacy', 'old-reader', 'legacy-refuses-upgraded-schema')
        assert digest(root / 'library/library.db') == migrated_hash
        launch('current', 'reopen', 'current-signed-process-reopen')
        launch('legacy', 'cleanup', 'original-signed-key-cleanup')
        state['ownedKeyCleanupVerified'] = True
        state['complete'] = True
    except Exception as error:
        state['failure'] = str(error)
        raise
    finally:
        if args.verify_prepared:
            remove_generated()
        if not (args.prepare_only or args.archive_prepared or args.verify_prepared) or not state.get('prepared'):
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
                    state['forcedFailureCleanup'] = True
            if root is not None and not state.get('ownedKeyCleanupVerified'):
                try:
                    launch('legacy', 'cleanup', 'failure-original-key-cleanup')
                    state['ownedKeyCleanupVerified'] = True
                except Exception as error:
                    state['cleanupFailure'] = str(error)
            if root is not None and state.get('ownedKeyCleanupVerified'):
                assert not root.is_symlink() and (root / '.qa-owner').read_text() == private['owner']
                shutil.rmtree(root)
                state['ownedFixtureRemoved'] = True
            if root is None or state.get('ownedKeyCleanupVerified'):
                remove_generated()
                (out / 'private-controller.json').unlink(missing_ok=True)
        save()
    print(json.dumps({'complete': state['complete'], 'cases': len(state['cases'])}), flush=True)


if __name__ == '__main__':
    main()
