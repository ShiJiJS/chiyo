from pathlib import Path
import subprocess,shutil,json
root=Path.cwd();out=Path(__file__).resolve().parent;src=out/'source';src.mkdir()
for name in subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z','apps/desktop','packages','scripts','third_party','integrations']).decode().split('\0'):
 if name:
  dest=src/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/name,dest)
(src/'.tools').symlink_to(root/'.tools',target_is_directory=True);(src/'.cache').mkdir();(src/'.cache/pub').symlink_to(root/'.cache/pub',target_is_directory=True)
p=src/'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig';p.write_text(p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop','PRODUCT_BUNDLE_IDENTIFIER = org.shijijs.agent-info-manage.qa.secretentry20261022').replace('PRODUCT_NAME = info_desktop','PRODUCT_NAME = MacSecretEntryProbe'))
entry='''import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'credential_dialogs.dart';
import 'credential_management.dart';
import 'mac_secret_input.dart';
import 'ui.dart';
import 'window_frame.dart';
void main() { WidgetsFlutterBinding.ensureInitialized(); runApp(const Probe()); }
class Probe extends StatefulWidget { const Probe({super.key}); @override State<Probe> createState() => _ProbeState(); }
class _ProbeState extends State<Probe> {
  final repository = MemoryInformationRepository();
  late final service = InformationService(repository: repository);
  final limited = TextEditingController(text: 'a');
  String summary = 'No credentials saved';
  Future<void> create() async {
    await showDialog<void>(context: context, builder: (_) => CredentialEditor(owner: service.owner));
    inspect();
  }
  Future<void> rotate() async {
    if (service.owner.credentials.isEmpty) return;
    await showDialog<void>(context: context, builder: (_) => CredentialManagement(owner: service.owner,
      credential: service.owner.credentials.single, action: 'rotate'));
    inspect();
  }
  void inspect() {
    final items = service.owner.credentials;
    final version = items.isEmpty ? 0 : items.single.version;
    final material = repository.credentialMaterials.where((m) => m.version == version).firstOrNull;
    final text = material == null ? '' : utf8.decode(material.bytes);
    debugPrint('QA_SAVED count=${items.length} version=$version createExact=${text == 'SyntheticCreate42'} rotateExact=${text == 'SyntheticRotate42'}');
    if (mounted) setState(() => summary = 'Saved credentials: ${items.length}; version: $version');
  }
  @override void dispose() { limited.dispose(); service.close(); super.dispose(); }
  @override Widget build(BuildContext context) => MaterialApp(theme: informationTheme(),
    builder: (_, child) => DesktopWindowFrame(child: child!),
    home: Builder(builder: (context) => Scaffold(body: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
      const Text('Mac secret entry acceptance — synthetic memory repository'),
      TextButton(onPressed: () async { await showDialog<void>(context: context,
        builder: (_) => CredentialEditor(owner: service.owner)); inspect(); }, child: const Text('新建合成凭据')),
      TextButton(onPressed: () async { if (service.owner.credentials.isNotEmpty) {
        await showDialog<void>(context: context, builder: (_) => CredentialManagement(owner: service.owner,
          credential: service.owner.credentials.single, action: 'rotate')); inspect();
      } }, child: const Text('轮换合成凭据')),
      MacSecretInput(controller: limited, label: '两字符边界测试', maxLength: 2),
      Text(summary),
    ])))),
  );
}
''';(src/'apps/desktop/lib/secret_form_probe.dart').write_text(entry)
# Keep only the normal product bridges. No Keychain calls or test-only native action injection.
build=(root/'build/macos-adaptation/issue48-menu-state-20261022/build.py').read_text().replace('clipboard_probe.dart','secret_form_probe.dart');(out/'build.py').write_text(build)
r=(root/'build/macos-adaptation/issue48-secure-ax-20261022/run.py').read_text();a=r.index("assert phase in");b=r.index('\nr=subprocess.run',a);r=r[:a]+"assert phase == 'fixed'\napp=out/'source/apps/desktop/build/macos/Build/Products/Release/MacSecretEntryProbe.app'\nexe=app/'Contents/MacOS/MacSecretEntryProbe'"+r[b:];(out/'run.py').write_text(r)
(out/'prepared.json').write_text(json.dumps({'sourceBase':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'scope':'Actual CredentialEditor/Management and product native editor, MemoryInformationRepository; no Bootstrap database Keychain or Agent runtime'},indent=2)+'\n')
