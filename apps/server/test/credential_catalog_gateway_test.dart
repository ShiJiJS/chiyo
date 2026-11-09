import 'dart:convert';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'current ordinary and credential template examples distinguish candidate key from pending itemKey',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final templates =
          (await f.agents.first.call('/templates/catalog', {}))['templates']
              as List;
      final kinds = <String>{};
      for (final row in templates.cast<Map>().where(
        (t) => t['enabled'] == true && t['hasGuidance'] == true,
      )) {
        final description =
            (await f.agents.first.call('/templates/read', {
                  'templateId': row['id'],
                }))['template']
                as Map;
        kinds.add(description['recordKind'] as String);
        final examples =
            description['submissionExamples'] as List? ??
            [description['submissionExample']];
        for (final example in examples.cast<Map>()) {
          final item = (example['items'] as List).single as Map;
          expect(item['key'], isA<String>());
          expect(item.containsKey('itemKey'), false);
          expect(example['operationId'], isA<String>());
          expect(
            (description['candidateIdentity'] as Map)['field'],
            'items[].key',
          );
          expect(
            ((description['relationInput'] as Map)['pendingTarget'] as Map)
                .containsKey('itemKey'),
            true,
          );
        }
      }
      expect(kinds, containsAll(['information', 'credential']));
    },
  );

  test(
    'authenticated remote CLI discovers only opted-in credential metadata without a chat or material access',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final visible = await f.runtime.run(() async {
        final c = await f.runtime.service.owner.createStringCredential(
          name: 'Visible synthetic token',
          publicPurpose: 'Synthetic service API',
          secret: 'SYNTHETIC_CATALOG_TOKEN_NEVER_PUBLIC',
        );
        return f.runtime.service.owner.updateCredentialMetadata(
          c.id,
          c.revision,
          name: c.name,
          publicPurpose: c.publicPurpose,
          privateNote: 'SYNTHETIC_PRIVATE_NOTE_NEVER_PUBLIC',
          suggestedBinding: 'api_token',
          discoverable: true,
        );
      });
      await f.runtime.run(
        () => f.runtime.service.owner.createStringCredential(
          name: 'Hidden synthetic credential',
          publicPurpose: 'Not discoverable',
          secret: 'SYNTHETIC_HIDDEN_TOKEN_NEVER_PUBLIC',
        ),
      );
      final client = AgentClient.remote(f.profiles.first);
      addTearDown(client.close);
      final result = await client.execute({'command': 'credential-catalog'});
      expect(result['status'], 'ok');
      final rows = result['credentials'] as List;
      expect(rows, hasLength(1));
      expect(rows.single['credentialId'], visible.id);
      final encoded = jsonEncode(result);
      for (final hidden in [
        'SYNTHETIC_CATALOG_TOKEN_NEVER_PUBLIC',
        'SYNTHETIC_PRIVATE_NOTE_NEVER_PUBLIC',
        'SYNTHETIC_HIDDEN_TOKEN_NEVER_PUBLIC',
        'Hidden synthetic credential',
      ]) {
        expect(encoded, isNot(contains(hidden)));
      }
      expect(client.sessionSecret, isNull);
      expect(
        (await client.execute({
          'command': 'credential-catalog',
          'limit': 0,
        }))['status'],
        'invalid_request',
      );
      await f.owner.request(
        'POST',
        '/v1/owner/devices/${f.profiles.first.deviceToken.split('.').first}/revoke',
        {'operationId': 'revoke-catalog-device'},
      );
      expect(
        (await client.execute({'command': 'credential-catalog'}))['status'],
        isNot('ok'),
      );
    },
  );
}
