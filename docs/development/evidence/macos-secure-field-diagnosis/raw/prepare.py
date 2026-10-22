from pathlib import Path
import subprocess,shutil,json
root=Path.cwd();out=Path(__file__).resolve().parent;src=out/'source';src.mkdir()
for name in subprocess.check_output(['git','ls-files','-z','apps/desktop','packages','scripts','third_party','integrations']).decode().split('\0'):
 if name:
  dest=src/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/name,dest)
(src/'.tools').symlink_to(root/'.tools',target_is_directory=True);(src/'.cache').mkdir();(src/'.cache/pub').symlink_to(root/'.cache/pub',target_is_directory=True)
p=src/'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig';p.write_text(p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop','PRODUCT_BUNDLE_IDENTIFIER = org.shijijs.agent-info-manage.qa.flutterax20261022').replace('PRODUCT_NAME = info_desktop','PRODUCT_NAME = MacAXFlutterControl'))
p=src/'apps/desktop/macos/Runner/MainFlutterWindow.swift';s=p.read_text();a=s.index('    DispatchQueue.main.async { [weak self] in\n      guard let self, let menu = NSApp.mainMenu else { return }\n      let forwarding = NativeTextEditingMenu');b=s.index('\n    }',a)+len('\n    }');p.write_text(s[:a]+s[b:]);(out/'baseline-MainFlutterWindow.swift').write_text(p.read_text())
entry='''import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'window_frame.dart';

const bridgeEnabled = false;
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Probe());
}
class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}
class _ProbeState extends State<Probe> {
  final secure = TextEditingController(text: 'SyntheticSecret42');
  final plain = TextEditingController(text: 'SyntheticPlain42');
  final toggled = TextEditingController(text: 'SyntheticToggle42');
  bool obscure = false;
  String status = 'No file saved';
  @override
  void initState() {
    super.initState();
    for (final pair in [(secure, 'secure'), (plain, 'plain'), (toggled, 'toggle')]) {
      pair.$1.addListener(() {
        final value = pair.$1.value;
        debugPrint('QA_AX ${jsonEncode({
          'field': pair.$2, 'secureKnownExact': secure.text == 'SyntheticSecret42',
          'toggleKnownExact': toggled.text == 'SyntheticToggle42',
          'length': value.text.length,
          'selection': [value.selection.baseOffset, value.selection.extentOffset],
        })}');
      });
    }
  }
  Future<void> panel() async {
    const channel = MethodChannel('agent_info_manage/backup_files');
    final result = await channel.invokeMethod<String>('informationFileOutput', 'SyntheticFlutterAX.txt');
    debugPrint('QA_AX panelCancelled=${result == null}');
    if (mounted) setState(() => status = result == null ? 'Native panel cancelled' : 'Unexpected selected path');
  }
  @override
  void dispose() { secure.dispose(); plain.dispose(); toggled.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => MaterialApp(
    builder: (_, child) => bridgeEnabled ? DesktopWindowFrame(child: child!) : child!,
    home: Scaffold(body: Padding(padding: const EdgeInsets.all(32), child: Column(children: [
      Text('Synthetic Flutter AX control; menu bridge: $bridgeEnabled'),
      TextField(controller: secure, obscureText: true, enableSuggestions: false, autocorrect: false,
        decoration: const InputDecoration(labelText: 'Always obscured synthetic')),
      TextField(controller: plain, decoration: const InputDecoration(labelText: 'Ordinary synthetic')),
      TextField(controller: toggled, obscureText: obscure, enableSuggestions: false, autocorrect: false,
        decoration: const InputDecoration(labelText: 'Toggle synthetic')),
      TextButton(onPressed: () => setState(() => obscure = !obscure), child: Text('Toggle obscured: $obscure')),
      TextButton(onPressed: panel, child: const Text('Open synthetic save panel')),
      Text(status),
    ]))),
  );
}
'''
(src/'apps/desktop/lib/secure_ax_probe.dart').write_text(entry);(out/'baseline-secure_ax_probe.dart').write_text(entry)
build=(root/'build/macos-adaptation/issue48-menu-state-20261022/build.py').read_text().replace('clipboard_probe.dart','secure_ax_probe.dart');(out/'build.py').write_text(build)
(out/'prepared.json').write_text(json.dumps({'sourceBase':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'baseline':'Same pinned Flutter and TextField configuration; no DesktopWindowFrame, no installed native editing bridge','keychainCalls':0,'realUserSecrets':False},indent=2)+'\n');print(src)
