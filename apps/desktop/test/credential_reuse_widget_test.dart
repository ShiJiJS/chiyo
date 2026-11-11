import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/credential_operations.dart';
import 'package:info_desktop/credential_use_approval.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/prototype_dialog.dart';
import 'package:info_desktop/ui.dart';
import 'credential_use_widget_test.dart' show fixture;

CredentialOperationInput operation(
  CredentialUseRequest r,
  String id,
  String repository,
) => CredentialOperationInput.fromJson({
  'protocolVersion': 2,
  'command': 'run-use',
  'requestId': r.id,
  'operationId': id,
  'launch': {
    ...r.toRequestInputJson()['launch'] as Map<String, Object?>,
    'argv': ['repo', 'view', repository],
  },
});

void viewport(WidgetTester tester, {double scale = 1}) {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  testWidgets(
    'v2 approval displays reusable scope and defaults independent fields to two hours',
    (tester) async {
      viewport(tester);
      final (service, session, request) = (await tester.runAsync(
        () => fixture(protocolVersion: 2),
      ))!;
      addTearDown(service.close);
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      expect(find.text('批准期限内使用'), findsOneWidget);
      expect(find.text('连接字段读取期限（独立）'), findsOneWidget);
      expect(find.text('2 小时'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('credential-use-approve')));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 小时内可重复使用'), findsOneWidget);
      expect(find.textContaining('2 小时（独立许可）'), findsOneWidget);
      await tester.ensureVisible(find.text('确认批准'));
      await tester.tap(find.text('确认批准'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      final r = service.owner.credentialUseRequests.single;
      expect(
        r.credentialExpiresAt!.difference(r.decidedAt!),
        const Duration(hours: 2),
      );
      expect(
        r.fieldExpiresAt!.difference(r.decidedAt!),
        const Duration(hours: 2),
      );
      expect(service.agent.claim(session, request.id).fields, request.fields);
      expect(find.text('使用授权有效 · 可重复使用'), findsOneWidget);
      expect(find.textContaining('仅一次，绑定'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'independent field lifetime selection reaches the owner decision without shortening credential scope',
    (tester) async {
      viewport(tester);
      final (service, _, request) = (await tester.runAsync(
        () => fixture(protocolVersion: 2),
      ))!;
      addTearDown(service.close);
      final draft = CredentialUseApprovalDraft(request.fields)..minutes = 240;
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(
            body: CredentialUseApprovalPanel(
              owner: service.owner,
              request: request,
              draft: draft,
              onChanged: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('credential-field-lifetime')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 小时').last);
      await tester.pumpAndSettle();
      expect(draft.fieldMinutes, 120);
      await tester.ensureVisible(
        find.byKey(const ValueKey('credential-use-approve')),
      );
      await tester.tap(find.byKey(const ValueKey('credential-use-approve')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认批准'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      final r = service.owner.credentialUseRequests.single;
      expect(
        r.credentialExpiresAt!.difference(r.decidedAt!),
        const Duration(hours: 4),
      );
      expect(
        r.fieldExpiresAt!.difference(r.decidedAt!),
        const Duration(hours: 2),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'v2 history separates field authorization and shows each frozen command, not only latest execution',
    (tester) async {
      viewport(tester);
      await tester.runAsync(() async {
        final (service, session, request) = await fixture(protocolVersion: 2);
        try {
          await service.owner.decideCredentialUse(
            request.id,
            approveCredential: true,
            fields: request.fields,
          );
          final first = await service.agent.beginCredentialUseOperation(
            session,
            operation(request, 'OP-01', 'northstar/first'),
          );
          final second = await service.agent.beginCredentialUseOperation(
            session,
            operation(request, 'OP-02', 'northstar/second'),
          );
          await service.agent.reportCredentialExecution(
            CredentialExecutionReport(
              executionId: second.execution.id,
              executionCapability: second.material!.executionCapability,
              state: 'start_failed',
              errorCode: 'process_start_failed',
              finishedAt: DateTime.now().toUtc(),
            ),
          );
          await tester.pumpWidget(InformationApp(service: service, port: 0));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('nav-3')));
          await tester.pumpAndSettle();
          expect(find.text('2 条记录'), findsOneWidget);
          await tester.tap(find.byKey(ValueKey('history-entry-${request.id}')));
          await tester.pumpAndSettle();
          expect(find.text('使用操作'), findsOneWidget);
          expect(find.text('OP-01'), findsOneWidget);
          expect(find.text('OP-02'), findsWidgets);
          expect(find.textContaining('northstar/second'), findsOneWidget);
          expect(find.textContaining('synthetic-token'), findsNothing);
          await tester.ensureVisible(
            find.byKey(ValueKey('use-operation-${first.execution.id}')),
          );
          await tester.tap(
            find.byKey(ValueKey('use-operation-${first.execution.id}')),
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('northstar/first'), findsOneWidget);
          expect(find.textContaining('northstar/second'), findsNothing);
          final receipt = find.text('查看本次执行记录与清理 →');
          await tester.ensureVisible(receipt);
          await tester.tap(receipt);
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: find.byType(PrototypeDialog),
              matching: find.text(first.execution.id),
            ),
            findsOneWidget,
          );
          expect(
            find.text(first.execution.operationPlan!.planHash),
            findsWidgets,
          );
          expect(find.textContaining('northstar/first'), findsWidgets);
          expect(find.textContaining('northstar/docs'), findsNothing);
          Navigator.of(tester.element(find.byType(PrototypeDialog))).pop();
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('撤销使用授权'));
          await tester.tap(find.text('撤销使用授权'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('确认撤销'));
          await tester.pumpAndSettle();
          expect(
            service.owner.credentialGrantState(
              service.owner.credentialUseRequests.single,
            ),
            'revoked',
          );
          expect(
            service.owner.credentialFieldGrantState(
              service.owner.credentialUseRequests.single,
            ),
            'available',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await service.close();
        }
      });
    },
  );

  testWidgets(
    'operation pagination and selection survive reports at 200 percent text',
    (tester) async {
      viewport(tester, scale: 2);
      final (service, session, request) = (await tester.runAsync(
        () => fixture(protocolVersion: 2),
      ))!;
      addTearDown(service.close);
      late CredentialOperationClaim firstClaim;
      await tester.runAsync(() async {
        await service.owner.decideCredentialUse(
          request.id,
          approveCredential: true,
        );
        for (var i = 1; i <= 7; i++) {
          final claim = await service.agent.beginCredentialUseOperation(
            session,
            operation(request, 'operation-$i', 'northstar/repo-$i'),
          );
          if (i == 1) firstClaim = claim;
        }
      });
      Widget screen() => MaterialApp(
        theme: informationTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: CredentialUseOperations(
                owner: service.owner,
                request: service.owner.credentialUseRequests.single,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('上一页操作'));
      await tester.tap(find.byTooltip('上一页操作'));
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      final first = service.owner.credentialExecutions.firstWhere(
        (e) => e.operationId == 'operation-1',
      );
      await tester.ensureVisible(
        find.byKey(ValueKey('use-operation-${first.id}')),
      );
      await tester.tap(find.byKey(ValueKey('use-operation-${first.id}')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await service.agent.reportCredentialExecution(
          CredentialExecutionReport(
            executionId: first.id,
            executionCapability: firstClaim.material!.executionCapability,
            state: 'unknown',
            errorCode: 'execution_unknown',
          ),
        );
        await service.agent.beginCredentialUseOperation(
          session,
          operation(request, 'operation-8', 'northstar/repo-8'),
        );
      });
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.textContaining('northstar/repo-1'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('先核查原操作'), findsOneWidget);
      expect(find.textContaining('northstar/repo-8'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
