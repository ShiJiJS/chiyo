import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'dart:io';
import 'package:info_desktop/main.dart';
import 'support/file_approval_fixture.dart';

void main() {
  testWidgets(
    'AWS file receipt retries only cleanup and preserves the consumed failed attempt',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = (await tester.runAsync(
        () => fileApprovalFixture('aws_shared_credentials'),
      ))!;
      final service = fixture.$1;
      addTearDown(service.close);
      final material = (await tester.runAsync(() async {
        await service.owner.decideCredentialUse(
          fixture.$3.id,
          approveCredential: true,
        );
        final material = await service.agent.consumeCredentialUse(
          fixture.$2,
          fixture.$3.id,
        );
        await service.agent.reportCredentialExecution(
          CredentialExecutionReport(
            executionId: material.executionId,
            executionCapability: material.executionCapability,
            state: 'prepare_failed',
            errorCode: 'material_prepare_failed',
            finishedAt: DateTime.now().toUtc(),
          ),
        );
        return material;
      }))!;
      addTearDown(() async {
        await service.owner.cleanupCredentialExecution(material.executionId);
      });
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      expect(find.text('AWS_SHARED_CREDENTIALS_FILE'), findsOneWidget);
      expect(find.textContaining('GH_TOKEN'), findsNothing);
      final receipt = find.text('查看执行记录 →');
      await tester.ensureVisible(receipt);
      await tester.tap(receipt);
      await tester.pumpAndSettle();
      expect(find.text('等待清理'), findsWidgets);
      final cleanup = find.text('核查并重试清理');
      expect(cleanup, findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(cleanup);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('已清理'), findsWidgets);
      expect(
        await tester.runAsync(
          () => Directory(material.materialLease!.path).exists(),
        ),
        isFalse,
      );
      expect(service.owner.credentialExecutions.single.state, 'prepare_failed');
      expect(
        service.owner.credentialUseRequests.single.attemptConsumed,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'SSH approval identifies the private file argument and confirmed host snapshot, and disables stale trust approvals',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = (await tester.runAsync(
        () => fileApprovalFixture('ssh_identity'),
      ))!;
      final service = fixture.$1;
      addTearDown(service.close);
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      expect(find.textContaining('文件 · 连接测试服务器'), findsOneWidget);
      expect(find.text('ssh 的 -i 参数'), findsOneWidget);
      expect(find.text('{{file:ssh_key}}'), findsOneWidget);
      expect(find.textContaining('GH_TOKEN'), findsNothing);
      final details = find.text('查看申请明细 ↗');
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.textContaining('StrictHostKeyChecking=yes'), findsWidgets);
      expect(find.textContaining('主机快照'), findsWidgets);
      expect(find.textContaining('SYNTHETIC_UI_KEY'), findsNothing);
      await tester.tap(find.text('返回审批'));
      await tester.pumpAndSettle();
      await tester.runAsync(service.owner.clearSshKnownHosts);
      await tester.pumpWidget(
        InformationApp(key: UniqueKey(), service: service, port: 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('已失效'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
