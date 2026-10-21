#!/usr/bin/env python3
"""Actual ordinary-app export -> native UI restore -> independent reopen/read.

Inputs must be synthetic private backup/key files in this checkout. The source
profile/Keychain is never opened by this runner or QA app. Private cached input
copies, target/reference databases and generated apps are removed afterwards.
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
ENTRY = 'apps/desktop/integration_test/macos_installed_backup_manual.dart'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--backup', type=Path, required=True)
    parser.add_argument('--recovery-file', type=Path, required=True)
    args = parser.parse_args()
    assert os.uname().sysname == 'Darwin'
    output = args.output.resolve()
    output.relative_to(ROOT / 'build/macos-adaptation')
    inputs = [args.backup.absolute(), args.recovery_file.absolute()]
    for path in inputs:
        path.relative_to(ROOT / 'local/private')
        assert path.is_file() and not path.is_symlink() and path.resolve() == path
        assert path.stat().st_mode & 0o777 == 0o600
    output.mkdir(parents=True, exist_ok=False)
    source, logs = output / 'source', output / 'logs'
    source.mkdir()
    logs.mkdir()
    owner = uuid.uuid4().hex
    identity = 'org.shijijs.agent-info-manage.qa.installed-backup.' + owner
    state = {'scope': __doc__, 'complete': False, 'bundleIdentifier': identity,
             'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             'backupBytes': inputs[0].stat().st_size, 'backupSha256': digest(inputs[0]),
             'commands': [], 'cases': [], 'processExits': [], 'inputSourceHashes': {}}
    app = root = None
    processes = []
    controller = output / 'controller.json'

    def save():
        (output / 'result.json').write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')

    def run(label, command, cwd=source):
        with (logs / (label + '.txt')).open('wb') as log:
            result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=900)
        state['commands'].append({'label': label, 'exitCode': result.returncode, 'command': command})
        save()
        print(label, result.returncode, flush=True)
        assert result.returncode == 0, label

    def report(mode):
        try:
            return json.loads((root / (mode + '.json')).read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    try:
        names = subprocess.check_output(['git', 'ls-files', '-z', 'apps/desktop', 'packages', 'scripts', 'integrations', 'third_party'], cwd=ROOT).decode().split('\0')
        for name in sorted(set(filter(None, names)) | {ENTRY, 'scripts/qa/macos-installed-backup-ui.py'}):
            path = ROOT / name
            assert path.is_file() and not path.is_symlink()
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
            state['inputSourceHashes'][name] = digest(path)
        for name in ['.tools', '.downloads']:
            (source / name).symlink_to(ROOT / name, target_is_directory=True)
        (source / '.cache').mkdir()
        (source / '.cache/pub').symlink_to(ROOT / '.cache/pub', target_is_directory=True)
        config = source / 'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig'
        old = 'PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop'
        assert config.read_text().count(old) == 1
        config.write_text(config.read_text().replace(old, 'PRODUCT_BUNDLE_IDENTIFIER = ' + identity))
        state['qaBundleConfigSha256'] = digest(config)
        launcher = str(source / 'scripts/dev-macos.sh')
        for package in ['info_core', 'info_cli', 'info_storage']:
            run('pub-' + package, [launcher, 'dart', 'pub', 'get', '--enforce-lockfile'], source / 'packages' / package)
        desktop = source / 'apps/desktop'
        run('pub-desktop', [launcher, 'flutter', 'pub', 'get', '--enforce-lockfile'], desktop)
        run('analyze', [launcher, 'flutter', 'analyze', '--no-pub', '--fatal-infos', '--fatal-warnings'], desktop)
        run('build', [launcher, 'build', '--target=integration_test/macos_installed_backup_manual.dart'])
        app = desktop / 'build/macos/Build/Products/Release/info_desktop.app'
        run('signature', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        run('entitlements', ['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)])
        for mode in ['restore', 'reopen']:
            environment = {k: os.environ[k] for k in ['HOME', 'USER', 'LOGNAME', 'LANG'] if k in os.environ}
            environment.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', MAC_INSTALLED_BACKUP_MODE=mode,
                MAC_INSTALLED_BACKUP_OWNER=owner, MAC_INSTALLED_BACKUP_FILE=str(inputs[0]),
                MAC_INSTALLED_BACKUP_KEY_FILE=str(inputs[1]))
            if root is not None:
                environment['MAC_INSTALLED_BACKUP_ROOT'] = str(root)
            logpath = logs / (mode + '.txt')
            with logpath.open('wb') as log:
                process = subprocess.Popen([str(app / 'Contents/MacOS/info_desktop')], cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)
            deadline = time.monotonic() + 1800
            ready = observed = False
            while process.poll() is None:
                found = re.findall(r'INSTALLED_BACKUP_ROOT=([^\r\n]+)', logpath.read_text(errors='replace'))
                if found and not ready:
                    candidate = Path(found[-1])
                    assert candidate.is_absolute() and not candidate.is_symlink() and candidate.name.startswith('aim-installed-backup-')
                    assert (candidate / '.qa-owner').read_text() == owner
                    if root is not None:
                        assert candidate.resolve() == root
                    root = candidate.resolve()
                    controller.write_text(json.dumps({'mode': mode, 'pid': process.pid, 'app': str(app), 'root': str(root)}))
                    ready = True
                    state['waitingForActualUI'] = mode
                    save()
                    print('INSTALLED_BACKUP_UI_READY=' + mode, flush=True)
                current = report(mode) if root is not None else None
                if current and current.get('complete') and not observed:
                    observed = True
                    print('INSTALLED_BACKUP_FLOW_PASSED=' + mode, flush=True)
                if root is not None:
                    for name in ['selected-backup.aimbackup', 'selected-recovery.txt']:
                        cached = root / name
                        if cached.exists():
                            assert cached.is_file() and not cached.is_symlink()
                            cached.chmod(0o600)
                if time.monotonic() > deadline:
                    raise TimeoutError('Actual UI deadline')
                time.sleep(0.1)
            state['processExits'].append({'mode': mode, 'pid': process.pid, 'exitCode': process.returncode})
            save()
            facts = report(mode)
            assert process.returncode == 0 and facts and facts.get('complete') and not facts.get('failed'), facts
            assert facts['libraryCloses'] == 1 and facts['flutterErrors'] == 0
            (output / (mode + '.json')).write_text(json.dumps(facts, ensure_ascii=False, indent=2) + '\n')
            state['cases'].append(facts)
            controller.unlink()
            state.pop('waitingForActualUI', None)
            assert digest(inputs[0]) == state['backupSha256']
            save()
            print('INSTALLED_BACKUP_CASE_PASSED=' + mode, flush=True)
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
        if root is not None and root.exists():
            assert not root.is_symlink() and (root / '.qa-owner').read_text() == owner
            for mode in ['restore', 'reopen']:
                if (root / (mode + '.json')).exists():
                    shutil.copy2(root / (mode + '.json'), output / ('last-' + mode + '.json'))
            shutil.rmtree(root)
        controller.unlink(missing_ok=True)
        if app is not None and app.exists():
            result = subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(app)], capture_output=True, timeout=30)
            state['unregisterExitCode'] = result.returncode
        for tail in ['apps/desktop/build', 'apps/desktop/.dart_tool/flutter_build', 'apps/desktop/.dart_tool/hooks_runner']:
            path = source / tail
            if path.exists():
                assert path.resolve().is_relative_to(source) and not path.is_symlink()
                shutil.rmtree(path)
        state['ownedPrivateTargetsAndGeneratedAppRemoved'] = (root is None or not root.exists()) and not (source / 'apps/desktop/build').exists()
        state['ordinaryBackupStillUnchanged'] = digest(inputs[0]) == state['backupSha256']
        save()


if __name__ == '__main__':
    main()
