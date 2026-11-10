import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'credential_use_test.dart' show tokenRequest;

void main() {
  test(
    'every new credential and field duration shares the exact absolute deadline in both protocols',
    () async {
      for (final version in [1, 2]) {
        var now = DateTime.utc(2026, 11, 11);
        final (s, session, base) = await tokenRequest(
          protocolVersion: version,
          clock: () => now,
        );
        addTearDown(s.close);
        final item = await s.owner.createInformation('合成地址', '', [
          const FieldInput('主机', '', 'synthetic.invalid'),
        ]);
        final field = FieldRef(item.id, item.fields.single.id);
        for (final minutes in [120, 240, 480, 1440]) {
          final r = await s.agent.requestCredentialUse(
            session,
            CredentialUseInput.fromJson({
              ...base.toRequestInputJson(),
              'readFields': [field.toJson()],
            }),
          );
          await s.owner.decideCredentialUse(
            r.id,
            approveCredential: true,
            fields: [field],
            lifetime: Duration(minutes: minutes),
            fieldLifetime: Duration(minutes: minutes),
          );
          final saved = s.owner.credentialUseRequests.singleWhere(
            (x) => x.id == r.id,
          );
          final end = now.add(Duration(minutes: minutes));
          expect(saved.credentialExpiresAt, end);
          expect(saved.fieldExpiresAt, end);
          now = end.subtract(const Duration(milliseconds: 1));
          expect(s.owner.credentialGrantState(saved), 'available');
          expect(s.owner.credentialFieldGrantState(saved), 'available');
          now = end;
          expect(s.owner.credentialGrantState(saved), 'expired');
          expect(s.owner.credentialFieldGrantState(saved), 'expired');
        }
      }
    },
  );
  test(
    'all new organization durations expire exactly and old short grants are never rewritten',
    () async {
      var now = DateTime.utc(2026, 11, 11);
      final s = InformationService.fictional(clock: () => now);
      addTearDown(s.close);
      final session = s.agent.openSession('合成整理聊天');
      final old = await s.agent.requestOrganization(session, '旧授权', [
        'demo-server',
      ]);
      await s.owner.approveOrganization(old.id, [
        'demo-server',
      ], lifetime: const Duration(minutes: 15));
      final oldEnd = s.owner.organizationTasks.single.expiresAt;
      await s.owner.setRequestLifetime(const Duration(hours: 24));
      expect(s.owner.organizationTasks.single.expiresAt, oldEnd);
      now = oldEnd;
      expect(s.agent.organizationStatus(session, old.id)['status'], 'expired');
      for (final minutes in [120, 240, 480, 1440]) {
        final r = await s.agent.requestOrganization(session, '合成整理', [
          'demo-server',
        ]);
        await s.owner.approveOrganization(r.id, [
          'demo-server',
        ], lifetime: Duration(minutes: minutes));
        final end = now.add(Duration(minutes: minutes));
        expect(s.owner.organizationTasks.last.expiresAt, end);
        now = end.subtract(const Duration(milliseconds: 1));
        expect(
          (await s.agent.organizationMetadata(session, r.id))['items'],
          hasLength(1),
        );
        now = end;
        expect(s.agent.organizationStatus(session, r.id)['status'], 'expired');
        await expectLater(
          s.agent.organizationMetadata(session, r.id),
          throwsA(isA<AccessFailure>()),
        );
      }
    },
  );
  test(
    'an existing short credential grant keeps its deadline when new waiting policy changes',
    () async {
      var now = DateTime.utc(2026, 11, 11);
      final (s, _, r) = await tokenRequest(
        clock: () => now,
        protocolVersion: 2,
      );
      addTearDown(s.close);
      await s.owner.decideCredentialUse(
        r.id,
        approveCredential: true,
        lifetime: const Duration(minutes: 15),
      );
      final old = s.owner.credentialUseRequests.single;
      await s.owner.setRequestLifetime(const Duration(hours: 24));
      expect(
        s.owner.credentialUseRequests.single.credentialExpiresAt,
        now.add(const Duration(minutes: 15)),
      );
      now = now.add(const Duration(minutes: 15));
      expect(s.owner.credentialGrantState(old), 'expired');
    },
  );
}
