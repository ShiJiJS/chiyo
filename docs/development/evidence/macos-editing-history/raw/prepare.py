from pathlib import Path
import subprocess,shutil,json
root=Path.cwd();out=Path(__file__).resolve().parent;src=out/'source';src.mkdir()
for name in subprocess.check_output(['git','ls-files','-z','apps/desktop','packages','scripts','third_party','integrations']).decode().split('\0'):
 if not name:continue
 target=src/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/name,target)
(src/'.tools').symlink_to(root/'.tools',target_is_directory=True)
(src/'.cache').mkdir();(src/'.cache/pub').symlink_to(root/'.cache/pub',target_is_directory=True)
previous=root/'docs/development/evidence/macos-clipboard-actions/raw'
p=src/'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig'
p.write_text(p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop','PRODUCT_BUNDLE_IDENTIFIER = org.shijijs.agent-info-manage.qa.history20261022').replace('PRODUCT_NAME = info_desktop','PRODUCT_NAME = MacHistoryProbe'))
old=(previous/'qa-source/apps/desktop/macos/Runner/MainFlutterWindow.swift').read_text()
begin=old.index('    // QA-only: preserve all original pasteboard item types in native memory.')
end=old.index('    super.awakeFromNib()',begin)
p=src/'apps/desktop/macos/Runner/MainFlutterWindow.swift'
s=p.read_text();marker='    super.awakeFromNib()';assert s.count(marker)==1
p.write_text(s.replace(marker,old[begin:end]+marker))
entry=(previous/'qa-source/apps/desktop/lib/clipboard_probe.dart').read_text().replace('Synthetic clipboard probe','Synthetic history probe')
(src/'apps/desktop/lib/clipboard_probe.dart').write_text(entry)
shutil.copy2(root/'build/macos-adaptation/issue48-clipboard-20261022/build.py',out/'build.py')
(out/'prepared.json').write_text(json.dumps({'sourceBase':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'scope':'Minimal current DesktopTextField and DesktopWindowFrame; no library, Keychain or bootstrap. Reuse audited QA memory-only all-format clipboard capture/restore; record only synthetic equality/selection.'},indent=2)+'\n')
print(src)
