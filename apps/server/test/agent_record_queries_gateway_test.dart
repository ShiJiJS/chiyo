import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'server lists and recovers only the original device and private chat records',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final item = await f.runtime.run(
        () => f.runtime.service.owner.createInformation('Synthetic host', '', [
          const FieldInput('Host', '', 'PRIVATE-HOST'),
        ]),
      );
      final a = f.agents.first, b = f.agents.last;
      final opened = await a.call('/session/lifecycle', {
        'chatLabel': 'Same public label',
      });
      final session = opened['sessionSecret'] as String;
      final other = await a.call('/session/lifecycle', {
        'chatLabel': 'Same public label',
      });
      final submitted = await a.call('/request', {
        'sessionSecret': session,
        'purpose': 'Check host',
        'operationId': 'recover-1',
        'fields': [
          {'itemId': item.id, 'fieldId': item.fields.single.id},
        ],
      });
      expect(submitted['status'], 'pending');
      final list = await a.call('/requests/list', {'sessionSecret': session});
      expect(list['status'], 'ok');
      expect((list['records'] as List).single['id'], submitted['requestId']);
      expect(
        (await a.call('/requests/list', {
          'sessionSecret': other['sessionSecret'],
        }))['records'],
        isEmpty,
      );
      expect(
        (await b.call('/requests/list', {'sessionSecret': session}))['status'],
        'unauthorized',
      );
      expect(
        (await b.call('/operations/show', {
          'sessionSecret': session,
          'id': 'recover-1',
        }))['status'],
        'unauthorized',
      );
      final operation = await a.call('/operations/show', {
        'sessionSecret': session,
        'id': 'recover-1',
      });
      expect(operation['requestId'], submitted['requestId']);
      expect(operation.values, isNot(contains('PRIVATE-HOST')));
      expect(
        (await a.call('/proposals/list', {
          'sessionSecret': session,
        }))['records'],
        isEmpty,
      );
      expect(
        (await a.call('/session/close', {'sessionSecret': session}))['status'],
        'ended',
      );
      expect(
        (await a.call('/requests/list', {'sessionSecret': session}))['status'],
        'unauthorized',
      );
    },
  );
}
