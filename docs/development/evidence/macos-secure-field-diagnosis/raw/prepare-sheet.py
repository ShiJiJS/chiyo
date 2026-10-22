from pathlib import Path
import shutil
out=Path(__file__).resolve().parent;src=out/'source';app=src/'apps/desktop'
for n in ['build-stages.json','build-probe.txt','analyze-probe.txt','format-probe.txt']:
 shutil.copy2(out/n,out/('embedded-semantics-'+n))
for source,name in [(app/'lib/secure_ax_probe.dart','embedded-semantics-secure_ax_probe.dart'),(app/'macos/Runner/MainFlutterWindow.swift','embedded-MainFlutterWindow.swift')]:shutil.copy2(source,out/name)
p=app/'macos/Runner/MainFlutterWindow.swift';s=Path('apps/desktop/macos/Runner/MainFlutterWindow.swift').read_text();marker='    super.awakeFromNib()';assert s.count(marker)==1
s=s.replace(marker,'''    // QA-only native sheet with synthetic values. No production registration.
    let qaSecret = FlutterMethodChannel(name: "qa/secret_sheet", binaryMessenger: flutterViewController.engine.binaryMessenger)
    qaSecret.setMethodCallHandler { [weak self] call, result in
      guard call.method == "edit", let self,
            let args = call.arguments as? [String: String], let initial = args["initial"]
      else { result(FlutterMethodNotImplemented); return }
      let alert = NSAlert()
      alert.messageText = "Edit synthetic native secret"
      alert.informativeText = "QA only. This does not access a database or Keychain."
      alert.addButton(withTitle: "Use value")
      alert.addButton(withTitle: "Cancel")
      let secure = NSSecureTextField(string: initial)
      secure.frame = NSRect(x: 0, y: 0, width: 440, height: 30)
      secure.setAccessibilityLabel("Synthetic native secret value")
      alert.accessoryView = secure
      alert.window.initialFirstResponder = secure
      alert.beginSheetModal(for: self) { response in
        if response == .alertFirstButtonReturn {
          let value = secure.stringValue
          print("QA_SHEET accepted updatedExact=\\(value == "SyntheticSheetUpdated42") length=\\(value.utf16.count)"); fflush(stdout)
          result(value)
        } else {
          print("QA_SHEET cancelled"); fflush(stdout)
          result(nil)
        }
        secure.stringValue = ""
      }
      DispatchQueue.main.async { alert.window.makeFirstResponder(secure) }
    }
'''+marker);p.write_text(s)
entry='''import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'window_frame.dart';
void main() { WidgetsFlutterBinding.ensureInitialized(); runApp(const SheetProbe()); }
class SheetProbe extends StatefulWidget {
  const SheetProbe({super.key});
  @override State<SheetProbe> createState() => _SheetProbeState();
}
class _SheetProbeState extends State<SheetProbe> {
  String secret = 'SyntheticSheet42';
  String status = 'No edit yet';
  final ordinary = TextEditingController(text: 'SyntheticPlain42');
  @override void dispose() { ordinary.dispose(); super.dispose(); }
  Future<void> edit() async {
    final before = secret;
    final result = await const MethodChannel('qa/secret_sheet').invokeMethod<String>('edit', {'initial': secret});
    if (!mounted) return;
    setState(() {
      if (result != null) secret = result;
      status = result == null ? 'Cancelled; previous value retained' : 'Native value accepted';
    });
    debugPrint('QA_SHEET_DART cancelled=${result == null} unchanged=${secret == before} updatedExact=${secret == 'SyntheticSheetUpdated42'}');
  }
  @override Widget build(BuildContext context) => MaterialApp(
    builder: (_, child) => DesktopWindowFrame(child: child!),
    home: Scaffold(body: Padding(padding: const EdgeInsets.all(32), child: Column(children: [
      const Text('Synthetic native secret sheet; no Flutter secret editor'),
      Text(secret.isEmpty ? 'Secret is empty' : 'Secret is set'),
      TextButton(onPressed: edit, child: const Text('Edit synthetic secret')),
      TextField(controller: ordinary, decoration: const InputDecoration(labelText: 'Ordinary synthetic')),
      Text(status),
    ]))),
  );
}
''';(app/'lib/secure_ax_probe.dart').write_text(entry)
p=out/'run.py';p.write_text(p.read_text().replace("'embedded']","'embedded','sheet']"))
