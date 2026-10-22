#!/usr/bin/env python3
"""Ordinary production UI with passive focus/composition and picker observations.

Isolated memory-key SQLCipher library and actual CUA keyboard/dialog actions.
Copied native additions only read current input-source ID and log picker begin/
end. Optional --diagnose-keys passively records key codes/modifiers in this test
window, Flutter's hardware-key state and incoming text-input method/selector
names through a forwarding messenger; no input-source change, UI injection,
path grants or callback substitution.
Private libraries and generated apps/debug symbols are removed afterwards.
--observe-only records actual UI activity until normal app exit; it makes no
save/reopen claim. --diagnose-accessibility-state observes system/window flags
and Flutter's semanticsEnabled without changing them. An explicit comparator
can omit only the native field-purpose adapter in the owned QA copy.
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
ENTRY = 'apps/desktop/integration_test/macos_editor_focus_manual.dart'
SWIFT = 'apps/desktop/macos/Runner/MainFlutterWindow.swift'
NATIVE_LABELS = 'apps/desktop/macos/Runner/NativeTextFieldAccessibility.swift'
INJECTION = '''      case "qaReadInputSource":
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
          result(nil); return
        }
        result(Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String)
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
    parser.add_argument('--diagnose-focus', action='store_true')
    parser.add_argument('--diagnose-keys', action='store_true')
    parser.add_argument('--diagnose-accessibility', action='store_true',
                        help='Passively record only field-purpose and geometry metadata in the QA copy')
    parser.add_argument('--diagnose-accessibility-state', action='store_true',
                        help='Read-only window/system flags, enhanced-UI notifications and Flutter semantics state')
    parser.add_argument('--observe-only', action='store_true',
                        help='Observe actual UI until normal quit; no save/reopen claim')
    parser.add_argument('--without-purpose-adapter', action='store_true',
                        help='QA comparator only: omit native field-purpose naming, keeping framework semantics')
    parser.add_argument('--expected-description', default='MacFocusSaved',
                        help='Synthetic text to save through the UI and verify after process restart')
    args = parser.parse_args()
    if args.without_purpose_adapter and not (args.observe_only and args.diagnose_accessibility_state):
        parser.error('Comparator requires --observe-only --diagnose-accessibility-state')
    if not args.expected_description or len(args.expected_description) > 4096:
        parser.error('Expected description must contain 1 to 4096 synthetic characters')
    assert os.uname().sysname == 'Darwin'
    output = args.output.resolve()
    output.relative_to(ROOT / 'build/macos-adaptation')
    output.mkdir(parents=True, exist_ok=False)
    source, logs = output / 'source', output / 'logs'
    source.mkdir()
    logs.mkdir()
    owner = uuid.uuid4().hex
    identity = 'org.shijijs.agent-info-manage.qa.editor-focus.' + owner
    state = {'scope': __doc__, 'complete': False,
             'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             'expectedSavedDescription': args.expected_description,
             'diagnoseAccessibility': args.diagnose_accessibility,
             'diagnoseAccessibilityState': args.diagnose_accessibility_state,
             'observationOnly': args.observe_only,
             'purposeAdapterDisabledInQACopy': args.without_purpose_adapter,
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
        for name in sorted(set(filter(None, names)) | {ENTRY, 'scripts/qa/macos-editor-focus-ui.py'}):
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
        text = swift.read_text().replace('import Cocoa\n', 'import Cocoa\nimport Carbon\n')
        text = text.replace(anchor, INJECTION + anchor)
        begin = text.index('      } else if call.method == "backupInput"')
        end = text.index('      } else if call.method == "informationFileOutput"', begin)
        block = text[begin:end]
        block = block.replace('        let panel = NSOpenPanel()',
            '        if call.method == "informationFileInput" { print("EDITOR_FOCUS_PANEL_BEGIN") }\n        let panel = NSOpenPanel()')
        block = block.replace('          result(response == .OK ? panel.url?.path : nil)',
            '          if call.method == "informationFileInput" { print("EDITOR_FOCUS_PANEL_END=\\(response == .OK ? "selected" : "cancelled")") }\n          result(response == .OK ? panel.url?.path : nil)')
        swift.write_text(text[:begin] + block + text[end:])
        if args.diagnose_keys:
            text = swift.read_text()
            anchor = '  private var desktopChannel: FlutterMethodChannel?\n'
            assert text.count(anchor) == 1
            text = text.replace(anchor, anchor + '  private var qaKeyMonitor: Any?\n')
            anchor = '    super.awakeFromNib()\n'
            assert text.count(anchor) == 1
            text = text.replace(anchor, anchor + '''    qaKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
      if let self, NSApp.keyWindow === self {
        var record: [String: Any] = ["event": event.type.rawValue, "keyCode": event.keyCode,
          "flags": event.modifierFlags.rawValue,
          "responder": self.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
          "marked": (self.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false]
        if event.keyCode == 48 {
          record["tabCharacters"] = event.characters.map { $0.utf16.map { Int($0) } } ?? []
        }
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
          FileHandle.standardOutput.write(Data(("EDITOR_FOCUS_NATIVE_KEY=" + json + "\\n").utf8))
        }
      }
      return event
    }
''')
            anchor = '      case "terminate":\n'
            assert text.count(anchor) == 1
            text = text.replace(anchor, anchor + '''        if let monitor = self.qaKeyMonitor { NSEvent.removeMonitor(monitor) }
        self.qaKeyMonitor = nil
''')
            swift.write_text(text)
        modified = [config, swift]
        if args.without_purpose_adapter:
            text = swift.read_text()
            init = '    textFieldAccessibility = NativeTextFieldAccessibility(view: flutterViewController.view)\n'
            assert text.count(init) == 1
            text = text.replace(init, '    // QA comparator: no native field-purpose adapter.\n')
            start = text.index('    accessibility.setMethodCallHandler {')
            end = text.index('\n    // Local, owner-process-only bridge;', start)
            text = text[:start] + '''    accessibility.setMethodCallHandler { call, result in
      guard call.method == "update" else { result(FlutterMethodNotImplemented); return }
      result(nil)
    }
''' + text[end:]
            swift.write_text(text)
        if args.diagnose_accessibility_state:
            text = swift.read_text()
            anchor = '  override func awakeFromNib() {\n'
            assert text.count(anchor) == 1
            text = text.replace(anchor, '''  private var qaStateTimer: Timer?
  private var qaEnhancedObserver: Any?
  private var qaLastEnhanced: Bool?
  private var qaEnhancedEvents = 0
  private var qaLastAccessibilityState = ""
  private func qaRecordAccessibilityState() {
    let data: [String: Any] = [
      "active": NSApp.isActive, "keyWindow": isKeyWindow, "visible": isVisible,
      "voiceOver": NSWorkspace.shared.isVoiceOverEnabled,
      "enhancedLast": qaLastEnhanced.map { $0 as Any } ?? NSNull(),
      "enhancedEvents": qaEnhancedEvents
    ]
    if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
       let json = String(data: bytes, encoding: .utf8), json != qaLastAccessibilityState {
      qaLastAccessibilityState = json
      var payload = data
      payload["observedAtEpochSeconds"] = Date().timeIntervalSince1970
      if let bytes = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
         let record = String(data: bytes, encoding: .utf8) {
        FileHandle.standardOutput.write(Data(("QA_ACCESSIBILITY_STATE=" + record + "\\n").utf8))
      }
    }
  }
''' + anchor)
            anchor = '    super.awakeFromNib()\n'
            assert text.count(anchor) == 1
            text = text.replace(anchor, anchor + '''    // Observe the same status notification used by the pinned Flutter engine;
    // never post it, toggle semantics, activate a window or change permissions.
    qaEnhancedObserver = NotificationCenter.default.addObserver(
      forName: NSNotification.Name("NSApplicationDidChangeAccessibilityEnhancedUserInterfaceNotification"),
      object: nil, queue: .main) { [weak self] notification in
        guard let self else { return }
        self.qaLastEnhanced = notification.userInfo?["AXEnhancedUserInterface"] as? Bool
        self.qaEnhancedEvents += 1
        self.qaRecordAccessibilityState()
      }
    qaStateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      self?.qaRecordAccessibilityState()
    }
''')
            anchor = '      case "terminate":\n'
            assert text.count(anchor) == 1
            text = text.replace(anchor, anchor + '''        self.qaStateTimer?.invalidate()
        self.qaStateTimer = nil
        if let observer = self.qaEnhancedObserver { NotificationCenter.default.removeObserver(observer) }
        self.qaEnhancedObserver = nil
''')
            swift.write_text(text)
        if args.diagnose_accessibility:
            labels = source / NATIVE_LABELS
            text = labels.read_text()
            anchor = '  private var timer: Timer?\n'
            assert text.count(anchor) == 1
            text = text.replace(anchor, anchor + '  private var qaLastGeometry = ""\n')
            anchor = '    visit(view)\n'
            assert text.count(anchor) == 1
            text = text.replace(anchor, anchor + '''    if ProcessInfo.processInfo.environment["MAC_FOCUS_DIAGNOSE_A11Y"] == "1" {
      func rect(_ value: NSRect) -> [Double] { [value.minX, value.minY, value.width, value.height] }
      let data: [String: Any] = [
        "viewBounds": rect(view.bounds), "viewFlipped": view.isFlipped,
        "labels": labels.map { ["label": $0.name, "rect": rect($0.rect)] },
        "fields": fields.map { field -> [String: Any] in
          let live = field.superview.map { window.convertToScreen($0.convert(field.frame, to: nil)) } ?? .zero
          return ["label": field.accessibilityLabel() ?? "", "viewFrame": rect(field.frame),
                  "liveScreenFrame": rect(live), "axScreenFrame": rect(field.accessibilityFrame())]
        }
      ]
      if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
         let json = String(data: bytes, encoding: .utf8), json != qaLastGeometry {
        qaLastGeometry = json
        FileHandle.standardOutput.write(Data(("NATIVE_FIELD_GEOMETRY=" + json + "\\n").utf8))
      }
    }
''')
            labels.write_text(text)
            modified.append(labels)
        if args.diagnose_focus:
            editor = source / 'apps/desktop/lib/information_editor.dart'
            text = editor.read_text()
            needle = '    final previousFocus = FocusManager.instance.primaryFocus;\n    await _fileAction'
            assert text.count(needle) == 1
            text = text.replace(needle, '    final previousFocus = FocusManager.instance.primaryFocus;\n    debugPrint("EDITOR_FOCUS_CHOOSE=${identityHashCode(previousFocus)};${previousFocus?.debugLabel};can=${previousFocus?.canRequestFocus};context=${previousFocus?.context?.mounted}");\n    await _fileAction')
            needle = '    WidgetsBinding.instance.addPostFrameCallback((_) {\n      if (mounted &&'
            assert text.count(needle) == 1
            text = text.replace(needle, '    WidgetsBinding.instance.addPostFrameCallback((_) {\n      debugPrint("EDITOR_FOCUS_RESTORE=${identityHashCode(previous)};${previous.debugLabel};can=${previous.canRequestFocus};context=${previous.context?.mounted};route=${ModalRoute.of(context)?.isCurrent};before=${identityHashCode(FocusManager.instance.primaryFocus)}");\n      if (mounted &&')
            editor.write_text(text)
            modified.append(editor)
        state['copyModifications'] = {str(p.relative_to(source)): digest(p) for p in modified}
        launcher = str(source / 'scripts/dev-macos.sh')
        for package in ['info_core', 'info_cli', 'info_storage']:
            run('pub-' + package, [launcher, 'dart', 'pub', 'get', '--enforce-lockfile'], source / 'packages' / package)
        desktop = source / 'apps/desktop'
        run('pub-desktop', [launcher, 'flutter', 'pub', 'get', '--enforce-lockfile'], desktop)
        run('analyze', [launcher, 'flutter', 'analyze', '--no-pub', '--fatal-infos', '--fatal-warnings'], desktop)
        run('build', [launcher, 'build', '--target=integration_test/macos_editor_focus_manual.dart'])
        app = desktop / 'build/macos/Build/Products/Release/info_desktop.app'
        run('signature', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        run('entitlements', ['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)])
        for mode in (['edit'] if args.observe_only else ['edit', 'reopen']):
            environment = {k: os.environ[k] for k in ['HOME', 'USER', 'LOGNAME', 'LANG'] if k in os.environ}
            environment.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', MAC_FOCUS_MODE=mode, MAC_FOCUS_OWNER=owner,
                               MAC_FOCUS_EXPECTED_DESCRIPTION=args.expected_description)
            if args.diagnose_keys:
                environment['MAC_FOCUS_DIAGNOSE_KEYS'] = '1'
            if args.diagnose_accessibility:
                environment['MAC_FOCUS_DIAGNOSE_A11Y'] = '1'
            if args.diagnose_accessibility_state:
                environment['MAC_FOCUS_DIAGNOSE_A11Y_STATE'] = '1'
            if args.observe_only:
                environment['MAC_FOCUS_OBSERVATION_ONLY'] = '1'
            if root is not None:
                environment['MAC_FOCUS_ROOT'] = str(root)
            logpath = logs / (mode + '.txt')
            with logpath.open('wb') as log:
                process = subprocess.Popen([str(app / 'Contents/MacOS/info_desktop')], cwd=source,
                    env=environment, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)
            deadline = time.monotonic() + 1800
            ready = observed = False
            while process.poll() is None:
                found = re.findall(r'EDITOR_FOCUS_ROOT=([^\r\n]+)', logpath.read_text(errors='replace'))
                if found and not ready:
                    candidate = Path(found[-1])
                    assert candidate.is_absolute() and not candidate.is_symlink() and candidate.name.startswith('aim-editor-focus-')
                    assert (candidate / '.qa-owner').read_text() == owner
                    if root is not None:
                        assert candidate.resolve() == root
                    root = candidate.resolve()
                    controller.write_text(json.dumps({'mode': mode, 'pid': process.pid, 'app': str(app), 'root': str(root)}))
                    ready = True
                    state['waitingForActualUI'] = mode
                    save()
                    print('EDITOR_FOCUS_UI_READY=' + mode, flush=True)
                if root is not None and (root / (mode + '.json')).exists():
                    try:
                        current = json.loads((root / (mode + '.json')).read_text())
                    except json.JSONDecodeError:
                        current = {}
                    if current.get('complete') and not observed:
                        observed = True
                        print('EDITOR_FOCUS_FLOW_COMPLETE=' + mode, flush=True)
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
            for mode in ['edit', 'reopen']:
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
