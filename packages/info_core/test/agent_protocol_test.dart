import 'dart:convert';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'standalone protocol reuses approval rules without a listening port or owner routes',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository([]),
      );
      addTearDown(service.close);
      final item = await service.owner.createInformation(
        'Synthetic metadata',
        'Public purpose',
        [const FieldInput('Address', '', 'PRIVATE_SYNTHETIC_VALUE')],
      );
      final protocol = AgentProtocol(service.agent);
      final catalog = await protocol.dispatch('/catalog', {});
      expect(catalog['status'], 'ok');
      expect(jsonEncode(catalog).contains('PRIVATE_SYNTHETIC_VALUE'), isFalse);
      await expectLater(
        protocol.dispatch('/approve', {}),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'unauthorized',
          ),
        ),
      );
      final session = await protocol.dispatch('/session/lifecycle', {
        'chatLabel': 'Synthetic protocol flow',
      });
      final secret = session['sessionSecret'] as String;
      final request = await protocol.dispatch('/request', {
        'sessionSecret': secret,
        'operationId': 'request-once',
        'purpose': 'Synthetic authorized read',
        'fields': [
          {'itemId': item.id, 'fieldId': item.fields.single.id},
        ],
      });
      expect(service.owner.requests, hasLength(1));
      await expectLater(
        protocol.dispatch('/claim', {
          'sessionSecret': secret,
          'requestId': request['requestId'],
        }),
        throwsA(
          isA<AccessFailure>().having((e) => e.status, 'status', 'pending'),
        ),
      );
      service.owner.approve(request['requestId'] as String, [
        FieldRef(item.id, item.fields.single.id),
      ]);
      final grant = await protocol.dispatch('/claim', {
        'sessionSecret': secret,
        'requestId': request['requestId'],
      });
      expect(
        (await protocol.dispatch('/read', {
          'token': grant['token'],
          'itemId': item.id,
          'fieldId': item.fields.single.id,
        }))['value'],
        'PRIVATE_SYNTHETIC_VALUE',
      );
      await protocol.dispatch('/session/end', {
        'endCapability': session['endCapability'],
      });
      await expectLater(
        protocol.dispatch('/read', {
          'token': grant['token'],
          'itemId': item.id,
          'fieldId': item.fields.single.id,
        }),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
}
