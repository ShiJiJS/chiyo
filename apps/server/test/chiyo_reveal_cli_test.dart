import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chiyo_cli.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

Future<(File, String)> _prepare(DeviceCredentialFixture f) async {
  final credential = await f.runtime.run(() async {
    final c = await f.runtime.service.owner.createStringCredential(
      name: 'Synthetic fallback',
      publicPurpose: '',
      secret: 'PRIVATE-SYNTHETIC-REVEAL',
    );
    return f.runtime.service.owner.updateCredentialMetadata(
      c.id,
      c.revision,
      name: c.name,
      publicPurpose: '',
      privateNote: '',
      suggestedBinding: 'TOKEN',
      discoverable: true,
    );
  });
  final opened = await f.agents.first.call('/session/lifecycle', {
    'chatLabel': 'Synthetic public reveal',
  });
  final file = File('${f.root.path}/cli-chat/context.json');
  await ChiyoContext(
    chatId: 'synthetic-reveal',
    agentName: 'Trial Agent',
    secret: opened['sessionSecret'] as String,
    port: f.profiles.first.address.port,
    connection: f.profiles.first,
  ).saveNew(file);
  return (file, credential.id);
}

List<String> _request(String id) => [
  'credentials',
  'reveal',
  'request',
  '--credential',
  id,
  '--purpose',
  'Sign into synthetic service',
  '--reason',
  'Synthetic target cannot accept direct input',
  '--operation',
  'submit-reveal',
];
void main() {
  test(
    'reveal submission lost reply and restart retain one fixed request without renewing or restoring a grant',
    () async {
      final f = await DeviceCredentialFixture.create(
        loseFirstPath: '/v1/agent/credential-reveal/request',
      );
      addTearDown(f.dispose);
      final (file, credential) = await _prepare(f);
      Future<ChiyoRunResult> call(List<String> args) => ChiyoCli(
        environment: {'CHIYO_CONTEXT': file.path},
      ).run([...args, '--json']);
      final unknown = await call(_request(credential));
      expect(unknown.exitCode, 7, reason: unknown.render());
      final original = f.runtime.service.owner.credentialUseRequests.single;
      final expiry = original.requestExpiresAt.millisecondsSinceEpoch;
      expect(original.submissionOperationId, 'submit-reveal');
      final recovered = await call(['operations', 'retry', 'submit-reveal']);
      expect(recovered.exitCode, 0, reason: recovered.render());
      expect((recovered.output['data'] as Map)['requestId'], original.id);
      await f.reopen();
      final shown = await call(['operations', 'show', 'submit-reveal']);
      expect(shown.exitCode, 0, reason: shown.render());
      expect((shown.output['data'] as Map)['requestId'], original.id);
      final repeated = await call(_request(credential));
      expect(repeated.exitCode, 0, reason: repeated.render());
      expect(f.runtime.service.owner.credentialUseRequests, hasLength(1));
      expect(
        f
            .runtime
            .service
            .owner
            .credentialUseRequests
            .single
            .requestExpiresAt
            .millisecondsSinceEpoch,
        expiry,
      );
      expect(
        f.runtime.service.owner.credentialGrantState(
          f.runtime.service.owner.credentialUseRequests.single,
        ),
        isNot('available'),
      );
      expect(shown.render(), isNot(contains('PRIVATE-SYNTHETIC-REVEAL')));
      final seed = await f.runtime.run(
        () => f.runtime.service.owner.createInformation(
          'Synthetic read target',
          '',
          [const FieldInput('Host', '', 'synthetic.invalid')],
        ),
      );
      final private = await ChiyoContext.load(file, environment: {});
      final collision = await f.agents.first.call('/request', {
        'sessionSecret': private.secret,
        'purpose': 'Synthetic unrelated read',
        'fields': [
          {'itemId': seed.id, 'fieldId': seed.fields.single.id},
        ],
        'operationId': 'submit-reveal',
      });
      expect(collision['status'], 'operation_conflict');

      expect(
        shown.render(),
        isNot(contains(original.submissionSessionBinding!)),
      );
      await f.runtime.run(() {
        final c = f.runtime.service.owner.credential(credential);
        return f.runtime.service.owner.rotateStringCredential(
          c.id,
          c.revision,
          'PRIVATE-SYNTHETIC-ROTATED',
        );
      });
      final rotated = await call(_request(credential));
      expect(rotated.exitCode, 0, reason: rotated.render());
      expect((rotated.output['data'] as Map)['requestId'], original.id);
      expect(f.runtime.service.owner.credentialUseRequests.single.version, 1);
      final changed = await call([..._request(credential), '--version', '2']);
      expect(changed.exitCode, 8);
      expect(f.runtime.service.owner.credentialUseRequests, hasLength(1));
    },
  );
  test(
    'plaintext read lost reply records once; retry and status never return material',
    () async {
      final f = await DeviceCredentialFixture.create(
        loseFirstPath: '/v1/agent/credential-reveal/read',
      );
      addTearDown(f.dispose);
      final (file, credential) = await _prepare(f);
      Future<ChiyoRunResult> call(List<String> args) => ChiyoCli(
        environment: {'CHIYO_CONTEXT': file.path},
      ).run([...args, '--json']);
      final requested = await call(_request(credential));
      expect(requested.exitCode, 0, reason: requested.render());
      final id = (requested.output['data'] as Map)['requestId'] as String;
      final read = [
        'credentials',
        'reveal',
        'read',
        '--request',
        id,
        '--operation',
        'read-once',
      ];
      final pending = await call(read);
      expect(pending.exitCode, 4, reason: pending.render());
      expect(
        f.runtime.service.owner.credentialUseRequests.single.revealReads,
        isEmpty,
      );
      await f.runtime.run(
        () => f.runtime.service.owner.decideCredentialUse(
          id,
          approveCredential: true,
        ),
      );
      final lost = await call(read);
      expect(lost.exitCode, 7, reason: lost.render());
      expect(
        f.runtime.service.owner.credentialUseRequests.single.revealReads,
        hasLength(1),
      );
      final retry = await call(['operations', 'retry', 'read-once']);
      expect(retry.exitCode, 7, reason: retry.render());
      expect((retry.output['data'] as Map)['readRecorded'], true);
      expect((await call(read)).exitCode, 7);
      expect(
        f.runtime.service.owner.credentialUseRequests.single.revealReads,
        hasLength(1),
      );
      final history = await call(['operations', 'show', 'read-once']);
      expect(history.exitCode, 0);
      expect((history.output['data'] as Map)['state'], 'completed');
      for (final result in [requested, lost, retry, history])
        expect(result.render(), isNot(contains('PRIVATE-SYNTHETIC-REVEAL')));
      final successful = await call([
        'credentials',
        'reveal',
        'read',
        '--request',
        id,
        '--operation',
        'explicit-new-read',
      ]);
      expect(successful.exitCode, 0, reason: successful.render());
      expect(
        (successful.output['data'] as Map)['secret'],
        'PRIVATE-SYNTHETIC-REVEAL',
      );
      await for (final entity in file.parent.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.json'))
          expect(
            await entity.readAsString(),
            isNot(contains('PRIVATE-SYNTHETIC-REVEAL')),
          );
      }
      await f.runtime.run(
        () => f.runtime.service.owner.revokeCredentialUse(id),
      );
      final revoked = await call([
        'credentials',
        'reveal',
        'read',
        '--request',
        id,
        '--operation',
        'after-revoke',
      ]);
      expect(revoked.exitCode, 4, reason: revoked.render());
      expect(
        f.runtime.service.owner.credentialUseRequests.single.revealReads,
        hasLength(2),
      );
      expect(
        jsonEncode(
          f.runtime.service.owner.credentialUseRequests.single.toJson(),
        ),
        isNot(contains('submissionOperation')),
      );
    },
  );
}
