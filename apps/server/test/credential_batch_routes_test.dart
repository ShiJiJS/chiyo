import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

const base = '/credential-use/batch';
const ownerBase = '/v1/owner/credential-batches';
const password = 'Synthetic-batch-password-中文😀';

Map<String, dynamic> target(String page) => {
  'via': 'ego',
  'target': {
    'provider': 'ego',
    'instanceId': 'synthetic-browser',
    'space': 7,
    'pageId': page,
    'url': 'https://synthetic.test/login',
    'form': '#login',
    'field': '#password',
    'structureDigest': 'a' * 64,
  },
};

void noPrivate(Object value) {
  final text = jsonEncode(value);
  for (final hidden in [
    password,
    'privateProof',
    'sessionBinding',
    'submissionDigest',
    'materialBase64',
    'useGeneration',
  ]) {
    expect(text, isNot(contains(hidden)));
  }
}

void main() {
  test(
    'HTTPS multi-credential request, partial decision, original device and one-time App material',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final a = f.agents.first, b = f.agents.last;
      final chat = await a.call('/session/lifecycle', {
        'chatLabel': 'Same public chat',
      });
      final session = chat['sessionSecret'] as String;
      final stranger = (await a.call('/session/lifecycle', {
        'chatLabel': 'Same public chat',
      }))['sessionSecret'];
      final credentials = await f.runtime.run(() async {
        final values = <ManagedCredential>[];
        for (var i = 0; i < 2; i++) {
          final c = await f.runtime.service.owner.createStringCredential(
            name: 'Synthetic service $i',
            publicPurpose: '',
            secret: password,
          );
          values.add(
            await f.runtime.service.owner.updateCredentialMetadata(
              c.id,
              c.revision,
              name: c.name,
              publicPurpose: '',
              privateNote: '',
              suggestedBinding: 'password',
              discoverable: true,
            ),
          );
        }
        return values;
      });
      final input = {
        'protocolVersion': 3,
        'submissionVersion': 1,
        'agentName': 'CLI trial',
        'externalChatId': 'same-public-id',
        'purpose': 'Sign into synthetic services',
        'items': [
          for (final (index, c) in credentials.indexed)
            {
              'credentialId': c.id,
              'version': c.version,
              'destination': target('p${index + 1}'),
            },
        ],
      };
      final submission = {
        'sessionSecret': session,
        'operationId': 'submit-many',
        'input': input,
      };
      final submitted = await a.call('$base/request', submission);
      expect(submitted['status'], 'pending', reason: '$submitted');
      expect(submitted['protocolVersion'], 3);
      final id = submitted['requestId'] as String;
      noPrivate(submitted);
      expect(await a.call('$base/request', submission), submitted);
      expect(
        (await a.call('$base/request', {
          ...submission,
          'deviceId': 'forged',
        }))['errorCode'],
        'unknown_field',
      );
      expect(
        (await b.call('$base/status', {
          'sessionSecret': session,
          'requestId': id,
        }))['status'],
        'unauthorized',
      );
      expect(
        (await a.call('$base/status', {
          'sessionSecret': stranger,
          'requestId': id,
        }))['status'],
        'unauthorized',
      );
      final review = await f.owner.request('GET', '$ownerBase/$id');
      expect(review['state'], 'pending');
      expect((review['items'] as List).length, 2);
      noPrivate(review);
      final decision = {
        'operationId': 'decide-many',
        'revision': 1,
        'approvedItems': ['b1'],
        'lifetimeSeconds': 7200,
      };
      final decided = await f.owner.request(
        'POST',
        '$ownerBase/$id/decide',
        decision,
      );
      expect(decided['state'], 'partially_approved');
      expect(
        await f.owner.request('POST', '$ownerBase/$id/decide', decision),
        decided,
      );
      noPrivate(decided);
      final blocked = await a.call('$base/begin', {
        'sessionSecret': session,
        'requestId': id,
        'operationId': 'needs-both',
      });
      expect(blocked['errorCode'], 'scope_not_approved');
      final operation = {
        'sessionSecret': session,
        'requestId': id,
        'operationId': 'use-a',
        'itemIds': ['b1'],
      };
      final claim = await a.call('$base/begin', operation);
      expect(claim['privateProof'], isA<String>());
      final proof = claim['privateProof'] as String;
      final duplicate = await a.call('$base/begin', operation);
      expect(duplicate, isNot(contains('privateProof')));
      noPrivate(duplicate);
      expect(
        (await b.call('$base/authorize', {'privateProof': proof}))['status'],
        'unauthorized',
      );
      expect(
        (await a.call('$base/material', {
          'privateProof': proof,
          'observations': {'b1': target('p2')},
        }))['errorCode'],
        'destination_changed',
      );
      final material = await a.call('$base/material', {
        'privateProof': proof,
        'observations': {'b1': target('p1')},
      });
      expect(material['status'], 'ok');
      expect(
        utf8.decode(
          base64Decode((material['materials'] as Map)['b1'] as String),
        ),
        password,
      );
      expect(
        (await a.call('$base/material', {
          'privateProof': proof,
          'observations': {'b1': target('p1')},
        }))['errorCode'],
        'execution_unknown',
      );
      expect(
        (await a.call('$base/authorize', {'privateProof': proof}))['status'],
        'ok',
      );
      final finished = await a.call('$base/finish', {
        'privateProof': proof,
        'state': 'filled',
        'itemResults': {'b1': 'filled'},
        'errorCode': null,
      });
      expect(finished['executionState'], 'filled', reason: '$finished');
      noPrivate(finished);
      final status = await a.call('$base/operation', {
        'sessionSecret': session,
        'operationId': 'use-a',
      });
      expect(status, finished);
      noPrivate(status);
      final list = await a.call('/requests/list', {'sessionSecret': session});
      expect((list['records'] as List).single['id'], id);
      final ownerRequests = await f.owner.request('GET', ownerBase);
      noPrivate(ownerRequests);
      final revocation = await f.owner.request(
        'POST',
        '$ownerBase/$id/revoke',
        {
          'operationId': 'revoke-a',
          'revision': 2,
          'itemIds': ['b1'],
        },
      );
      expect((revocation['items'] as List).first['grantState'], 'revoked');
      expect(
        (await a.call('$base/begin', {
          ...operation,
          'operationId': 'again',
        }))['errorCode'],
        'scope_not_approved',
      );
      final http = HttpClient(context: f.trust);
      addTearDown(() => http.close(force: true));
      for (final route in [ownerBase, '$ownerBase/$id']) {
        final request = await http.getUrl(f.owner.address.resolve(route));
        request.headers.set(
          'authorization',
          'Bearer ${f.profiles.first.deviceToken}',
        );
        final response = await request.close();
        expect(response.statusCode, 401);
        await response.drain<void>();
      }
      final capabilities =
          (await a.call('/capabilities', {}))['capabilities'] as List;
      expect(
        capabilities,
        containsAll([
          'agent-record-queries.v1',
          'credential-catalog-search.v1',
        ]),
      );
      // v3 is deliberately not advertised until the shipped App UI/Host can run it.
      expect(capabilities, isNot(contains('credential-batches.v3')));
    },
  );

  test(
    'lost first execution reply never mints another proof; owner acknowledges unknown without changing history',
    () async {
      var now = DateTime.utc(2026, 11, 13);
      final f = await DeviceCredentialFixture.create(
        loseFirstPath: '/v1/agent$base/begin',
        clock: () => now,
      );
      addTearDown(f.dispose);
      final a = f.agents.first;
      final chat = await a.call('/session/lifecycle', {
        'chatLabel': 'Synthetic lost reply',
      });
      final session = chat['sessionSecret'];
      final c = await f.runtime.run(() async {
        final owner = f.runtime.service.owner;
        final c = await owner.createStringCredential(
          name: 'Synthetic service',
          publicPurpose: '',
          secret: password,
        );
        return owner.updateCredentialMetadata(
          c.id,
          c.revision,
          name: c.name,
          publicPurpose: '',
          privateNote: '',
          suggestedBinding: 'password',
          discoverable: true,
        );
      });
      final submitted = await a.call('$base/request', {
        'sessionSecret': session,
        'operationId': 'submit-lost',
        'input': {
          'protocolVersion': 3,
          'purpose': 'Synthetic lost execution reply',
          'items': [
            {'credentialId': c.id, 'destination': target('p1')},
          ],
        },
      });
      final id = submitted['requestId'];
      await f.owner.request('POST', '$ownerBase/$id/decide', {
        'operationId': 'approve-lost',
        'revision': 1,
        'approvedItems': ['b1'],
        'lifetimeSeconds': 7200,
      });
      final operation = {
        'sessionSecret': session,
        'requestId': id,
        'operationId': 'lost-use',
      };
      expect(
        (await a.call('$base/begin', operation))['status'],
        'service_unavailable',
      );
      final duplicate = await a.call('$base/begin', operation);
      noPrivate(duplicate);
      expect(duplicate['executionState'], 'checking');
      now = now.add(const Duration(seconds: 31));
      final unknown = await a.call('$base/operation', {
        'sessionSecret': session,
        'operationId': 'lost-use',
      });
      expect(unknown['executionState'], 'unknown');
      expect(unknown['finishedAt'], null);
      expect(
        (await a.call('$base/begin', {
          ...operation,
          'operationId': 'bad-retry',
        }))['errorCode'],
        'fill_needs_attention',
      );
      final ownerReview = await f.owner.request('GET', '$ownerBase/$id');
      expect(
        ((ownerReview['operations'] as List).single as Map)['executionState'],
        'unknown',
      );
      final ack = {
        'operationId': 'owner-checked-target',
        'revision':
            ((ownerReview['operations'] as List).single as Map)['revision'],
      };
      final acknowledged = await f.owner.request(
        'POST',
        '$ownerBase/$id/operations/lost-use/acknowledge',
        ack,
      );
      expect(acknowledged['executionState'], 'unknown');
      expect(acknowledged['finishedAt'], null);
      expect(
        await f.owner.request(
          'POST',
          '$ownerBase/$id/operations/lost-use/acknowledge',
          ack,
        ),
        acknowledged,
      );
      noPrivate(acknowledged);
      final explicitNew = await a.call('$base/begin', {
        ...operation,
        'operationId': 'explicit-new-use',
      });
      expect(explicitNew['privateProof'], isA<String>());
      expect(
        (await a.call('$base/begin', operation)),
        isNot(contains('privateProof')),
      );
    },
  );
}
