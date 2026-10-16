import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/backups.dart';
import 'support/isolated_desktop.dart';

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 2400; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('isolated Windows history settings and native backup pickers', (
    tester,
  ) async {
    final fixture = await IsolatedDesktopFixture.start();
    EncryptedInformationRepository? recipient;
    InformationService? target;
    AgentServer? targetServer;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await targetServer?.close();
      await target?.close();
      await recipient?.close();
      await fixture.close();
    });
    final service = fixture.service, owner = fixture.service.owner;
    final item = owner.information.single,
        ref = FieldRef(
          owner.information.single.id,
          owner.information.single.fields.first.id,
        );
    final session = service.agent.openSession('Native history chat');
    final denied = service.agent.request(session, 'Rejected native request', [
      ref,
    ]);
    owner.deny(denied.id);
    final approved = service.agent.request(session, 'Native deployment', [ref]);
    owner.approve(approved.id, [ref]);
    final grant = service.agent.claim(session, approved.id);
    await service.agent.read(grant.token, ref);
    final pending = service.agent.request(
      session,
      'Original pending deadline',
      [ref],
    );
    final originalDeadline = owner.requests
        .firstWhere((r) => r.id == pending.id)
        .requestExpiresAt;
    await tester.pumpWidget(
      InformationApp(
        service: service,
        port: fixture.port,
        runtime: fixture.bootstrap.runtime,
        backups: fixture.bootstrap.library!.backups,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-theme-green')));
    await tester.pumpAndSettle();
    expect(owner.colorTheme, DesktopColorTheme.green);
    await tester.tap(find.byKey(const ValueKey('nav-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('请求设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeout-30')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 分钟').last);
    await tester.pumpAndSettle();
    expect(owner.requestLifetime, const Duration(minutes: 5));
    expect(
      owner.requests.firstWhere((r) => r.id == pending.id).requestExpiresAt,
      originalDeadline,
    );
    final newer = service.agent.request(session, 'New deadline', [ref]);
    expect(
      owner.requests
          .firstWhere((r) => r.id == newer.id)
          .requestExpiresAt
          .difference(
            owner.requests.firstWhere((r) => r.id == newer.id).createdAt,
          ),
      const Duration(minutes: 5),
    );
    await tester.tap(find.byKey(const ValueKey('settings-section-templates')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建模板'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('template-name')),
      'Native empty structure',
    );
    await tester.enterText(
      find.byKey(const ValueKey('template-field-name-0')),
      'Host',
    );
    await tester.tap(find.text('保存模板'));
    await tester.pumpAndSettle();
    expect(owner.templates.single.fields.single.name, 'Host');
    await tester.tap(find.byKey(const ValueKey('nav-3')));
    await tester.pumpAndSettle();
    final history = await owner.history();
    final granted = history.grants.single;
    await tester.tap(find.byKey(ValueKey('history-entry-${granted.id}')));
    await tester.pumpAndSettle();
    expect(find.text(item.name), findsOneWidget);
    expect(find.textContaining(item.fields.first.value), findsNothing);
    await tester.tap(find.text('实际访问 1'));
    await tester.pumpAndSettle();
    expect(find.text('访问允许'), findsOneWidget);
    await tester.tap(find.text('撤销授权'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认撤销'));
    await tester.pumpAndSettle();
    await expectLater(
      service.agent.read(grant.token, ref),
      throwsA(isA<AccessFailure>()),
    );
    await tester.tap(find.byKey(const ValueKey('nav-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-backups')));
    await tester.pumpAndSettle();
    await waitFor(tester, find.text('导出加密备份'));
    final keyDirectory = Directory('${fixture.root.path}/independent-key');
    await keyDirectory.create();
    final exportDirectory = Directory('${fixture.root.path}/exports');
    await exportDirectory.create();
    final keyPath = '${keyDirectory.path}/recovery.txt',
        backupPath = '${exportDirectory.path}/export.aimbackup';
    debugPrint('D4_PICKER_EXPECT_KEY=$keyPath');
    debugPrint('D4_PICKER_EXPECT_BACKUP=$backupPath');
    await tester.tap(find.text('导出加密备份'));
    await waitFor(tester, find.text('首次启用备份'));
    await tester.tap(find.text('创建恢复密钥'));
    await waitFor(tester, find.text('保存恢复密钥文件'));
    expect(
      await fixture.bootstrap.library!.backups!.recoveryKeySaved(),
      isFalse,
    );
    debugPrint('D4_PICKER_PHASE=SAVE_KEY');
    await tester.tap(find.text('保存恢复密钥文件'));
    await waitFor(tester, find.text('恢复密钥已另存，请与备份分开保管。'));
    expect(await File(keyPath).exists(), isTrue);
    debugPrint('D4_PICKER_PHASE=SAVE_BACKUP');
    await tester.tap(
      find.descendant(
        of: find.byType(BackupFlowDialog),
        matching: find.text('导出加密备份'),
      ),
    );
    await waitFor(tester, find.text('加密备份已导出。'));
    expect(await File(backupPath).exists(), isTrue);
    final keys = WindowsDatabaseKeyStore(
      '${fixture.root.path}/recipient/database-key.dpapi',
    );
    recipient = await EncryptedInformationRepository.open(
      '${fixture.root.path}/recipient',
      keys,
    );
    target = InformationService(repository: recipient);
    targetServer = await AgentServer.start(target.agent, port: 0);
    await tester.pumpWidget(
      InformationApp(
        key: const ValueKey('recipient'),
        service: target,
        port: targetServer.port,
        backups: recipient.backups,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-backups')));
    await tester.pumpAndSettle();
    await waitFor(tester, find.text('查看恢复步骤'));
    await tester.tap(find.text('查看恢复步骤'));
    await waitFor(tester, find.text('首次启用备份'));
    debugPrint('D4_PICKER_PHASE=OPEN_BACKUP');
    await tester.tap(find.byKey(const ValueKey('backup-select-file')));
    await waitFor(tester, find.text('export.aimbackup'));
    debugPrint('D4_PICKER_PHASE=OPEN_KEY');
    await tester.tap(find.byKey(const ValueKey('backup-select-key')));
    await waitFor(tester, find.text('recovery.txt'));
    await tester.tap(find.text('检查备份与恢复密钥'));
    await waitFor(tester, find.text('恢复预览'));
    expect(find.textContaining('请求记录 2 条'), findsOneWidget);
    await tester.ensureVisible(find.text('确认恢复到空库'));
    await tester.tap(find.text('确认恢复到空库'));
    await waitFor(tester, find.text('资料已恢复，请到“信息库”查看。Agent 需要重新申请访问。'));
    await tester.tap(find.text('×'));
    await tester.pumpAndSettle();
    expect(target.owner.information.single.name, item.name);
    expect(target.owner.colorTheme, DesktopColorTheme.green);
    expect(target.owner.templates.single.name, 'Native empty structure');
    expect(target.owner.requests, isEmpty);
    expect(
      (await target.owner.history()).requests.any((r) => r.id == denied.id),
      isTrue,
    );
    expect((await target.owner.history()).grants.single.restoredAt, isNotNull);
    await expectLater(
      target.agent.read(grant.token, ref),
      throwsA(isA<AccessFailure>()),
    );
    await tester.tap(find.byKey(const ValueKey('nav-3')));
    await tester.pumpAndSettle();
    expect(find.text('撤销授权'), findsNothing);
    await targetServer.close();
    targetServer = null;
    await target.close();
    target = null;
    await recipient.close();
    recipient = await EncryptedInformationRepository.open(
      '${fixture.root.path}/recipient',
      keys,
    );
    target = InformationService(repository: recipient);
    expect(
      target.owner.information.single.fields.first.value,
      item.fields.first.value,
    );
    expect(target.owner.requestLifetime, const Duration(minutes: 5));
    expect(target.owner.templates.single.fields.single.name, 'Host');
    expect(
      (await target.owner.history()).requests.every(
        (r) => r.state != AccessRequestState.pending,
      ),
      isTrue,
    );
    debugPrint(
      'D4_NATIVE_ACCEPTANCE=PASS real-pickers separate-key export restore no-live-authority DPAPI-reopen',
    );
  }, timeout: const Timeout(Duration(minutes: 15)));
}
