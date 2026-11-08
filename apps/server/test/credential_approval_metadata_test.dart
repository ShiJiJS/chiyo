import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';

void main() {
  test(
    'v2 preserves the complete credential review and execution identity; v1 cannot silently omit them',
    () {
      final now = DateTime.utc(2026, 11, 8);
      final receiver = WorkspaceCredentialReceiver(
        id: 'gh_token',
        label: 'GitHub CLI',
        executable: '/device/gh',
        workingDirectory: '/device/work',
        arguments: ['api', 'user'],
        binding: 'GH_TOKEN',
      );
      final credential = WorkspaceCredentialUseRequest(
        id: 'request',
        ref: WorkspaceRecordRef(WorkspaceRecordKind.credential, 'credential'),
        credentialName: 'Synthetic token',
        materialVersion: 2,
        useGeneration: 3,
        delivery: WorkspaceCredentialDelivery.environment,
        receiver: receiver,
        session: const WorkspaceCredentialSession(
          'public-chat-id',
          'Synthetic chat',
          'Synthetic Agent',
        ),
        purpose: 'Synthetic task',
        minutes: 15,
        submittedAt: now,
        state: WorkspaceCredentialRequestState.approved,
      );
      final execution = WorkspaceApprovalExecution(
        requestId: 'request',
        grantId: 'request',
        operationId: 'operation',
        credential: credential,
        plan: receiver,
        createdAt: now,
        state: WorkspaceExecutionState.exited,
        revision: 2,
        processEnded: true,
        processStarted: true,
        cleanup: WorkspaceExecutionCleanup.complete,
        exitCode: 0,
        observedAt: now.add(const Duration(seconds: 1)),
      );
      final detail = WorkspaceApprovalDetail(
        request: WorkspaceApprovalSummary(
          id: 'request',
          title: 'Synthetic use',
          kind: WorkspaceApprovalKind.credential,
          agentClaim: 'Synthetic Agent',
          sessionId: 'public-chat-id',
          chatClaim: 'Synthetic chat',
          purpose: 'Synthetic task',
          submittedAt: now,
          requestExpiresAt: now.add(const Duration(minutes: 30)),
          state: WorkspaceApprovalState.approved,
        ),
        reviewToken: 'review',
        scopes: const [],
        credential: credential,
        executions: [execution],
      );
      expect(
        () => approvalDetailToJson(detail),
        throwsA(
          isA<WorkspaceFailure>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
      final encoded = approvalDetailToJson(detail, version: 2);
      final received = approvalDetailFromJson(encoded);
      expect(received.credential!.receiver.arguments, receiver.arguments);
      expect(received.credential!.materialVersion, 2);
      expect(received.executions.single.bindingDigest, execution.bindingDigest);
      expect(
        received.executions.single.observationDigest,
        execution.observationDigest,
      );
      expect(
        () => approvalDetailFromJson({...encoded, 'credential': null}),
        throwsFormatException,
      );
      expect(
        () => approvalDetailFromJson({...encoded, 'version': 3}),
        throwsFormatException,
      );
      expect(
        () => approvalDetailFromJson({
          ...encoded,
          'credential': {
            ...(encoded['credential'] as Map),
            'executionCapability': 'PRIVATE_PROOF',
          },
        }),
        throwsFormatException,
      );
    },
  );
}
