import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'fixtures/ssh_session_fixture.dart' show knownHostBytes;

void main() {
  test(
    'SSH session grant is fixed to device/chat/version/trust and can end with chat',
    () async {
      var now = DateTime.utc(2026, 11, 14);
      final service = InformationService(
        repository: MemoryInformationRepository(),
        clock: () => now,
      );
      addTearDown(service.close);
      final session = service.agent.openSession('Synthetic SSH');
      final stranger = service.agent.openSession('Synthetic SSH');
      const device = 'AAAAAAAAAAAAAAAAAAAAAA';
      var credential = await service.owner.createStringCredential(
        name: 'SSH login',
        publicPurpose: 'Test',
        secret: 'synthetic-password',
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: credential.publicPurpose,
        privateNote: '',
        suggestedBinding: '',
        discoverable: true,
      );
      final trust = await service.owner.configureSshKnownHosts(
        'fixture',
        knownHostBytes(),
      );
      final input = CredentialBatchInput.fromJson({
        'protocolVersion': 3,
        'purpose': 'Install synthetic package',
        'agentName': 'Test Agent',
        'externalChatId': 'ssh-test',
        'items': [
          {
            'credentialId': credential.id,
            'version': credential.version,
            'destination': {
              'via': 'ssh',
              'target': SshSessionTarget(
                host: 'example.test',
                port: 22,
                user: 'fixture',
                authentication: 'password',
                credentialUse: 'login',
                validity: 'session',
              ).toJson(),
            },
          },
        ],
      });
      var request = await service.agent.requestCredentialBatch(
        session,
        device,
        input,
        operationId: 'request',
      );
      expect(request.items.single.destination.ssh!.trustId, trust.id);
      expect(
        () => service.agent.checkSshSessionGrant(session, device, request.id),
        throwsA(isA<CredentialUseFailure>()),
      );
      request = await service.owner.decideCredentialBatch(
        request.id,
        operationId: 'approve',
        revision: request.revision,
        approvedItems: [request.items.single.id],
        lifetime: null,
      );
      expect(request.items.single.expiresAt, isNull);
      now = now.add(const Duration(days: 5));
      expect(
        service.agent.checkSshSessionGrant(
          session,
          device,
          request.id,
        )['status'],
        'ok',
      );
      expect(
        () => service.agent.checkSshSessionGrant(stranger, device, request.id),
        throwsA(isA<CredentialUseFailure>()),
      );
      expect(
        () => service.agent.checkSshSessionGrant(
          session,
          'BBBBBBBBBBBBBBBBBBBBBB',
          request.id,
        ),
        throwsA(isA<CredentialUseFailure>()),
      );
      final context = SshSessionOperationContext(
        kind: 'run',
        sessionId: 'ssh-test',
        runId: 'run-one',
        digest: 'sha256:${'a' * 64}',
        byteLength: 9,
      );
      final run = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        request.id,
        operationId: 'run-one',
        sshContext: context,
      );
      await expectLater(
        service.agent.claimCredentialBatchMaterials(device, run.privateProof!, {
          'b1': request.items.single.destination,
        }),
        throwsA(isA<CredentialUseFailure>()),
      );
      await service.agent.authorizeCredentialBatchInput(
        device,
        run.privateProof!,
      );
      await service.agent.finishCredentialBatchOperation(
        device,
        run.privateProof!,
        CredentialBatchOperationState.filled,
        itemResults: {'b1': 'sent'},
      );
      final duplicate = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        request.id,
        operationId: 'run-one',
        sshContext: context,
      );
      expect(duplicate.privateProof, isNull);
      expect(duplicate.operation.materialClaimed, isFalse);
      expect(duplicate.operation.sshContext!.kind, 'run');
      final sudoRequest = await service.agent.requestCredentialBatch(
        session,
        device,
        CredentialBatchInput.fromJson({
          'protocolVersion': 3,
          'purpose': 'Synthetic sudo',
          'agentName': 'Test Agent',
          'externalChatId': 'ssh-test',
          'items': [
            {
              'credentialId': credential.id,
              'version': credential.version,
              'destination': {
                'via': 'ssh',
                'target': SshSessionTarget(
                  host: 'example.test',
                  port: 22,
                  user: 'fixture',
                  authentication: 'password',
                  credentialUse: 'sudo',
                  validity: 'session',
                ).toJson(),
              },
            },
          ],
        }),
        operationId: 'sudo-request',
      );
      final sudoApproved = await service.owner.decideCredentialBatch(
        sudoRequest.id,
        operationId: 'sudo-approve',
        revision: sudoRequest.revision,
        approvedItems: ['b1'],
        lifetime: null,
      );
      final sudoOperation = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        sudoRequest.id,
        operationId: 'sudo-use',
        sshContext: SshSessionOperationContext(
          kind: 'credential',
          sessionId: 'ssh-test',
          runId: 'run-one',
          actionId: 'action-one',
          digest: 'sha256:${'b' * 64}',
        ),
      );
      await service.agent.claimCredentialBatchMaterials(
        device,
        sudoOperation.privateProof!,
        {'b1': sudoApproved.items.single.destination},
      );
      await expectLater(
        service.agent.authorizeCredentialBatchInput(
          device,
          sudoOperation.privateProof!,
        ),
        throwsA(isA<CredentialUseFailure>()),
      );
      await service.agent.authorizeCredentialBatchInput(
        device,
        sudoOperation.privateProof!,
        sshLoginSession: session,
        sshLoginRequestId: request.id,
      );
      await service.owner.revokeCredentialBatch(
        sudoRequest.id,
        operationId: 'sudo-revoke',
        revision: sudoApproved.revision,
        itemIds: ['b1'],
      );
      await expectLater(
        service.agent.authorizeCredentialBatchInput(
          device,
          sudoOperation.privateProof!,
          sshLoginSession: session,
          sshLoginRequestId: request.id,
        ),
        throwsA(isA<CredentialUseFailure>()),
      );
      await service.owner.configureSshKnownHosts(
        'replacement',
        knownHostBytes(),
      );
      expect(
        () => service.agent.checkSshSessionGrant(session, device, request.id),
        throwsA(isA<CredentialUseFailure>()),
      );
    },
  );
}
