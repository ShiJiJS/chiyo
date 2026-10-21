from pathlib import Path
import subprocess, shutil, json

root = Path.cwd()
out = Path(__file__).resolve().parent
src = out / 'source'
src.mkdir()
for name in subprocess.check_output(['git', 'ls-files', '-z', 'apps/desktop', 'packages', 'scripts', 'third_party', 'integrations']).decode().split('\0'):
    if not name:
        continue
    target = src / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / name, target)
(src / '.tools').symlink_to(root / '.tools', target_is_directory=True)
(src / '.cache').mkdir()
(src / '.cache/pub').symlink_to(root / '.cache/pub', target_is_directory=True)
p = src / 'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig'
p.write_text(p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop', 'PRODUCT_BUNDLE_IDENTIFIER = org.shijijs.agent-info-manage.qa.clipboard20261022').replace('PRODUCT_NAME = info_desktop', 'PRODUCT_NAME = MacClipboardProbe'))
(src / 'apps/desktop/lib/clipboard_probe.dart').write_text('''import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui.dart';
import 'window_frame.dart';

const fixture = '中文 合成粘贴 Clipboard';
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
  final editor = TextEditingController();
  ClipboardData? previous;
  bool captured = false;
  String status = 'No clipboard changes';
  @override
  void initState() {
    super.initState();
    editor.addListener(() {
      final value = editor.value;
      debugPrint('QA_VALUE ${jsonEncode({'length': value.text.length, 'fixtureExact': value.text == fixture, 'asciiExact': value.text == 'FlutterBaseline', 'empty': value.text.isEmpty, 'selection': [value.selection.baseOffset, value.selection.extentOffset], 'composing': [value.composing.start, value.composing.end]})}');
    });
  }
  Future<void> seed() async {
    if (!captured) {
      previous = await Clipboard.getData(Clipboard.kTextPlain);
      captured = true;
    }
    await Clipboard.setData(const ClipboardData(text: fixture));
    debugPrint('QA_CLIPBOARD seeded synthetic text');
    if (mounted) setState(() => status = 'Synthetic clipboard ready');
  }
  Future<void> restore() async {
    if (!captured) return;
    await Clipboard.setData(previous ?? const ClipboardData(text: ''));
    previous = null;
    captured = false;
    debugPrint('QA_CLIPBOARD restored previous plain text');
    if (mounted) setState(() => status = 'Previous clipboard restored');
  }
  @override
  void dispose() {
    editor.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: informationTheme(),
    builder: (context, child) => DesktopWindowFrame(child: child!),
    home: Scaffold(body: Padding(padding: const EdgeInsets.all(40), child: Column(children: [
      const Text('Synthetic clipboard probe — no library or Keychain'),
      DesktopTextField(controller: editor, decoration: const InputDecoration(labelText: 'Synthetic editor')),
      TextButton(onPressed: seed, child: const Text('Seed synthetic clipboard')),
      TextButton(onPressed: restore, child: const Text('Restore previous clipboard')),
      Text(status),
    ]))),
  );
}
''')
old = root / 'build/macos-adaptation/issue48-native-editing-1/build-probe.py'
(out / 'build.py').write_text(old.read_text().replace('editing_probe.dart', 'clipboard_probe.dart'))
(out / 'prepared.json').write_text(json.dumps({'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(), 'scope': 'QA minimal current DesktopTextField + DesktopWindowFrame; no database/bootstrap/Keychain calls; only known text equality/selection logs; original plain clipboard held in memory only until explicit restore'}, indent=2) + '\n')
print(src)
