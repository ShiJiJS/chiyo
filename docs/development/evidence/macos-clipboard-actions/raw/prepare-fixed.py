from pathlib import Path
import shutil, json, subprocess
root = Path.cwd()
out = Path(__file__).resolve().parent
src = out / 'source'
for name in ['apps/desktop/lib/mac_text_editing.dart', 'apps/desktop/macos/Runner/NativeTextEditingMenu.swift', 'apps/desktop/macos/Runner/MainFlutterWindow.swift', 'apps/desktop/macos/Runner.xcodeproj/project.pbxproj']:
    shutil.copy2(root / name, src / name)
(src / 'apps/desktop/macos/Runner/NativeSelectAllMenu.swift').unlink()
shutil.copy2(out/'runtime.txt', out/'baseline-runtime.txt')
shutil.copy2(out/'exit.json', out/'baseline-exit.json')
shutil.copy2(out/'process.json', out/'baseline-process.json')
shutil.copy2(out/'build-stages.json', out/'baseline-build-stages.json')
p = src/'apps/desktop/macos/Runner/MainFlutterWindow.swift'
s = p.read_text()
marker = '    super.awakeFromNib()'
assert s.count(marker) == 1
s = s.replace(marker, '''    // QA-only: preserve all original pasteboard item types in native memory.
    let qaClipboard = FlutterMethodChannel(name: "qa/clipboard", binaryMessenger: flutterViewController.engine.binaryMessenger)
    let pasteboard = NSPasteboard.general
    var savedItems: [[NSPasteboard.PasteboardType: Data]]?
    func restoreClipboard() {
      guard let saved = savedItems else { return }
      pasteboard.clearContents()
      let items = saved.map { types -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, data) in types { item.setData(data, forType: type) }
        return item
      }
      if !items.isEmpty { pasteboard.writeObjects(items) }
      savedItems = nil
      print("QA_CLIPBOARD restored original item types"); fflush(stdout)
    }
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in restoreClipboard() }
    qaClipboard.setMethodCallHandler { call, result in
      switch call.method {
      case "seed":
        if savedItems == nil {
          savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { values[type] = data } }
            return values
          }
        }
        pasteboard.clearContents()
        pasteboard.setString("中文 合成粘贴 Clipboard", forType: .string)
        print("QA_CLIPBOARD seeded synthetic text"); fflush(stdout)
        result(nil)
      case "restore": restoreClipboard(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
''' + marker)
p.write_text(s)
p = src/'apps/desktop/lib/clipboard_probe.dart'
s = p.read_text()
begin=s.index('  ClipboardData? previous;')
end=s.index("  String status",begin)
s=s[:begin]+"  static const clipboard = MethodChannel('qa/clipboard');\n"+s[end:]
begin=s.index('  Future<void> seed()')
end=s.index('  @override\n  void dispose()',begin)
s=s[:begin]+'''  Future<void> seed() async {
    await clipboard.invokeMethod<void>('seed');
    if (mounted) setState(() => status = 'Synthetic clipboard ready');
  }
  Future<void> restore() async {
    await clipboard.invokeMethod<void>('restore');
    if (mounted) setState(() => status = 'Previous clipboard restored');
  }
'''+s[end:]
p.write_text(s)
print('Updated QA source: production editing changes + clipboard native-memory snapshot only')
