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
