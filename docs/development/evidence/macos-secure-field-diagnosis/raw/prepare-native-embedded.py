from pathlib import Path
import shutil
out=Path(__file__).resolve().parent;src=out/'source';app=src/'apps/desktop'
for n in ['build-stages.json','build-probe.txt','analyze-probe.txt','format-probe.txt']:
 shutil.copy2(out/n,out/('current-'+n))
shutil.copy2(app/'lib/secure_ax_probe.dart',out/'current-secure_ax_probe.dart')
shutil.copy2(app/'macos/Runner/MainFlutterWindow.swift',out/'current-MainFlutterWindow.swift')
p=app/'macos/Runner/MainFlutterWindow.swift';s=p.read_text();marker='    super.awakeFromNib()';assert s.count(marker)==1;s=s.replace(marker,'''    // QA-only AppKit platform view, synthetic fixture only.
    let qaRegistrar = flutterViewController.engine.registrar(forPlugin: "SecureAXProbe")
    qaRegistrar.register(SecureAXFactory(messenger: qaRegistrar.messenger), withId: "qa/native_secure_ax")
    let qaAX = FlutterMethodChannel(name: "qa/native_ax", binaryMessenger: qaRegistrar.messenger)
    qaAX.setMethodCallHandler { [weak self] call, result in
      guard call.method == "inspect", let self else { result(FlutterMethodNotImplemented); return }
      var info: [[String: Any]] = []
      func visit(_ view: NSView) {
        if let field = view as? NSTextField {
          let raw = field.stringValue
          let ax = field.accessibilityValue() as? String ?? ""
          info.append([
            "class": NSStringFromClass(type(of: field)),
            "nativeSecure": field is NSSecureTextField,
            "frameY": field.frame.origin.y,
            "rawKnownSecret": raw == "SyntheticSecret4Z2",
            "rawKnownToggle": raw == "SyntheticToggle42",
            "rawKnownEmbedded": raw == "SyntheticEmbedded42",
            "axKnownSecret": ax == "SyntheticSecret4Z2",
            "axKnownToggle": ax == "SyntheticToggle42",
            "axKnownEmbedded": ax == "SyntheticEmbedded42",
            "axMasked": !ax.isEmpty && ax.allSatisfy { $0 == "•" || $0 == "\\u{F79A}" }
          ])
        }
        for child in view.subviews { visit(child) }
      }
      if let view = self.contentView { visit(view) }
      if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]),
         let text = String(data: data, encoding: .utf8) { print("QA_OWN_AX " + text); fflush(stdout) }
      result(nil)
    }
'''+marker)
s+='''
// QA-only prototype. It is not installed in production.
final class SecureAXFactory: NSObject, FlutterPlatformViewFactory, NSTextFieldDelegate {
  private let messenger: FlutterBinaryMessenger
  private var channels: [ObjectIdentifier: FlutterMethodChannel] = [:]
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger; super.init() }
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let field = NSSecureTextField(string: "SyntheticEmbedded42")
    field.placeholderString = "Embedded native secure synthetic"
    field.setAccessibilityLabel("Embedded native secure synthetic")
    field.font = .systemFont(ofSize: 15)
    field.delegate = self
    let channel = FlutterMethodChannel(name: "qa/secure_view/\\(viewId)", binaryMessenger: messenger)
    channels[ObjectIdentifier(field)] = channel
    channel.setMethodCallHandler { [weak field] call, result in
      guard let field else { result(nil); return }
      guard call.method == "setSynthetic" else { result(FlutterMethodNotImplemented); return }
      field.stringValue = "SyntheticReplacement42"
      if let editor = field.currentEditor() {
        editor.string = field.stringValue
        editor.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
      }
      channel.invokeMethod("changed", arguments: field.stringValue)
      result(nil)
    }
    return field
  }
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSecureTextField,
          let channel = channels[ObjectIdentifier(field)] else { return }
    channel.invokeMethod("changed", arguments: field.stringValue)
    print("QA_EMBEDDED length=\\(field.stringValue.utf16.count)"); fflush(stdout)
  }
}
'''
p.write_text(s)
p=app/'lib/secure_ax_probe.dart';s=p.read_text().replace("  bool obscure = false;", "  bool obscure = false;\n  MethodChannel? nativeChannel;")
needle="            TextField(\n              controller: secure,"
# Insert using stable first TextField marker after formatter output.
pos=s.index('            TextField(',s.index('Widget build'))
s=s[:pos]+'''            const Text('Native NSSecureTextField embedded in Flutter'),
            SizedBox(height: 42, child: AppKitView(
              viewType: 'qa/native_secure_ax',
              onPlatformViewCreated: (id) {
                final channel = MethodChannel('qa/secure_view/$id');
                nativeChannel = channel;
                channel.setMethodCallHandler((call) async {
                  if (call.method == 'changed') {
                    final value = call.arguments as String;
                    debugPrint('QA_EMBEDDED_DART length=${value.length} replacementExact=${value == 'SyntheticReplacement42'}');
                  }
                  return null;
                });
              },
            )),
'''+s[pos:]
marker='            Text(status),';assert marker in s;s=s.replace(marker,'''            TextButton(onPressed: () async { await nativeChannel?.invokeMethod<void>('setSynthetic'); },
              child: const Text('Replace embedded with synthetic fixture')),
            TextButton(onPressed: () async { await const MethodChannel('qa/native_ax').invokeMethod<void>('inspect'); },
              child: const Text('Inspect owned native AX booleans')),
'''+marker);p.write_text(s)
p=out/'run.py';p.write_text(p.read_text().replace("['native','baseline','current']","['native','baseline','current','embedded']"))
