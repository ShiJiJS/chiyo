#!/usr/bin/env python3
"""Observe CUA pointer/key delivery and compact approval layout in an owned UI.

No Keychain calls, approval callbacks, native input synthesis or SDK changes.
Memory repository and synthetic file isolate this UI diagnosis from ordinary
installed-package persistence acceptance. The app uses the ordinary binding.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
ENTRY = 'apps/desktop/integration_test/macos_compact_approval_manual.dart'
DRIVER = 'scripts/qa/macos-compact-approval-ui.py'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.relative_to(ROOT / 'build/macos-adaptation')
    output.mkdir(parents=True, exist_ok=False)
    source, logs = output / 'source', output / 'logs'
    source.mkdir()
    logs.mkdir()
    identity = 'org.shijijs.agent-info-manage.qa.compact.' + uuid.uuid4().hex
    facts = {'scope': __doc__, 'bundleIdentifier': identity,
             'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             'inputHashes': {}, 'commands': [], 'complete': False}
    process = None

    def save():
        (output / 'result.json').write_text(json.dumps(facts, indent=2) + '\n')

    def run(label, command, cwd):
        with (logs / (label + '.txt')).open('wb') as log:
            result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=900)
        facts['commands'].append({'label': label, 'command': command, 'exit': result.returncode})
        save()
        print(label, result.returncode, flush=True)
        if result.returncode:
            raise RuntimeError(label)

    try:
        names = subprocess.check_output(['git', 'ls-files', '-z', 'apps/desktop', 'packages', 'scripts', 'integrations', 'third_party'], cwd=ROOT).decode().split('\0')
        for name in sorted(set(filter(None, names)) | {ENTRY, DRIVER}):
            original = ROOT / name
            assert original.is_file() and not original.is_symlink()
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, target)
            facts['inputHashes'][name] = hashlib.sha256(original.read_bytes()).hexdigest()
        for name in ['.tools', '.downloads']:
            (source / name).symlink_to(ROOT / name, target_is_directory=True)
        (source / '.cache').mkdir()
        (source / '.cache/pub').symlink_to(ROOT / '.cache/pub', target_is_directory=True)
        config = source / 'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig'
        config.write_text(config.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop',
                                                     'PRODUCT_BUNDLE_IDENTIFIER = ' + identity))
        swift = source / 'apps/desktop/macos/Runner/MainFlutterWindow.swift'
        text = swift.read_text()
        anchor = '      case "initialize":\n'
        assert text.count(anchor) == 1
        text = text.replace(anchor, '''      case "qaSetCompactWindow":
        self.setContentSize(NSSize(width: 800, height: 600))
        result(nil)
''' + anchor)
        anchor = '    super.awakeFromNib()\n'
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '''    NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self] event in
      if let self {
        var record: [String: Any] = ["event": event.type.rawValue,
          "hasWindow": event.window != nil, "matchesOwnedWindow": event.window === self,
          "appActive": NSApp.isActive, "windowKey": self.isKeyWindow]
        if event.type == .keyDown { record["keyCode"] = event.keyCode }
        if event.type == .leftMouseDown || event.type == .scrollWheel {
          record["x"] = event.locationInWindow.x
          record["y"] = event.locationInWindow.y
        }
        if event.type == .scrollWheel { record["dy"] = event.scrollingDeltaY }
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
          FileHandle.standardOutput.write(Data(("COMPACT_NATIVE=" + json + "\\n").utf8))
        }
      }
      return event
    }
''')
        swift.write_text(text)
        for name, relative in {
            'qa-driver-source.py': DRIVER,
            'qa-entry-source.dart': ENTRY,
            'approval-source.dart': 'apps/desktop/lib/approvals.dart',
            'qa-window-source.swift': 'apps/desktop/macos/Runner/MainFlutterWindow.swift',
        }.items():
            shutil.copyfile(source / relative, output / name)
        for package in ['info_core', 'info_cli', 'info_storage']:
            run('pub-' + package, [str(ROOT / 'scripts/dev-macos.sh'), 'dart', 'pub', 'get', '--enforce-lockfile'], source / 'packages' / package)
        desktop = source / 'apps/desktop'
        run('pub-desktop', [str(ROOT / 'scripts/dev-macos.sh'), 'flutter', 'pub', 'get', '--enforce-lockfile'], desktop)
        run('analyze-entry', [str(ROOT / 'scripts/dev-macos.sh'), 'flutter', 'analyze', '--fatal-infos', '--no-pub', ENTRY.split('apps/desktop/')[1]], desktop)
        run('build-ui-release', [str(ROOT / 'scripts/dev-macos.sh'), 'flutter', 'build', 'macos', '--release', '--no-pub', '--target', ENTRY.split('apps/desktop/')[1]], desktop)
        app = desktop / 'build/macos/Build/Products/Release/info_desktop.app'
        run('strict-signature', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], source)
        env = {k: os.environ[k] for k in ['HOME', 'USER', 'LOGNAME', 'LANG'] if k in os.environ}
        env['PATH'] = '/usr/bin:/bin'
        facts['appPath'] = str(app)
        facts['environmentKeys'] = sorted(env)
        with (logs / 'app.txt').open('wb') as log:
            process = subprocess.Popen([str(app / 'Contents/MacOS/info_desktop')], cwd='/', env=env, stdout=log, stderr=subprocess.STDOUT)
            facts['pid'] = process.pid
            save()
            print('COMPACT_APP_PID', process.pid, str(app), flush=True)
            code = process.wait(timeout=2400)
        facts['exit'] = code
        facts['complete'] = code == 0
        print('COMPACT_APP_EXIT', code, flush=True)
    finally:
        if process is None or process.poll() is not None:
            app_path = facts.get('appPath')
            if app_path and Path(app_path).exists():
                unregister = subprocess.run([
                    '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                    '-u', app_path,
                ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
                facts['launchServicesUnregisterExit'] = unregister.returncode
            shutil.rmtree(source)
            facts['sourceAndGeneratedAppRemoved'] = True
        else:
            facts['sourceAndGeneratedAppRemoved'] = False
            facts['liveProcessPreserved'] = process.pid
        save()


if __name__ == '__main__':
    main()
