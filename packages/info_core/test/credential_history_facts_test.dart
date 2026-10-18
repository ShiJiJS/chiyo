import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'credential_use_test.dart' show tokenRequest;

void main() {
  test(
    'credential history preserves the requested name and actual decision and revocation times after metadata changes',
    () async {
      var now = DateTime.utc(2026, 10, 18, 8);
      final (service, session, request) = await tokenRequest(clock: () => now);
      addTearDown(service.close);
      expect(request.credentialName, 'Synthetic');
      now = now.add(const Duration(minutes: 2));
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
        lifetime: const Duration(minutes: 30),
      );
      var fact = service.owner.credentialUseRequests.single;
      expect(fact.decidedAt, DateTime.utc(2026, 10, 18, 8, 2));
      final c = service.owner.credentials.single;
      await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: 'Renamed token',
        publicPurpose: c.publicPurpose,
        privateNote: c.privateNote,
        suggestedBinding: c.suggestedBinding,
        discoverable: c.discoverable,
      );
      now = now.add(const Duration(minutes: 3));
      await service.owner.revokeCredentialUse(request.id);
      fact = CredentialUseRequest.fromJson(
        service.owner.credentialUseRequests.single.toJson(),
      );
      expect(fact.credentialName, 'Synthetic');
      expect(fact.revokedAt, DateTime.utc(2026, 10, 18, 8, 5));
      expect(service.owner.credentialGrantState(fact), 'revoked');
      final status = service.agent.credentialUseStatus(session, request.id);
      expect(
        ((status['decision'] as Map)['credentialUse'] as Map)['state'],
        'revoked',
      );
      expect(fact.attemptedAt, isNull);
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(isA<CredentialUseFailure>()),
      );
    },
  );
}
