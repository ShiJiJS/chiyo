import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'fixtures/ssh_session_fixture.dart'
    show knownHostBytes, SshSessionFixture;
import 'credential_use_test.dart' show tokenRequest;

Matcher fails(String code) =>
    throwsA(isA<CredentialUseFailure>().having((e) => e.code, 'code', code));

void main() {
  test(
    'session SSH permit survives old deadlines while ordinary fields expire independently',
    () async {
      var now = DateTime.utc(2026, 11, 7);
      final f = await SshSessionFixture.create(clock: () => now), s = f.service;
      addTearDown(s.close);
      await s.owner.decideCredentialUse(
        f.request.id,
        approveCredential: true,
        lifetime: null,
        fields: [f.field],
      );
      final stored = s.owner.credentialUseRequests.single;
      expect(stored.credentialValidity, CredentialUseValidity.session);
      expect(stored.credentialExpiresAt, isNull);
      expect(stored.toJson()['credentialValidity'], 'session');
      final first = await f.begin('first');
      now = now.add(const Duration(days: 4));
      final second = await f.begin('second');
      expect(second.newlyClaimed, isTrue);
      expect(second.execution.id, isNot(first.execution.id));
      final repeated = await f.begin('second');
      expect(repeated.execution.id, second.execution.id);
      expect(repeated.material, isNull);
      final status = s.agent.credentialUseStatus(f.session, f.request.id);
      final decision = (status['decision'] as Map)['credentialUse'] as Map;
      expect(decision['validity'], 'session');
      expect(decision['expiresAt'], isNull);
      expect(decision['sessionId'], isNotEmpty);
      expect(decision['state'], 'available');
      expect(s.owner.credentialFieldGrantState(stored), 'expired');
      expect(s.owner.credentialExecutions, hasLength(2));
      await expectLater(
        s.agent.beginCredentialUseOperation(
          s.agent.openSession('Other chat'),
          f.operation('third'),
        ),
        fails('session_mismatch'),
      );
    },
  );

  for (final cause in [
    'revoked',
    'ended',
    'disabled',
    'rotated',
    'deleted',
    'trust-changed',
  ]) {
    test(
      '$cause blocks further session SSH uses without replaying a previous operation',
      () async {
        var now = DateTime.utc(2026, 11, 7);
        final f = await SshSessionFixture.create(clock: () => now),
            s = f.service;
        addTearDown(s.close);
        await s.owner.decideCredentialUse(
          f.request.id,
          approveCredential: true,
          lifetime: null,
        );
        await f.begin('before');
        now = now.add(const Duration(hours: 12));
        final c = s.owner.credential(f.request.credentialId);
        switch (cause) {
          case 'revoked':
            await s.owner.revokeCredentialUse(f.request.id);
          case 'ended':
            s.agent.endSession(f.session);
          case 'disabled':
            await s.owner.setCredentialEnabled(c.id, c.revision, false);
          case 'rotated':
            await s.owner.rotateFileCredential(
              c.id,
              c.revision,
              fileName: 'replacement',
              bytes: utf8.encode('ANOTHER SYNTHETIC KEY'),
            );
          case 'deleted':
            await s.owner.deleteCredential(c.id, c.revision);
          case 'trust-changed':
            await s.owner.configureSshKnownHosts(
              'New confirmation',
              knownHostBytes(),
            );
        }
        await expectLater(
          f.begin('after'),
          fails(switch (cause) {
            'revoked' => 'grant_revoked',
            'ended' => 'session_required',
            'disabled' => 'credential_disabled',
            'rotated' => 'credential_version_changed',
            'deleted' => 'credential_deleted',
            _ => 'receiver_not_ready',
          }),
        );
        expect(
          s.owner.credentialGrantState(s.owner.credentialUseRequests.single),
          isNot('available'),
        );
        expect(s.owner.credentialExecutions, hasLength(1));
      },
    );
  }

  test(
    'null lifetime never upgrades legacy SSH or another receiver and timed records stay timed',
    () async {
      var now = DateTime.utc(2026, 11, 7);
      final legacy = await SshSessionFixture.create(
        clock: () => now,
        protocolVersion: 1,
      );
      addTearDown(legacy.service.close);
      await expectLater(
        legacy.service.owner.decideCredentialUse(
          legacy.request.id,
          approveCredential: true,
          lifetime: null,
        ),
        fails('invalid_plan'),
      );
      final (s, _, r) = await tokenRequest(
        protocolVersion: 2,
        clock: () => now,
      );
      addTearDown(s.close);
      await expectLater(
        s.owner.decideCredentialUse(
          r.id,
          approveCredential: true,
          lifetime: null,
        ),
        fails('invalid_plan'),
      );
      await s.owner.decideCredentialUse(r.id, approveCredential: true);
      final saved = s.owner.credentialUseRequests.single;
      expect(saved.toJson().containsKey('credentialValidity'), isFalse);
      now = now.add(const Duration(minutes: 121));
      expect(s.owner.credentialGrantState(saved), 'expired');
      expect(
        () => CredentialUseRequest.fromJson({
          ...saved.toJson(),
          'credentialValidity': 'session',
          'credentialExpiresAt': null,
        }),
        fails('invalid_plan'),
      );
      for (final invalid in [null, 'timed', 'forever', 10]) {
        expect(
          () => CredentialUseRequest.fromJson({
            ...saved.toJson(),
            'credentialValidity': invalid,
          }),
          fails('invalid_plan'),
        );
      }
    },
  );
}
