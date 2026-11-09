// Explicit native-panel probe. Operate the save/open dialogs with Computer
// Use, then inspect the system application's own window. No NAS or user
// profile is opened; all original content below belongs to this probe.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/workspace/owner_file_open_dispatcher.dart';
import 'package:info_desktop/workspace/owner_plugin_picker.dart';
import 'package:info_desktop/workspace/owner_workspace_plugins.dart';
import 'package:info_desktop/workspace/template_package_decoder.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_storage/macos_backup_publication.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const directory = String.fromEnvironment('CHIYO_NATIVE_FILES_DIRECTORY');
  if (!Platform.isWindows || directory.isEmpty) {
    throw StateError('Explicit Windows native files probe directory required');
  }
  testWidgets('Windows real file panels and system receiver', (tester) async {
    final root = Directory(directory);
    expect(await root.exists(), true);
    final bytes = Uint8List.fromList(
      utf8.encode(
        '知予 Windows 系统打开检查\n'
        '这是本轮开发创建的普通附件，不含个人资料。\n'
        '系统应用已收到经过身份和哈希核对的本机副本。\n',
      ),
    );
    const picker = NativeBackupFilePicker();
    const dispatcher = NativeOwnerFileOpenDispatcher();
    final driver = core.NativeInformationDeliveryFiles();
    core.InformationDeliveryLease? lease;
    final package = File('${root.path}/windows-template.json');
    await package.writeAsString(
      jsonEncode({
        'id': 'local.windows-files-check',
        'name': 'Windows 文件面板检查',
        'version': '1.0.0',
        'hostApi': 1,
        'author': 'Windows 开发检查',
        'description': '',
        'templates': [
          {
            'id': 'note',
            'name': '说明',
            'icon': 'file',
            'instructions': '',
            'fields': [
              {'key': 'body', 'label': '内容', 'type': 'text', 'required': false},
            ],
            'sections': [
              {
                'kind': 'fields',
                'title': '资料',
                'keys': ['body'],
              },
            ],
            'relations': [],
          },
        ],
      }),
      flush: true,
    );
    Future<void> status(String text) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Center(child: Text(text))),
        ),
      );
      await tester.pump();
    }

    Future<void> io(Future<void> Function() action) async {
      final completed = await tester.runAsync(() async {
        await action();
        return true;
      });
      // runAsync records native exceptions and returns null. Stop this probe
      // immediately instead of opening later panels after an earlier failure.
      expect(completed, isTrue);
    }

    try {
      await status('Windows 原生文件检查：请选择新的另存位置');
      await io(() async {
        final output = await picker.ownerFileOutput('Windows 附件检查.txt');
        expect(output, isNotNull);
        expect(
          File(
            output!,
          ).parent.absolute.path.replaceAll('\\', '/').toLowerCase(),
          root.absolute.path.replaceAll('\\', '/').toLowerCase(),
        );
        final stage = (await picker.prepareStaging(output))!;
        final captured = MacBackupPublicationFiles.captureStaging(
          stage.directory,
        );
        final source = '${captured.path}/prepared';
        MacBackupPublicationFiles.writePrivateFile(source, bytes);
        final prepared = MacBackupPublicationFiles.prepare(source, output);
        MacBackupPublicationFiles.publish(prepared);
        expect(await File(output).readAsBytes(), bytes);
        MacBackupPublicationFiles.cleanup(prepared);
        await picker.releaseStaging(stage);
      });
      await status('另存核对通过：请选择 windows-template.json');
      await io(() async {
        final selected = (await readTemplatePackage(
          const NativeTemplatePackagePicker(),
        ))!;
        expect(selected.filename, 'windows-template.json');
        final decoded = TemplatePackageDecoder().decode(
          selected.bytes,
          origin: selected.filename,
        );
        expect(decoded.id, 'local.windows-files-check');
        expect(decoded.templates.single.type.name, '说明');
      });
      await status('模板选择核对通过：即将交给 Windows 系统应用打开');
      await io(() async {
        lease = await driver.reserve('attachment.txt');
        await driver.write(lease!, bytes);
        final digest = sha256.convert(bytes).toString();
        await driver.verify(lease!, bytes.length, digest);
        const id = 'windows-real-shell-open';
        final command = 'a' * 64;
        expect(await dispatcher.status(id, command), isNull);
        expect(
          await dispatcher.open(id, command, lease!, bytes.length, digest),
          OwnerFileDispatchOutcome.opened,
        );
        expect(
          await dispatcher.status(id, command),
          OwnerFileDispatchOutcome.opened,
        );
        expect(
          await dispatcher.open(id, command, lease!, bytes.length, digest),
          OwnerFileDispatchOutcome.opened,
        );
        // Inspect and normally close the receiver window during this interval.
        await Future<void>.delayed(const Duration(seconds: 45));
        await driver.verify(lease!, bytes.length, digest);
      });
      await status('Windows 文件面板、模板解析及系统打开通道检查通过');
    } finally {
      if (lease != null) await tester.runAsync(() => driver.cleanup(lease!));
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
