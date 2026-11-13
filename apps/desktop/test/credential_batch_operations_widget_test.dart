import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/batch_operations.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_workspace/owner_workspace_approvals.dart';
import 'package:info_workspace/workspace_source.dart';

class _TrackedOwner extends OwnerWorkspaceApprovals {
  _TrackedOwner({required super.owner});
  Future<Object?>? lastWrite, lastRead;
  @override
  Future<WorkspaceCredentialBatchOperation> batchOperation(
    String request,
    String operation,
  ) {
    final result = super.batchOperation(request, operation);
    lastRead = result;
    return result;
  }

  @override
  Future<WorkspaceCredentialBatchOperation> acknowledgeBatchOperation(
    WorkspaceCredentialBatchAcknowledgement change,
  ) {
    final result = super.acknowledgeBatchOperation(change);
    lastWrite = result;
    return result;
  }

  @override
  Future<WorkspaceApprovalReceipt> change(WorkspaceApprovalChange change) {
    final result = super.change(change);
    lastWrite = result;
    return result;
  }
}

class _Fixture {
  DateTime now = DateTime.utc(2026, 11, 14);
  late core.InformationService service;
  late String request;
  late _TrackedOwner source;
  Future<void> open() async {
    service = core.InformationService(
      repository: core.MemoryInformationRepository(),
      clock: () => now,
    );
    final credentials = <core.ManagedCredential>[];
    for (var i = 0; i < 2; i++) {
      final c = await service.owner.createStringCredential(
        name: '合成密码$i',
        publicPurpose: '',
        secret: 'NEVER-RENDER-PASSWORD',
      );
      credentials.add(
        await service.owner.updateCredentialMetadata(
          c.id,
          c.revision,
          name: c.name,
          publicPurpose: '',
          privateNote: '',
          suggestedBinding: 'password',
          discoverable: true,
        ),
      );
    }
    final session = service.agent.openSession('合成填写记录');
    final r = await service.agent.requestCredentialBatch(
      session,
      'A' * 22,
      core.CredentialBatchInput.fromJson({
        'protocolVersion': 3,
        'purpose': '登录合成服务',
        'items': [
          for (final (i, c) in credentials.indexed)
            {
              'credentialId': c.id,
              'destination': {
                'via': 'ego',
                'target': {
                  'provider': 'ego',
                  'space': 7,
                  'pageId': 'p${i + 1}',
                  'instanceId': 'synthetic',
                  'url': 'https://synthetic$i.test/login',
                  'form': '#login',
                  'field': '#password',
                  'structureDigest': 'a' * 64,
                },
              },
            },
        ],
      }),
      operationId: 'widget-submit',
    );
    request = r.id;
    await service.owner.decideCredentialBatch(
      request,
      operationId: 'widget-approve',
      revision: 1,
      approvedItems: ['b1', 'b2'],
    );
    await service.agent.beginCredentialBatchOperation(
      session,
      'A' * 22,
      request,
      operationId: 'widget-use',
      itemIds: ['b2'],
    );
    now = now.add(const Duration(seconds: 31));
    source = _TrackedOwner(owner: service.owner);
  }
}

void main() {
  testWidgets(
    'query and owner acknowledgement never replay input; the user must first check the target',
    (tester) async {
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.service.close);
      final model = ApprovalsController(f.source, const Stream.empty());
      addTearDown(model.dispose);
      await tester.runAsync(() => model.open(f.request));
      await tester.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: model,
              builder: (_, _) => SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: BatchOperations(controller: model),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('填写结果未知'), findsOneWidget);
      final ack = find.byKey(const ValueKey('batch-acknowledge-widget-use'));
      expect(tester.widget<DesktopButton>(ack).onPressed, null);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('batch-query-widget-use')));
        await f.source.lastRead;
      });
      await tester.pumpAndSettle();
      expect(f.service.owner.credentialBatchOperations, hasLength(1));
      expect(
        f
            .service
            .owner
            .credentialBatchOperations
            .single
            .attentionAcknowledgedAt,
        null,
      );
      await tester.tap(find.byKey(const ValueKey('batch-checked-widget-use')));
      await tester.pumpAndSettle();
      expect(tester.widget<DesktopButton>(ack).onPressed, isNotNull);
      await tester.runAsync(() async {
        await tester.tap(ack);
        await f.source.lastWrite;
      });
      await tester.pumpAndSettle();
      final operation = f.service.owner.credentialBatchOperations.single;
      expect(operation.attentionAcknowledgedAt, f.now);
      expect(operation.state, core.CredentialBatchOperationState.unknown);
      expect(operation.itemResults, isEmpty);
      expect(find.text('已由用户核对，原结果保持不变。'), findsOneWidget);
      expect(find.textContaining('NEVER-RENDER-PASSWORD'), findsNothing);
      expect(
        find.byKey(const ValueKey('batch-checked-widget-use')),
        findsNothing,
      );
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'processed request exposes separate revoke actions without revoking the other credential',
    (tester) async {
      tester.view.physicalSize = const Size(1500, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.service.close);
      final model = ApprovalsController(f.source, const Stream.empty());
      addTearDown(model.dispose);
      await tester.runAsync(() => model.open(f.request));
      await tester.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: ApprovalsPage(controller: model, onRecord: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final revoke = find.byKey(const ValueKey('approval-revoke-scope-b1'));
      await tester.ensureVisible(revoke);
      await tester.runAsync(() async {
        await tester.tap(revoke);
        await f.source.lastWrite;
      });
      await tester.pumpAndSettle();
      expect(
        f.service.owner.credentialBatches.single.items.first.decision,
        core.CredentialBatchItemDecision.revoked,
      );
      expect(
        f.service.owner.credentialBatches.single.items.last.decision,
        core.CredentialBatchItemDecision.approved,
      );
      expect(model.detail!.approved, {'b2'});
      expect(f.service.owner.credentialBatchOperations, hasLength(1));
      expect(find.textContaining('NEVER-RENDER-PASSWORD'), findsNothing);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'batch observations cannot invent results at the same stored revision',
    () {
      final at = DateTime.utc(2026, 11, 14);
      final old = WorkspaceCredentialBatchOperation(
        requestId: 'r',
        operationId: 'o',
        revision: 1,
        itemIds: ['b1'],
        state: 'checking',
        createdAt: at,
        observedAt: at,
      );
      final raw = old.toJson();
      WorkspaceCredentialBatchOperation next(Map<String, Object?> changes) =>
          WorkspaceCredentialBatchOperation.fromJson({...raw, ...changes});
      final unknown = next({
        'executionState': 'unknown',
        'errorCode': 'execution_unknown',
        'observedAt': at.add(const Duration(seconds: 31)).toIso8601String(),
      });
      expect(unknown.updates(old), true);
      expect(
        next({
          'executionState': 'unknown',
          'errorCode': 'execution_unknown',
          'itemResults': {'b1': 'filled'},
        }).updates(old),
        false,
      );
      expect(() => next({'executionState': 'filled'}), throwsFormatException);
      expect(
        () => next({
          'observedAt': at
              .subtract(const Duration(seconds: 1))
              .toIso8601String(),
        }),
        throwsFormatException,
      );
    },
  );
}
