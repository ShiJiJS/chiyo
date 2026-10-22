#!/usr/bin/env python3
"""Coordinate real macOS Settings permission, native notifications and clicks.

Only a synthetic library/in-memory key. Dispatch gates trigger one real native
submission per distinct case; neither callbacks nor permission state are mocked.
Generated apps/caches and owned library files are removed after the app exits.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
ENTRY = 'apps/desktop/integration_test/macos_notifications_manual.dart'
IDENTITY = 'org.shijijs.agent-info-manage.qa.notifications20261021'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--reuse-permission', action='store_true',
                        help='Require existing system grant; no startup permission request')
    parser.add_argument('--permission-settings', action='store_true',
                        help='Check actual Settings denial/restoration without submitting notifications')
    parser.add_argument('--delivery-failure', action='store_true',
                        help='With --permission-settings, submit once after actual denial but before app refresh')
    args = parser.parse_args()
    if args.permission_settings and not args.reuse_permission:
        parser.error('--permission-settings requires --reuse-permission')
    if args.delivery_failure and not args.permission_settings:
        parser.error('--delivery-failure requires --permission-settings')
    if os.uname().sysname != 'Darwin':
        parser.error('macOS required')
    output = args.output.resolve()
    output.relative_to(ROOT / 'build/macos-adaptation')
    output.mkdir(parents=True, exist_ok=False)
    source, logs = output / 'source', output / 'logs'
    source.mkdir()
    logs.mkdir()
    owner = uuid.uuid4().hex
    state = {'complete': False, 'sourceCommit': subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'bundleIdentifier': IDENTITY, 'commands': [], 'scope': __doc__,
        'reusePermission': args.reuse_permission,
        'permissionSettings': args.permission_settings,
        'deliveryFailure': args.delivery_failure}
    app, process, root = None, None, None
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
        for name in sorted(set(filter(None, names)) | {ENTRY, 'scripts/qa/macos-notifications-ui.py'}):
            path = ROOT / name
            assert path.is_file() and not path.is_symlink()
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
            state['inputSourceHashes'][name] = digest(path)
        (source / '.tools').symlink_to(ROOT / '.tools', target_is_directory=True)
        (source / '.downloads').symlink_to(ROOT / '.downloads', target_is_directory=True)
        (source / '.cache').mkdir()
        (source / '.cache/pub').symlink_to(ROOT / '.cache/pub', target_is_directory=True)
        config = source / 'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig'
        original = 'PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop'
        assert config.read_text().count(original) == 1
        config.write_text(config.read_text().replace(original, 'PRODUCT_BUNDLE_IDENTIFIER = ' + IDENTITY))
        state['copyModifications'] = {str(config.relative_to(source)): digest(config)}
        # Observers only: preserve the native bridge's permission, presentation
        # and routing statements. No callback dispatch or notification replay.
        native = source / 'apps/desktop/macos/Runner/MainFlutterWindow.swift'
        text = native.read_text()
        observations = [
            ('    UNUserNotificationCenter.current().getNotificationSettings { settings in\n',
             '      self.qaNotificationTrace("settings", extra: ["authorization": settings.authorizationStatus.rawValue, "alert": settings.alertSetting.rawValue, "notificationCenter": settings.notificationCenterSetting.rawValue])\n'),
            ('        UNUserNotificationCenter.current().add(request) { error in\n',
             '          self.qaNotificationTrace("accepted", identifier: request.identifier, requestId: content.userInfo["requestId"] as? String ?? "", extra: ["accepted": error == nil, "errorDomain": (error as NSError?)?.domain ?? "", "errorCode": (error as NSError?)?.code ?? 0])\n'),
            ('    completionHandler([.alert])\n',
             None),
        ]
        for marker, after in observations:
            assert text.count(marker) == 1
            if after is None:
                before = '    qaNotificationTrace("willPresent", identifier: notification.request.identifier, requestId: notification.request.content.userInfo["requestId"] as? String ?? "")\n'
                text = text.replace(marker, before + marker)
            else:
                text = text.replace(marker, marker + after)
        marker = '        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)\n'
        assert text.count(marker) == 1
        text = text.replace(marker, marker + '        self.qaNotificationTrace("submit", identifier: request.identifier, requestId: content.userInfo["requestId"] as? String ?? "")\n')
        marker = '      self.desktopChannel?.invokeMethod("open", arguments: response.notification.request.content.userInfo["requestId"] as? String)\n'
        assert text.count(marker) == 1
        text = text.replace(marker, '      self.qaNotificationTrace("didReceive", identifier: response.notification.request.identifier, requestId: response.notification.request.content.userInfo["requestId"] as? String ?? "", extra: ["action": response.actionIdentifier])\n' + marker)
        helper = '''
  private func qaNotificationTrace(_ event: String, identifier: String = "", requestId: String = "", extra: [String: Any] = [:]) {
    DispatchQueue.main.async {
      var value: [String: Any] = ["event": event, "identifier": identifier, "requestId": requestId,
        "appActive": NSApp.isActive, "windowVisible": self.isVisible]
      value.merge(extra) { _, new in new }
      if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) {
        print("MAC_NOTIFICATION_NATIVE=" + line)
        fflush(stdout)
      }
    }
  }
'''
        head, tail = text.rsplit('}', 1)
        native.write_text(head + helper + '}' + tail)
        state['copyModifications'][str(native.relative_to(source))] = digest(native)
        state['nativeObserverOnly'] = True
        save()
        launcher = str(source / 'scripts/dev-macos.sh')
        for package in ['info_core', 'info_cli', 'info_storage']:
            run('pub-' + package, [launcher, 'dart', 'pub', 'get', '--enforce-lockfile'], source / 'packages' / package)
        desktop = source / 'apps/desktop'
        run('pub-desktop', [launcher, 'flutter', 'pub', 'get', '--enforce-lockfile'], desktop)
        run('analyze', [launcher, 'flutter', 'analyze', '--no-pub', '--fatal-infos', '--fatal-warnings'], desktop)
        run('build-release', [launcher, 'build', '--target=integration_test/macos_notifications_manual.dart'])
        app = desktop / 'build/macos/Build/Products/Release/info_desktop.app'
        info = app / 'Contents/Info.plist'
        data = plistlib.loads(info.read_bytes())
        data['CFBundleName'] = data['CFBundleDisplayName'] = 'Mac 通知合成验收'
        info.write_bytes(plistlib.dumps(data))
        state['qaDisplayName'] = data['CFBundleDisplayName']
        run('sign-qa-name', ['/usr/bin/codesign', '--force', '--sign', '-',
                            '--preserve-metadata=entitlements,requirements,flags,runtime', str(app)])
        run('signature', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        run('entitlements', ['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)])
        state['binarySha256'] = digest(app / 'Contents/MacOS/info_desktop')
        environment = os.environ.copy()
        environment['MAC_NOTIFICATION_OWNER'] = owner
        if args.reuse_permission:
            environment['MAC_NOTIFICATION_REUSE_PERMISSION'] = '1'
        if args.permission_settings:
            environment['MAC_NOTIFICATION_PERMISSION_SETTINGS'] = '1'
        if args.delivery_failure:
            environment['MAC_NOTIFICATION_DELIVERY_FAILURE'] = '1'
        with (logs / 'application.txt').open('wb') as log:
            process = subprocess.Popen([str(app / 'Contents/MacOS/info_desktop')], cwd=source,
                                       env=environment, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 60
        while root is None:
            found = re.findall(r'MAC_NOTIFICATION_ROOT=([^\r\n]+)', (logs / 'application.txt').read_text(errors='replace'))
            if found:
                candidate = Path(found[-1])
                assert candidate.is_absolute() and not candidate.is_symlink()
                assert candidate.name.startswith('aim-mac-notifications-') and (candidate / '.qa-owner').read_text() == owner
                root = candidate
            if root is None:
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Application root unavailable')
                time.sleep(0.1)
        fd = os.open(controller, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w') as file:
            json.dump({'root': str(root), 'owner': owner, 'pid': process.pid,
                       'app': str(app), 'bundleIdentifier': IDENTITY}, file)
        print('MAC_NOTIFICATION_UI_READY', flush=True)
        save()
        deadline = time.monotonic() + 2400
        while process.poll() is None:
            if time.monotonic() > deadline:
                raise TimeoutError('Real notification workflow deadline')
            time.sleep(0.1)
        facts = json.loads((root / 'result.json').read_text())
        state['application'] = {'exitCode': process.returncode, **facts}
        assert process.returncode == 0 and facts['complete'] and not facts.get('failed')
        assert facts['nativeTerminationRequested'] and facts['libraryCloses'] == 1 and facts['flutterErrors'] == 0
        assert len(facts['cases']) == (3 if args.delivery_failure else 2)
        if args.permission_settings:
            assert facts['submissions'] == (1 if args.delivery_failure else 0) and facts['permissionActions'] == 2
            assert facts['permissionSettingsRestored'] and facts['pendingRequestPreservedWhileDenied']
            if args.delivery_failure:
                assert facts['deliveryFailureObserved']
        else:
            assert facts['submissions'] == 2
        state['complete'] = True
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=10)
            state['forcedFailureCleanup'] = True
        if root is not None and root.exists():
            assert not root.is_symlink() and (root / '.qa-owner').read_text() == owner
            if (root / 'result.json').exists():
                shutil.copy2(root / 'result.json', output / 'last-application-result.json')
            shutil.rmtree(root)
            state['ownedFixtureRemoved'] = True
        controller.unlink(missing_ok=True)
        if app is not None and app.exists():
            result = subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(app)], capture_output=True, timeout=30)
            state['unregisterExitCode'] = result.returncode
        state['generatedArtifactsRemoved'] = []
        for tail in ['apps/desktop/build', 'apps/desktop/.dart_tool/flutter_build', 'apps/desktop/.dart_tool/hooks_runner']:
            path = source / tail
            if path.exists():
                assert not path.is_symlink() and path.resolve().is_relative_to(source)
                shutil.rmtree(path)
                state['generatedArtifactsRemoved'].append(tail)
        save()
    print(json.dumps({'complete': state['complete']}), flush=True)


if __name__ == '__main__':
    main()
