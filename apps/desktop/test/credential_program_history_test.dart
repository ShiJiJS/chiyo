import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/approval_executions.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/owner_workspace_approvals.dart';
import 'package:info_workspace/workspace_source.dart';

class _Owner extends OwnerWorkspaceApprovals {
  _Owner({required super.owner});
  int queries = 0;
  Future<WorkspaceCredentialProgramOperation>? lastQuery;
  Completer<WorkspaceCredentialProgramOperation>? delayed;
  @override
  Future<WorkspaceCredentialProgramOperation> programOperation(
    String request,
    String operation,
  ) {
    queries++;
    return lastQuery =
        delayed?.future ?? super.programOperation(request, operation);
  }
}

class _Fixture {
  DateTime now = DateTime.utc(2026, 11, 14);
  late core.InformationService service;
  late _Owner source;
  late String session;
  late core.CredentialUseBatch request;
  late core.CredentialProgramPlan launch;
  Future<void> open() async {
    service = core.InformationService(
      repository: core.MemoryInformationRepository(),
      clock: () => now,
    );
    final credentials = <core.ManagedCredential>[];
    for (final name in ['合成数据库密码', '合成服务密钥']) {
      final credential = await service.owner.createStringCredential(
        name: name,
        publicPurpose: '',
        secret: 'DO-NOT-RENDER-SYNTHETIC-MATERIAL',
      );
      credentials.add(
        await service.owner.updateCredentialMetadata(
          credential.id,
          credential.revision,
          name: name,
          publicPurpose: '',
          privateNote: '',
          suggestedBinding: 'password',
          discoverable: true,
        ),
      );
    }
    launch = core.CredentialProgramPlan.fromJson({
      'executable': r'C:\Program Files\Service Tool\service.exe',
      'cwd': r'C:\Work\项目',
      'argv': ['query', '--format', 'simple'],
      'env': {
        'DB_PASSWORD': {'credentialId': credentials.first.id},
        'KEY_PATH': {
          'file': {'credentialId': credentials.last.id},
        },
      },
    }, allowPortablePaths: true);
    session = service.agent.openSession('合成程序历史');
    request = await submit('program-submit');
    source = _Owner(owner: service.owner);
  }

  core.DeviceCredentialLaunch get prepared =>
      core.DeviceCredentialLaunch.fromPrivateJson({
        'version': 1,
        'planHash': launch.planHash,
        'cwd': launch.cwd,
        'executable': core.ExecutableIdentity(
          launch.path,
          100,
          1,
          'sha256:${'a' * 64}',
        ).toJson(),
      });
  Future<core.CredentialUseBatch> submit(String operation) =>
      service.agent.requestCredentialBatch(
        session,
        'A' * 22,
        core.CredentialBatchInput.forProgram(
          prepared.resolveProgram(launch),
          purpose: '查询合成服务',
          agentName: '试用 Agent',
          externalChatId: 'program-trial',
        ),
        operationId: operation,
      );
  Future<void> begin() async {
    await service.owner.decideCredentialBatch(
      request.id,
      operationId: 'approve-program',
      revision: 1,
      approvedItems: ['b1', 'b2'],
    );
    await service.agent.beginCredentialProgramOperation(
      session,
      'A' * 22,
      request.id,
      launch,
      prepared,
      core.CredentialProcessJob.nameFor('A' * 32),
      operationId: 'program-use',
    );
    now = now.add(const Duration(seconds: 31));
  }
}

void main() {
  test(
    'program metadata is strict, bound to the exact request receivers and never accepts invented same-revision facts',
    () async {
      final f = _Fixture();
      await f.open();
      addTearDown(f.service.close);
      await f.begin();
      final detail = await f.source.read(f.request.id);
      expect(detail.request.title, 'service.exe · 程序使用');
      expect(detail.programPlan!.workingDirectory, r'C:\Work\项目');
      final operation = detail.programOperations.single;
      expect(operation.state, 'unknown');
      expect(operation.updates(operation), true);
      final wire = approvalDetailToJson(detail, version: 4);
      final decoded = approvalDetailFromJson(Map<String, dynamic>.from(wire));
      expect(
        decoded.programOperations.single.plan.fingerprint,
        operation.plan.fingerprint,
      );
      expect(decoded.batchOperations, isEmpty);
      expect(
        () => approvalDetailToJson(detail, version: 3),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect(
        () => WorkspaceCredentialProgramOperation.fromJson({
          ...operation.toJson(),
          'executionCapability': 'PRIVATE-NOT-ALLOWED',
        }),
        throwsFormatException,
      );
      final invented = WorkspaceCredentialProgramOperation.fromJson({
        ...operation.toJson(),
        'finishedAt': f.now.toIso8601String(),
      });
      expect(invented.updates(operation), false);
      final changed = WorkspaceCredentialProgramOperation.fromJson({
        ...operation.toJson(),
        'revision': operation.revision + 1,
        'programPlan': {
          ...operation.plan.toJson(),
          'argv': ['delete'],
        },
      });
      expect(changed.updates(operation), false);
      expect(
        () => approvalDetailFromJson({
          ...wire,
          'programOperations': [
            {
              ...operation.toJson(),
              'itemIds': ['b2', 'b1'],
            },
          ],
        }),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'the program result panel reuses the plan, queries metadata only, and does not offer fill replay or password values',
    (tester) async {
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.service.close);
      await tester.runAsync(f.begin);
      final controller = ApprovalsController(f.source, const Stream.empty());
      addTearDown(controller.dispose);
      await tester.runAsync(() => controller.open(f.request.id));
      await tester.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: ApprovalExecutions(controller: controller),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('程序执行记录'), findsOneWidget);
      expect(find.text('执行结果未知'), findsOneWidget);
      expect(find.text('填写记录'), findsNothing);
      expect(find.text('确认已检查目标'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('program-details-program-use')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(r'C:\Program Files\Service Tool\service.exe'),
        findsOneWidget,
      );
      expect(find.textContaining('DB_PASSWORD = 合成数据库密码（第1版）'), findsOneWidget);
      expect(find.textContaining('KEY_PATH = 文件：合成服务密钥（第1版）'), findsOneWidget);
      expect(
        find.textContaining('DO-NOT-RENDER-SYNTHETIC-MATERIAL'),
        findsNothing,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('program-query-program-use')),
      );
      await tester.runAsync(() async {
        await tester.tap(
          find.byKey(const ValueKey('program-query-program-use')),
        );
        await f.source.lastQuery;
      });
      await tester.pumpAndSettle();
      expect(f.source.queries, 1);
      expect(f.service.owner.credentialProgramOperations, hasLength(1));
      expect(f.service.owner.credentialProgramOperations.single.revision, 1);
      expect(tester.takeException(), null);
    },
  );

  test(
    'a delayed program query cannot replace another request selected later',
    () async {
      final f = _Fixture();
      await f.open();
      addTearDown(f.service.close);
      await f.begin();
      final controller = ApprovalsController(f.source, const Stream.empty());
      addTearDown(controller.dispose);
      await controller.open(f.request.id);
      final old = controller.detail!.programOperations.single;
      f.source.delayed = Completer<WorkspaceCredentialProgramOperation>();
      final query = controller.refreshProgramOperation('program-use');
      final second = await f.submit('second-program');
      await controller.open(second.id);
      f.source.delayed!.complete(old);
      await query;
      expect(controller.detail!.request.id, second.id);
      expect(controller.detail!.programOperations, isEmpty);
    },
  );
}
