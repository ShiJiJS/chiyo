from pathlib import Path
import subprocess,shutil,json
root=Path.cwd();out=Path(__file__).resolve().parent;src=out/'source';src.mkdir()
for name in subprocess.check_output(['git','ls-files','-z','apps/desktop','packages','scripts','third_party','integrations']).decode().split('\0'):
 if name:
  target=src/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/name,target)
(src/'.tools').symlink_to(root/'.tools',target_is_directory=True)
(src/'.cache').mkdir();(src/'.cache/pub').symlink_to(root/'.cache/pub',target_is_directory=True)
p=src/'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig';p.write_text(p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop','PRODUCT_BUNDLE_IDENTIFIER = org.shijijs.agent-info-manage.qa.menustate20261022').replace('PRODUCT_NAME = info_desktop','PRODUCT_NAME = MacMenuStateProbe'))
old=(root/'docs/development/evidence/macos-editing-history/raw/qa-source/apps/desktop/macos/Runner/MainFlutterWindow.swift').read_text();begin=old.index('    // QA-only: preserve all original pasteboard item types in native memory.');end=old.index('    super.awakeFromNib()',begin)
p=src/'apps/desktop/macos/Runner/MainFlutterWindow.swift';s=p.read_text();p.write_text(s.replace('    super.awakeFromNib()',old[begin:end]+'    super.awakeFromNib()'))
p=src/'apps/desktop/macos/Runner/NativeTextEditingMenu.swift';s=p.read_text().replace('    let generation = menuGeneration','    print("QA_MENU begin"); fflush(stdout)\n    let generation = menuGeneration').replace('      self.editingState = state','      print("QA_MENU state \\(state)"); fflush(stdout)\n      self.editingState = state');p.write_text(s)
entry=(root/'docs/development/evidence/macos-editing-history/raw/qa-source/apps/desktop/lib/clipboard_probe.dart').read_text();entry=entry.replace("  String status = 'No clipboard changes';", "  String status = 'No clipboard changes';\n  bool readOnly = false;\n  bool obscure = false;")
entry=entry.replace('            DesktopTextField(\n              controller: editor,','            TextField(\n              controller: editor,\n              readOnly: readOnly,\n              obscureText: obscure,')
entry=entry.replace('            Text(status),', '''            TextButton(onPressed: () => setState(() => readOnly = !readOnly),
              child: Text('Toggle read-only: $readOnly')),
            TextButton(onPressed: () => setState(() => obscure = !obscure),
              child: Text('Toggle obscured: $obscure')),
            Text(status),''');(src/'apps/desktop/lib/clipboard_probe.dart').write_text(entry)
shutil.copy2(root/'build/macos-adaptation/issue48-editing-history-20261022/build.py',out/'build.py')
r=(root/'build/macos-adaptation/issue48-editing-history-20261022/run.py').read_text().replace("assert phase in ['baseline','fixed','baseline-two-states']","assert phase in ['fixed']").replace('MacHistoryProbe','MacMenuStateProbe');(out/'run.py').write_text(r)
(out/'prepared.json').write_text(json.dumps({'sourceBase':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'scope':'Minimal Release, current product native/Dart menu bridge; synthetic controller and memory-only clipboard, no bootstrap or database/Keychain. QA logs booleans only.'},indent=2)+'\n');print(src)
