import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  late SampleWorkspaceSource s;
  const ssh = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
  setUp(() => s = SampleWorkspaceSource());
  tearDown(() => s.dispose());
  Future<WorkspaceApprovalDetail> approve({bool credential = true}) async {
    final d = await s.approvals.read('server');
    await s.approvals.change(
      WorkspaceApprovalChange(
        operationId: workspaceOperationId(),
        fieldMinutes: 240,
        credentialMinutes: 120,
        requestId: 'server',
        reviewToken: d.reviewToken,
        action: WorkspaceApprovalAction.approve,
        selected: d.scopes
            .where(
              (x) =>
                  x.requested &&
                  (credential ||
                      x.kind != WorkspaceApprovalScopeKind.credential),
            )
            .map((x) => x.id),
      ),
    );
    return s.approvals.read('server');
  }

  Matcher failure(String code) =>
      isA<WorkspaceFailure>().having((e) => e.code, 'code', code);

  test(
    'approval does not imply execution; independent metadata operations share one fixed grant without extending it',
    () async {
      final granted = await approve();
      expect(granted.executions, isEmpty);
      expect((await s.credentials.history(ssh)).last.operations, isEmpty);
      s.demonstrateApprovalExecutions('server');
      final d = await s.approvals.read('server');
      expect(d.executions.map((e) => e.operationId).toSet(), hasLength(3));
      expect(d.executions.map((e) => e.grantId).toSet(), {
        'preview-grant:server',
      });
      expect(d.executions.map((e) => e.state), [
        WorkspaceExecutionState.exited,
        WorkspaceExecutionState.startFailed,
        WorkspaceExecutionState.unknown,
      ]);
      expect(d.executions.every((e) => e.valid), isTrue);
      expect(d.executions.first.exitCode, 0);
      expect(d.executions[1].processStarted, false);
      expect(d.executions.last.exitCode, isNull);
      for (final e in d.executions) {
        expect(
          (await s.approvals.execution(
            'server',
            e.operationId,
          )).observationDigest,
          e.observationDigest,
        );
      }
      s.demonstrateApprovalExecutions('server');
      expect((await s.approvals.read('server')).executions, hasLength(3));
      expect(
        (await s.credentials.history(ssh)).last.operations.map((e) => e.id),
        d.executions.map((e) => e.operationId),
      );
      expect(
        (await s.approvals.read('server')).credentialExpiresAt,
        granted.credentialExpiresAt,
      );
    },
  );

  test(
    'failed query cannot mean no execution; observed tree end and cleanup cannot imply a known exit result',
    () async {
      final granted = await approve();
      s.demonstrateApprovalExecutions('server');
      final old = (await s.approvals.read('server')).executions.last;
      s.nextApprovalExecutionReadFailure = const WorkspaceFailure(
        'offline',
        '查询失败',
      );
      await expectLater(
        s.approvals.execution('server', old.operationId),
        throwsA(failure('offline')),
      );
      expect(
        (await s.approvals.read('server')).executions.last.observationDigest,
        old.observationDigest,
      );
      s.publishApprovalExecutionObservation('server');
      final next = await s.approvals.execution('server', old.operationId);
      expect(next.updates(old), true);
      expect(next.processEnded, true);
      expect(next.cleanup, WorkspaceExecutionCleanup.complete);
      expect(next.state, WorkspaceExecutionState.unknown);
      expect(next.exitCode, isNull);
      expect(old.processEnded, false);
      expect(
        (await s.approvals.read('server')).credentialExpiresAt,
        granted.credentialExpiresAt,
      );
      s.advanceApprovalClock(const Duration(minutes: 121));
      final mixed = await s.approvals.read('server');
      expect(
        mixed.request.state,
        WorkspaceApprovalState.approved,
      ); // Ordinary fields last four hours.
      expect(
        mixed.scopes
            .singleWhere((x) => x.kind == WorkspaceApprovalScopeKind.credential)
            .available,
        false,
      );
      expect(
        mixed.scopes.where(
          (x) => x.kind == WorkspaceApprovalScopeKind.field && x.available,
        ),
        isNotEmpty,
      );
      expect((await s.credentials.history(ssh)).last.state, '已到期');
      expect(
        (await s.approvals.execution('server', old.operationId)).operationId,
        old.operationId,
      );
      expect(
        () => s.demonstrateApprovalExecutions('server'),
        throwsA(failure('unavailable')),
      );
    },
  );

  test(
    'field-only, revoked, session-ended and rotated credentials cannot acquire new operations; old metadata stays readable',
    () async {
      await approve(credential: false);
      expect(
        () => s.demonstrateApprovalExecutions('server'),
        throwsA(failure('unavailable')),
      );
      s.reset();
      await approve();
      s.demonstrateApprovalExecutions('server');
      final d = await s.approvals.read('server'), old = d.executions.last;
      await s.approvals.change(
        WorkspaceApprovalChange(
          operationId: 'revoke',
          requestId: 'server',
          reviewToken: d.reviewToken,
          action: WorkspaceApprovalAction.revoke,
        ),
      );
      expect(
        () => s.demonstrateApprovalExecutions('server'),
        throwsA(failure('unavailable')),
      );
      expect(
        (await s.approvals.execution('server', old.operationId)).bindingDigest,
        old.bindingDigest,
      );
      s.reset();
      await approve();
      s.demonstrateApprovalExecutions('server');
      s.endApprovalSession('session-maintenance');
      expect(
        () => s.demonstrateApprovalExecutions('server'),
        throwsA(failure('unavailable')),
      );
      expect((await s.approvals.read('server')).executions, hasLength(3));
      s.reset();
      await approve();
      s.demonstrateApprovalExecutions('server');
      final credential = await s.credentials.read(ssh);
      await s.credentials.save(
        WorkspaceCredentialWrite(
          operationId: 'rotate',
          ref: ssh,
          name: credential.record.name,
          expectedRecordVersion: credential.recordVersion,
          expectedMaterialVersion: credential.materialVersion,
          candidateId: 'ssh-file',
        ),
      );
      expect(
        () => s.demonstrateApprovalExecutions('server'),
        throwsA(failure('unavailable')),
      );
      final history = (await s.approvals.read('server')).executions;
      expect(history, hasLength(3));
      expect(history.every((e) => e.credential.materialVersion == 1), true);
    },
  );

  test(
    'missing lookup never replays; reset and empty state do not recreate an old operation',
    () async {
      await approve();
      s.demonstrateApprovalExecutions('server');
      final old = (await s.approvals.read('server')).executions.last;
      await expectLater(
        s.approvals.execution('token', old.operationId),
        throwsA(failure('not_found')),
      );
      expect((await s.approvals.read('server')).executions, hasLength(3));
      s.setScenario(SampleWorkspaceScenario.empty);
      await expectLater(
        s.approvals.execution('server', old.operationId),
        throwsA(failure('not_found')),
      );
      s.reset();
      await expectLater(
        s.approvals.execution('server', old.operationId),
        throwsA(failure('not_found')),
      );
      expect((await s.approvals.read('server')).executions, isEmpty);
      expect((await s.loadSummary()).pending, 5);
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.pending,
      );
    },
  );
}
