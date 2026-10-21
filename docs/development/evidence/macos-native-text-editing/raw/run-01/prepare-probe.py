from pathlib import Path
import subprocess,shutil,json,hashlib
root=Path.cwd();out=root/'build/macos-adaptation/issue48-native-editing-1';src=out/'source';src.mkdir()
for name in subprocess.check_output(['git','ls-files','-z','apps/desktop','packages','scripts','third_party','integrations']).decode().split('\0'):
 if not name:continue
 p=root/name;t=src/name;t.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,t)
(src/'.tools').symlink_to(root/'.tools',target_is_directory=True);(src/'.cache').mkdir();(src/'.cache/pub').symlink_to(root/'.cache/pub',target_is_directory=True)
p=src/'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig';p.write_text(p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop','PRODUCT_BUNDLE_IDENTIFIER = org.shijijs.agent-info-manage.qa.editing20261022').replace('PRODUCT_NAME = info_desktop','PRODUCT_NAME = MacEditingProbe'))
p=src/'apps/desktop/macos/Runner/MainFlutterWindow.swift';s=p.read_text();marker='    super.awakeFromNib()';assert s.count(marker)==1
s=s.replace(marker,'''    // QA-only passive native event observation; never logs production input.
    NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
      print("QA_NATIVE_KEY type=\\(event.type.rawValue) code=\\(event.keyCode) flags=\\(event.modifierFlags.rawValue) responder=\\(String(describing: self?.firstResponder)) target=\\(String(describing: NSApp.target(forAction: NSSelectorFromString("selectAll:"))))")
      fflush(stdout)
      return event
    }
    NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
      print("QA_NATIVE_MENU responder=\\(String(describing: self?.firstResponder)) target=\\(String(describing: NSApp.target(forAction: NSSelectorFromString("selectAll:"))))")
      fflush(stdout)
    }
''' + marker);p.write_text(s)
entry=src/'apps/desktop/lib/editing_probe.dart';entry.write_text('''import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = TextEditingController();
  controller.addListener(() {
    debugPrint('QA_EDIT_VALUE text=${controller.text} selection=${controller.selection.baseOffset}:${controller.selection.extentOffset}');
  });
  HardwareKeyboard.instance.addHandler((event) {
    debugPrint('QA_DART_KEY type=${event.runtimeType} logical=${event.logicalKey.debugName} meta=${HardwareKeyboard.instance.isMetaPressed} ctrl=${HardwareKeyboard.instance.isControlPressed}');
    return false;
  });
  runApp(MaterialApp(
    theme: informationTheme(),
    home: Scaffold(body: Padding(padding: const EdgeInsets.all(40), child: Column(children: [
      const Text('Synthetic native editing probe — no library or Keychain'),
      DesktopTextField(controller: controller, decoration: const InputDecoration(labelText:'Synthetic editor')),
    ]))),
  ));
}
''')
(out/'prepared.json').write_text(json.dumps({'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'scope':'QA-only minimal DesktopTextField; passive native/Dart key and selection logs; no library, keys, server, owner API or production application mutations','source':str(src)},indent=2)+'\n')
print(src)
