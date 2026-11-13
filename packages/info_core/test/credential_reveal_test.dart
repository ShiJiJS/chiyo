import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'credential_use_test.dart' show tokenRequest, FailingRuntimeRepository;

CredentialRevealInput revealInput(String id, {int version = 1}) =>
    CredentialRevealInput.fromJson({
      'protocolVersion': 2,
      'command': 'request-reveal',
      'credentialId': id,
      'version': version,
      'purpose': 'Synthetic fallback login',
      'fallbackReason':
          'Synthetic target cannot receive focused fill or a program input.',
    });
Matcher failure(String code) =>
    throwsA(isA<CredentialUseFailure>().having((e) => e.code, 'code', code));

void main() {
  test(
    'explicit reveal submission ids recover one immutable request in the original chat',
    () async {
      var now = DateTime.utc(2026, 11, 14);
      final (service, session, command) = await tokenRequest(
        clock: () => now,
        protocolVersion: 2,
      );
      addTearDown(service.close);
      Map<String, dynamic> input(String reason) => {
        'protocolVersion': 2,
        'command': 'request-reveal',
        'credentialId': command.credentialId,
        'version': 1,
        'purpose': 'Synthetic fallback',
        'fallbackReason': reason,
        'operationId': 'reveal-once',
      };
      final results = await Future.wait(
        List.generate(
          4,
          (_) => service.agent.requestCredentialReveal(
            session,
            CredentialRevealInput.fromJson(
              input('Cannot fill synthetic target'),
            ),
          ),
        ),
      );
      expect(results.map((r) => r.id).toSet(), hasLength(1));
      final first = results.first;
      expect(first.submissionOperationId, 'reveal-once');
      expect(
        service.agent.showOwnOperation(session, 'reveal-once')['requestId'],
        first.id,
      );
      expect(
        service.agent.showOwnOperation(
          service.agent.openSession('Other chat'),
          'reveal-once',
        )['status'],
        'not_found',
      );
      expect(
        jsonEncode(first.toJson()),
        isNot(contains('submissionOperation')),
      );
      final stored = CredentialUseRequest.fromStorageJson(
        Map<String, dynamic>.from(first.toStorageJson()),
      );
      expect(stored.submissionOperationId, 'reveal-once');
      expect(
        stored.changed({'state': 'denied'}).submissionDigest,
        first.submissionDigest,
      );
      now = now.add(const Duration(minutes: 10));
      final c = service.owner.credential(command.credentialId);
      await service.owner.rotateStringCredential(
        c.id,
        c.revision,
        'SYNTHETIC-ROTATED',
      );
      final same = await service.agent.requestCredentialReveal(
        session,
        CredentialRevealInput.fromJson(input('Cannot fill synthetic target')),
      );
      expect(same.id, first.id);
      expect(same.version, 1);
      expect(same.requestExpiresAt, first.requestExpiresAt);
      await expectLater(
        service.agent.requestCredentialReveal(
          session,
          CredentialRevealInput.fromJson(input('Changed business reason')),
        ),
        failure('operation_conflict'),
      );
      expect(
        service.owner.credentialUseRequests.where((r) => r.isReveal),
        hasLength(1),
      );
    },
  );
  test(
    'use approval never becomes plaintext approval; reads are separate and audited',
    () async {
      final (service, session, command) = await tokenRequest(
        protocolVersion: 2,
      );
      addTearDown(service.close);
      await service.owner.decideCredentialUse(
        command.id,
        approveCredential: true,
      );
      await expectLater(
        service.agent.readCredentialReveal(session, command.id, 'wrong-kind'),
        failure('scope_not_approved'),
      );
      final r = await service.agent.requestCredentialReveal(
        session,
        revealInput(command.credentialId),
      );
      await expectLater(
        service.agent.readCredentialReveal(session, r.id, 'pending'),
        failure('request_pending'),
      );
      expect(jsonEncode(r.toJson()), isNot(contains('synthetic-token')));
      expect(CredentialUseRequest.fromJson(r.toJson()).isReveal, isTrue);
      await service.owner.decideCredentialUse(r.id, approveCredential: true);
      final result = await service.agent.readCredentialReveal(
        session,
        r.id,
        'read-1',
      );
      expect(result['secret'], 'synthetic-token');
      final stored = service.owner.credentialUseRequests.singleWhere(
        (v) => v.id == r.id,
      );
      expect(stored.revealReads.single.operationId, 'read-1');
      expect(jsonEncode(stored.toJson()), isNot(contains('synthetic-token')));
      await expectLater(
        service.agent.readCredentialReveal(session, r.id, 'read-1'),
        failure('attempt_consumed'),
      );
      await expectLater(
        service.agent.readCredentialReveal(
          service.agent.openSession('another chat'),
          r.id,
          'read-2',
        ),
        failure('session_mismatch'),
      );
      final operation = CredentialOperationInput.fromJson({
        'protocolVersion': 2,
        'command': 'run-use',
        'requestId': r.id,
        'operationId': 'launch',
        'launch': command.toRequestInputJson()['launch'],
      });
      await expectLater(
        service.agent.beginCredentialUseOperation(session, operation),
        failure('scope_not_approved'),
      );
      await service.owner.revokeCredentialUse(r.id);
      await expectLater(
        service.agent.readCredentialReveal(session, r.id, 'revoked'),
        failure('grant_revoked'),
      );
    },
  );

  test('expiry, rotation and failed audit prevent reads', () async {
    var now = DateTime.utc(2026, 11, 12);
    final repo = FailingRuntimeRepository();
    final (service, session, command) = await tokenRequest(
      repository: repo,
      clock: () => now,
      protocolVersion: 2,
    );
    addTearDown(service.close);
    final r = await service.agent.requestCredentialReveal(
      session,
      revealInput(command.credentialId),
    );
    await service.owner.decideCredentialUse(r.id, approveCredential: true);
    repo.fail = true;
    await expectLater(
      service.agent.readCredentialReveal(session, r.id, 'audit'),
      failure('audit_unavailable'),
    );
    expect(service.owner.credentialUseRequests.last.revealReads, isEmpty);
    repo.fail = false;
    now = now.add(const Duration(days: 1));
    await expectLater(
      service.agent.readCredentialReveal(session, r.id, 'expiry'),
      failure('grant_expired'),
    );
    final newer = await service.agent.requestCredentialReveal(
      session,
      revealInput(command.credentialId),
    );
    await service.owner.decideCredentialUse(newer.id, approveCredential: true);
    final c = service.owner.credential(command.credentialId);
    await service.owner.rotateStringCredential(
      c.id,
      c.revision,
      'synthetic-replacement',
    );
    await expectLater(
      service.agent.readCredentialReveal(session, newer.id, 'rotation'),
      failure('credential_version_changed'),
    );
  });

  test(
    'owner can view disabled saved strings without any AI approval; files refused',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      var c = await service.owner.createStringCredential(
        name: 'Saved',
        publicPurpose: '',
        secret: 'SYNTHETIC_OWNER',
      );
      c = await service.owner.setCredentialEnabled(c.id, c.revision, false);
      expect(
        await service.owner.readStringCredential(c.id, c.version),
        'SYNTHETIC_OWNER',
      );
      expect(service.owner.credentialUseRequests, isEmpty);
      final file = await service.owner.createFileCredential(
        name: 'File',
        publicPurpose: '',
        fileName: 'synthetic.key',
        bytes: [1, 2, 3],
      );
      await expectLater(
        service.owner.readStringCredential(file.id, file.version),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'credential_form_mismatch',
          ),
        ),
      );
      await expectLater(
        service.agent.requestCredentialReveal(
          service.agent.openSession('synthetic'),
          revealInput(file.id),
        ),
        failure('invalid_reference'),
      );
      expect(
        () => CredentialRevealInput.fromJson({
          'protocolVersion': 2,
          'command': 'request-reveal',
          'credentialId': c.id,
          'version': 1,
          'purpose': 'test',
          'fallbackReason': ' ',
        }),
        failure('invalid_type'),
      );
    },
  );
}
