import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/main.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

class _Files extends BackupFilePicker {
  _Files(this.root);
  final String root;
  @override
  Future<String?> recoveryKeyOutput() async => '$root/recovery.txt';
  @override
  Future<String?> backupOutput() async => '$root/export.aimbackup';
  @override
  Future<String?> backupInput() async => '$root/export.aimbackup';
}

Future<void> _settleIO(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (target.evaluate().isNotEmpty &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      break;
    }
    if (target.evaluate().isNotEmpty &&
        find.byType(AlertDialog).evaluate().isNotEmpty) {
      break;
    }
  }
  expect(target, findsWidgets);
}

void main() {
  testWidgets(
    'restore preview imports into empty library and refreshed information tab shows data',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late final Directory root;
      late EncryptedInformationRepository recipient;
      late String key;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('backup-restore-widget-');
        final source = await EncryptedInformationRepository.open(
          '${root.path}/source',
          _Keys(),
        );
        final sourceService = InformationService(repository: source);
        final item = await sourceService.owner.createInformation(
          'Restored fictional server',
          '',
          [const FieldInput('Address', '', 'restored.invalid')],
        );
        final field = FieldRef(item.id, item.fields.single.id);
        await sourceService.owner.correctValue(field, 'restored.invalid');
        final session = sourceService.agent.openSession('Imported chat');
        final request = sourceService.agent.request(session, 'fictional read', [
          field,
        ]);
        sourceService.owner.approve(request.id, [field]);
        await sourceService.agent.read(
          sourceService.agent.claim(session, request.id).token,
          field,
        );
        key = await source.backups.enable();
        await source.backups.exportTo('${root.path}/export.aimbackup');
        await sourceService.close();
        await source.close();
        recipient = await EncryptedInformationRepository.open(
          '${root.path}/recipient',
          _Keys(),
        );
      });
      final service = InformationService(repository: recipient);
      final oldSession = service.agent.openSessionWithEndCapability(
        'old empty runtime',
      );
      await tester.pumpWidget(
        InformationApp(
          service: service,
          port: 47125,
          backups: recipient.backups,
          backupFiles: _Files(root.path),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的信息'), findsOneWidget);
      expect(find.text('请选择一条信息'), findsOneWidget);
      await tester.tap(find.text('授权历史'));
      await tester.pump(const Duration(milliseconds: 400));
      await _settleIO(tester, find.text('暂无授权历史。'));
      await tester.tap(find.byKey(const ValueKey('nav-4')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('备份与恢复'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('从备份恢复'));
      await tester.pump(const Duration(milliseconds: 400));
      await _settleIO(tester, find.text('从备份恢复'));
      await tester.ensureVisible(find.text('从备份恢复'));
      await tester.tap(find.text('从备份恢复'));
      await _settleIO(tester, find.text('输入恢复密钥'));
      await tester.enterText(find.byType(TextField), key);
      await tester.tap(find.text('检查备份'));
      await _settleIO(tester, find.text('确认恢复资料库'));
      expect(find.textContaining('修改版本 1 条'), findsOneWidget);
      expect(find.textContaining('授权历史 1 条，访问记录 1 条'), findsOneWidget);
      await tester.tap(find.text('恢复到空资料库'));
      await _settleIO(tester, find.text('资料已恢复，请到“资料库”查看。Agent 需要重新申请访问。'));
      expect(
        () => service.agent.validateSession(oldSession.sessionSecret),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.agent.endSessionWithCapability(oldSession.endCapability),
        throwsA(isA<AccessFailure>()),
      );
      await tester.tap(find.text('授权历史'));
      await tester.pump(const Duration(milliseconds: 400));
      await _settleIO(tester, find.text('从备份恢复的历史事实，不代表当前有效授权。'));
      expect(find.text('撤销授权'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      expect(find.text('Restored fictional server'), findsNWidgets(2));
      await tester.tap(find.text('Restored fictional server').first);
      await tester.pumpAndSettle();
      expect(find.text('restored.invalid'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await service.close();
      await tester.runAsync(() async {
        await recipient.close();
        await root.delete(recursive: true);
      });
    },
  );

  testWidgets(
    'owner enables backup and separately saves key before exporting',
    (tester) async {
      late final Directory root;
      EncryptedInformationRepository? repository;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('backup-widget-');
        repository = await EncryptedInformationRepository.open(
          '${root.path}/library',
          _Keys(),
        );
      });
      final files = _Files(root.path);
      final service = InformationService(repository: repository!);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BackupLibrary(
              backups: repository!.backups,
              owner: service.owner,
              files: files,
            ),
          ),
        ),
      );
      await _settleIO(tester, find.text('启用手动备份'));
      await tester.tap(find.text('启用手动备份'));
      await _settleIO(tester, find.text('请另行保存恢复密钥'));
      await tester.tap(find.text('保存恢复密钥文件'));
      await _settleIO(tester, find.text('恢复密钥已另存，请与备份分开保管。'));
      expect(File('${root.path}/recovery.txt').existsSync(), isTrue);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('导出加密备份'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出加密备份'));
      await _settleIO(tester, find.text('加密备份已导出。'));
      expect(File('${root.path}/export.aimbackup').existsSync(), isTrue);
      await tester.pumpWidget(const SizedBox());
      await service.close();
      await tester.runAsync(() async {
        await repository!.close();
        await root.delete(recursive: true);
      });
    },
  );
}
