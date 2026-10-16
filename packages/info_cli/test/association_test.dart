import 'package:info_cli/agent_client.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a private association resumes requests through the generic client',
    () async {
      final core = InformationService.fictional();
      final server = await AgentServer.start(core.agent, port: 0);
      final client = AgentClient(
        server.port,
        sessionSecret: core.agent.openSession('independent-label'),
      );
      addTearDown(() async {
        client.close();
        await server.close();
        core.close();
      });
      final result = await client.execute({
        'command': 'request',
        'purpose': 'test',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
        ],
      });
      expect(result['status'], 'pending');
      expect(result.containsKey('sessionSecret'), false);
      expect(core.owner.requests.single.chatLabel, 'independent-label');
    },
  );
}
