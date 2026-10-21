#!/usr/bin/env python3
"""Actual close buttons and unavailable native status item in an isolated app.

Only the copied Swift bridge gets two QA cases: set this app's own status item's
visibility, and passively read its window/item state. Production close/hide/show,
KVO, bootstrap, SQLCipher and lifecycle remain unchanged. No Keychain calls.
Private authority, databases, apps and generated debug symbols are removed.
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

ROOT = Path(__file__).resolve().parents[2]
ENTRY = 'apps/desktop/integration_test/macos_status_fallback_manual.dart'
SWIFT = 'apps/desktop/macos/Runner/MainFlutterWindow.swift'
INJECTION = '''      case "qaSetStatusVisible":
        guard let value = call.arguments as? Bool, let item = self.statusItem else {
          result(FlutterError(code: "qa_status_missing", message: nil, details: nil)); return
        }
        item.isVisible = value
        result(nil)
      case "qaObserveStatusWindow":
        result(["windowVisible": self.isVisible, "windowMiniaturized": self.isMiniaturized,
                "buttonPresent": self.statusItem?.button != nil,
                "statusVisible": self.statusItem?.isVisible == true])
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reachable(port):
    with socket.socket() as connection:
        connection.settimeout(1)
        return connection.connect_ex(('127.0.0.1', port)) == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--expect-regression', action='store_true')
    args = parser.parse_args()
    assert os.uname().sysname == 'Darwin'
    output = args.output.resolve()
    output.relative_to(ROOT / 'build/macos-adaptation')
    output.mkdir(parents=True, exist_ok=False)
    source, logs = output / 'source', output / 'logs'
    source.mkdir()
    logs.mkdir()
    owner = uuid.uuid4().hex
    identity = 'org.shijijs.agent-info-manage.qa.status-fallback.' + owner
    state = {'scope': __doc__, 'complete': False, 'expectRegression': args.expect_regression,
             'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             'bundleIdentifier': identity, 'commands': [], 'cases': [], 'processExits': [], 'inputSourceHashes': {}}
    processes = []
    app = root = None
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

    try:
        names = subprocess.check_output(['git', 'ls-files', '-z', 'apps/desktop', 'packages', 'scripts', 'integrations', 'third_party'], cwd=ROOT).decode().split('\0')
        for name in sorted(set(filter(None, names)) | {ENTRY, 'scripts/qa/macos-status-fallback-ui.py'}):
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
        swift = source / SWIFT
        anchor = '      case "initialize":\n'
        assert swift.read_text().count(anchor) == 1
        swift.write_text(swift.read_text().replace(anchor, INJECTION + anchor))
        state['copyModifications'] = {str(p.relative_to(source)): digest(p) for p in [config, swift]}
        launcher = str(source / 'scripts/dev-macos.sh')
        for package in ['info_core', 'info_cli', 'info_storage']:
            run('pub-' + package, [launcher, 'dart', 'pub', 'get', '--enforce-lockfile'], source / 'packages' / package)
        desktop = source / 'apps/desktop'
        run('pub-desktop', [launcher, 'flutter', 'pub', 'get', '--enforce-lockfile'], desktop)
        run('analyze', [launcher, 'flutter', 'analyze', '--no-pub', '--fatal-infos', '--fatal-warnings'], desktop)
        run('build', [launcher, 'build', '--target=integration_test/macos_status_fallback_manual.dart'])
        app = desktop / 'build/macos/Build/Products/Release/info_desktop.app'
        run('signature', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        run('entitlements', ['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)])
        for mode in (['close'] if args.expect_regression else ['close', 'reopen']):
            environment = {k: os.environ[k] for k in ['HOME', 'USER', 'LOGNAME', 'LANG'] if k in os.environ}
            environment.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', MAC_STATUS_MODE=mode,
                MAC_STATUS_OWNER=owner, MAC_STATUS_EXPECT_REGRESSION='1' if args.expect_regression else '0')
            if root is not None:
                environment['MAC_STATUS_ROOT'] = str(root)
            logpath = logs / (mode + '.txt')
            with logpath.open('wb') as log:
                process = subprocess.Popen([str(app / 'Contents/MacOS/info_desktop')], cwd=source,
                    env=environment, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)
            deadline = time.monotonic() + 1800
            ready = observed = False
            while process.poll() is None:
                found = re.findall(r'STATUS_FALLBACK_ROOT=([^\r\n]+)', logpath.read_text(errors='replace'))
                if found and not ready:
                    candidate = Path(found[-1])
                    assert candidate.is_absolute() and not candidate.is_symlink() and candidate.name.startswith('aim-status-fallback-')
                    assert (candidate / '.qa-owner').read_text() == owner
                    if root is not None:
                        assert candidate.resolve() == root
                    root = candidate.resolve()
                    controller.write_text(json.dumps({'mode': mode, 'pid': process.pid, 'app': str(app), 'root': str(root)}))
                    ready = True
                    state['waitingForActualUI'] = mode
                    save()
                    print('STATUS_FALLBACK_UI_READY=' + mode, flush=True)
                if root is not None and (root / (mode + '.json')).exists():
                    try:
                        current = json.loads((root / (mode + '.json')).read_text())
                    except json.JSONDecodeError:
                        current = {}
                    if current.get('complete') and not observed:
                        observed = True
                        print('STATUS_FALLBACK_FLOW_COMPLETE=' + mode, flush=True)
                assert time.monotonic() < deadline, 'Actual UI deadline'
                time.sleep(0.1)
            state['processExits'].append({'mode': mode, 'pid': process.pid, 'exitCode': process.returncode})
            save()
            facts = json.loads((root / (mode + '.json')).read_text())
            assert process.returncode == 0 and facts.get('complete') and not facts.get('failed'), facts
            assert facts['libraryCloses'] == 1 and facts['flutterErrors'] == 0
            assert not reachable(facts['port'])
            facts['portClosedAfterExit'] = True
            (output / (mode + '.json')).write_text(json.dumps(facts, ensure_ascii=False, indent=2) + '\n')
            state['cases'].append(facts)
            controller.unlink()
            state.pop('waitingForActualUI', None)
            save()
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
            for mode in ['close', 'reopen']:
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
        save()


if __name__ == '__main__':
    main()
