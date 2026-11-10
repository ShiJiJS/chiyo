import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'credential_use_test.dart' show tokenRequest;

void main() {
  test(
    'a mixed request reports independent current field permission after credential revocation, field revocation and expiry without reloading history',
    () async {
      var now = DateTime.utc(2026, 10, 18, 8);
      final (service, session, base) = await tokenRequest(clock: () => now);
      addTearDown(service.close);
      final item = await service.owner.createInformation('Test server', '', [
        const FieldInput('Host', '', 'test.example.invalid'),
      ]);
      final field = FieldRef(item.id, item.fields.single.id);
      Future<CredentialUseRequest> approve() async {
        final r = await service.agent.requestCredentialUse(
          session,
          CredentialUseInput.fromJson({
            ...base.toRequestInputJson(),
            'readFields': [field.toJson()],
          }),
        );
        await service.owner.decideCredentialUse(
          r.id,
          approveCredential: true,
          fields: [field],
        );
        return service.owner.credentialUseRequests.firstWhere(
          (x) => x.id == r.id,
        );
      }

      final r = await approve();
      expect(service.owner.credentialFieldGrantState(r), 'available');
      await service.owner.revokeCredentialUse(r.id);
      expect(service.owner.credentialFieldGrantState(r), 'available');
      final history = await service.owner.history();
      await service.owner.revokeFromHistory(history.grants.single.id);
      expect(service.owner.credentialFieldGrantState(r), 'revoked');
      final expiring = await approve();
      now = now.add(const Duration(minutes: 121));
      expect(service.owner.credentialFieldGrantState(expiring), 'expired');
    },
  );
}
