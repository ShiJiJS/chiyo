import 'package:info_desktop/desktop_controls.dart';
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
  String? keyInputOverride;
  @override
  Future<String?> recoveryKeyOutput() async => '$root/recovery.txt';
  @override
  Future<String?> backupOutput() async => '$root/export.aimbackup';
  @override
  Future<String?> backupInput() async => '$root/export.aimbackup';
  @override
  Future<String?> recoveryKeyInput() async =>
      keyInputOverride ?? '$root/source-recovery.txt';
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
    'restore refreshes mounted preference controls, keeps the settings section and imports information',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late final Directory root;
      late EncryptedInformationRepository recipient;
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
        await source.backups.enable();
        await sourceService.owner.setColorTheme(DesktopColorTheme.green);
        await sourceService.owner.setRequestLifetime(
          const Duration(minutes: 5),
        );
        await sourceService.owner.setAuditRetention(180);
        await sourceService.owner.setNotificationsEnabled(false);
        await source.backups.saveRecoveryKeyTo(
          '${root.path}/source-recovery.txt',
        );
        await source.backups.exportTo('${root.path}/export.aimbackup');
        await sourceService.close();
        await source.close();
        recipient = await EncryptedInformationRepository.open(
          '${root.path}/recipient',
          _Keys(),
        );
        await File(
          '${root.path}/bad-recovery.txt',
        ).writeAsString('invalid isolated test key');
      });
      final service = InformationService(repository: recipient);
      final files = _Files(root.path)
        ..keyInputOverride = '${root.path}/bad-recovery.txt';
      final oldSession = service.agent.openSessionWithEndCapability(
        'old empty runtime',
      );
      await tester.pumpWidget(
        InformationApp(
          service: service,
          port: 47125,
          backups: recipient.backups,
          backupFiles: files,
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
      await tester.tap(find.byKey(const ValueKey('settings-section-records')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DesktopSelect<int>>(
              find.byKey(const ValueKey('timeout-30')),
            )
            .value,
        30,
      );
      expect(
        tester
            .widget<DesktopSelect<int>>(
              find.byKey(const ValueKey('retention-90')),
            )
            .value,
        90,
      );
      await tester.tap(
        find.byKey(const ValueKey('settings-section-notifications')),
      );
      await tester.pumpAndSettle();
      // Return to enabled through the visible control, leaving a mounted draft
      // that differs from the disabled preference in the source backup.
      for (var i = 0; i < 2; i++) {
        await tester.tap(
          find.byKey(const ValueKey('settings-notifications-switch')),
        );
        await _settleIO(tester, find.text('设置已保存。'));
      }
      expect(
        tester
            .widget<Semantics>(
              find.byWidgetPredicate(
                (w) => w is Semantics && w.properties.label == '访问申请通知',
              ),
            )
            .properties
            .toggled,
        isTrue,
      );
      await tester.tap(find.text('备份与恢复'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看恢复步骤'));
      await _settleIO(tester, find.text('首次启用备份'));
      await tester.tap(find.byKey(const ValueKey('backup-select-file')));
      await _settleIO(tester, find.text('export.aimbackup'));
      await tester.tap(find.byKey(const ValueKey('backup-select-key')));
      await _settleIO(tester, find.text('bad-recovery.txt'));
      await tester.tap(find.text('检查备份与恢复密钥'));
      await _settleIO(tester, find.text('操作未完成'));
      expect(find.text('export.aimbackup'), findsOneWidget);
      expect(service.owner.information, isEmpty);
      files.keyInputOverride = null;
      await tester.tap(find.byKey(const ValueKey('backup-select-key')));
      await _settleIO(tester, find.text('source-recovery.txt'));
      await tester.tap(find.text('检查备份与恢复密钥'));
      await _settleIO(tester, find.text('恢复预览'));
      expect(find.textContaining('修改版本 1 条'), findsOneWidget);
      expect(find.textContaining('授权历史 1 条，访问记录 1 条'), findsOneWidget);
      await tester.ensureVisible(find.text('确认恢复到空库'));
      await tester.tap(find.text('确认恢复到空库'));
      await _settleIO(tester, find.text('资料已恢复，请到“信息库”查看。Agent 需要重新申请访问。'));
      await tester.pumpAndSettle();
      final completedAction = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('确认恢复到空库'),
          matching: find.byType(TextButton),
        ),
      );
      expect(completedAction.onPressed, isNull);
      final disabled = {WidgetState.disabled};
      final label = completedAction.style!.foregroundColor!.resolve(disabled)!;
      final surface = completedAction.style!.backgroundColor!.resolve(
        disabled,
      )!;
      expect(
        (surface.computeLuminance() + .05) / (label.computeLuminance() + .05),
        greaterThanOrEqualTo(4.5),
        reason: 'The completed restore remains disabled with a readable label.',
      );
      expect(
        Theme.of(
          tester.element(find.text('资料已恢复，请到“信息库”查看。Agent 需要重新申请访问。')),
        ).colorScheme.primary,
        const Color(0xff296a53),
      );
      expect(
        () => service.agent.validateSession(oldSession.sessionSecret),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.agent.endSessionWithCapability(oldSession.endCapability),
        throwsA(isA<AccessFailure>()),
      );
      await tester.tap(find.text('×'));
      await tester.pumpAndSettle();
      expect(find.text('手动加密备份'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-section-records')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DesktopSelect<int>>(find.byKey(const ValueKey('timeout-5')))
            .value,
        5,
      );
      expect(
        tester
            .widget<DesktopSelect<int>>(
              find.byKey(const ValueKey('retention-180')),
            )
            .value,
        180,
      );
      await tester.tap(
        find.byKey(const ValueKey('settings-section-notifications')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Semantics>(
              find.byWidgetPredicate(
                (w) => w is Semantics && w.properties.label == '访问申请通知',
              ),
            )
            .properties
            .toggled,
        isFalse,
      );
      await tester.tap(find.text('授权历史'));
      await tester.pump(const Duration(milliseconds: 400));
      await _settleIO(tester, find.text('从备份恢复的历史记录'));
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
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
      await _settleIO(tester, find.text('导出加密备份'));
      await tester.tap(find.text('导出加密备份'));
      await _settleIO(tester, find.text('首次启用备份'));
      await tester.tap(find.text('创建恢复密钥'));
      await _settleIO(tester, find.text('保存恢复密钥文件'));
      await tester.tap(find.text('保存恢复密钥文件'));
      await _settleIO(tester, find.text('恢复密钥已另存，请与备份分开保管。'));
      expect(File('${root.path}/recovery.txt').existsSync(), isTrue);
      await tester.ensureVisible(
        find.descendant(
          of: find.byType(BackupFlowDialog),
          matching: find.text('导出加密备份'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(BackupFlowDialog),
          matching: find.text('导出加密备份'),
        ),
      );
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
