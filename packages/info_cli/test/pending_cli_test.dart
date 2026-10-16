import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'CLI cancellation is scoped to session and rejected states are final',
    () async {
      var now = DateTime.utc(2026, 10, 16);
      final core = InformationService.fictional(clock: () => now);
      final server = await AgentServer.start(core.agent, port: 0);
      final client = AgentClient(server.port);
      final other = AgentClient(server.port);
      addTearDown(() async {
        client.close();
        other.close();
        await server.close();
        core.close();
      });
      await client.execute({'command': 'session', 'chatLabel': 'chat'});
      await other.execute({'command': 'session', 'chatLabel': 'other'});
      final request = await client.execute({
        'command': 'request',
        'purpose': 'demo',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
        ],
      });
      final id = request['requestId'];
      expect(
        (await other.execute({'command': 'cancel', 'requestId': id}))['status'],
        'unauthorized',
      );
      expect(
        (await client.execute({
          'command': 'cancel',
          'requestId': id,
        }))['status'],
        'cancelled',
      );
      expect(
        (await client.execute({'command': 'wait', 'requestId': id}))['status'],
        'cancelled',
      );
      expect(core.owner.requests, hasLength(1));
      final denied = await client.execute({
        'command': 'request',
        'purpose': 'demo',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
        ],
      });
      core.owner.deny(denied['requestId'] as String);
      expect(
        (await client.execute({
          'command': 'wait',
          'requestId': denied['requestId'],
        }))['status'],
        'denied',
      );
      final expired = await client.execute({
        'command': 'request',
        'purpose': 'demo',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
        ],
      });
      now = now.add(const Duration(minutes: 30));
      expect(
        (await client.execute({
          'command': 'wait',
          'requestId': expired['requestId'],
        }))['status'],
        'expired',
      );
      expect(core.owner.requests, hasLength(3));
    },
  );
}
