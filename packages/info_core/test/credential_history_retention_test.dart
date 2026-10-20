import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'credential_use_test.dart' show tokenRequest;

void main() {
  test(
    'one ended operation cannot prune an earlier active operation of the same grant',
    () async {
      var now = DateTime.utc(2026, 10, 1);
      final repository = MemoryInformationRepository();
      final (service, session, request) = await tokenRequest(
        repository: repository,
        clock: () => now,
      );
      addTearDown(service.close);
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      final first = await service.agent.consumeCredentialUse(
        session,
        request.id,
      );
      // A reusable grant owns several independent execution facts. The newer
      // terminal record must not hide an older preparing/running process group.
      await repository
          .commitCredentialRuntime(repository.credentialUseRequests, [
            ...repository.credentialExecutions,
            CredentialExecution(
              id: 'later-terminal-operation',
              requestId: request.id,
              state: 'start_failed',
              errorCode: 'process_start_failed',
              finishedAt: now,
            ),
          ]);
      now = DateTime.utc(2026, 12, 1);
      final preview = await service.owner.previewAuditRetention(30);
      expect(preview.credentialRequests, 0);
      expect(preview.credentialExecutions, 0);
      await service.owner.pruneCredentialUseHistory();
      expect(service.owner.credentialUseRequests, hasLength(1));
      expect(service.owner.credentialExecutions, hasLength(2));
      expect(
        service.owner.credentialExecutions.any(
          (e) => e.id == first.executionId,
        ),
        isTrue,
      );
    },
  );
  test(
    'retention previews and removes only ended credential facts while keeping an execution whose end cannot be established',
    () async {
      var now = DateTime.utc(2026, 10, 1);
      final (service, session, first) = await tokenRequest(clock: () => now);
      addTearDown(service.close);
      await service.owner.decideCredentialUse(
        first.id,
        approveCredential: false,
      );
      for (final state in ['prepare_failed', 'unknown']) {
        final request = await service.agent.requestCredentialUse(
          session,
          CredentialUseInput.fromJson({
            ...first.toRequestInputJson(),
            'purpose': 'Retention $state',
          }),
        );
        await service.owner.decideCredentialUse(
          request.id,
          approveCredential: true,
        );
        final m = await service.agent.consumeCredentialUse(session, request.id);
        await service.agent.reportCredentialExecution(
          CredentialExecutionReport(
            executionId: m.executionId,
            executionCapability: m.executionCapability,
            state: state,
            errorCode: state == 'unknown'
                ? 'execution_unknown'
                : 'material_prepare_failed',
            finishedAt: now,
          ),
        );
      }
      now = DateTime.utc(2026, 12, 1);
      final preview = await service.owner.previewAuditRetention(30);
      expect(preview.credentialRequests, 2);
      expect(preview.credentialExecutions, 1);
      expect(service.owner.credentialUseRequests, hasLength(3));
      await expectLater(
        service.owner.setAuditRetention(30),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.owner.credentialUseRequests, hasLength(3));
      await service.owner.setAuditRetention(30, confirmation: preview);
      expect(
        service.owner.credentialUseRequests.single.purpose,
        'Retention unknown',
      );
      expect(service.owner.credentialExecutions.single.state, 'unknown');
      await service.owner.pruneCredentialUseHistory();
      expect(service.owner.credentialUseRequests, hasLength(1));
    },
  );
}
