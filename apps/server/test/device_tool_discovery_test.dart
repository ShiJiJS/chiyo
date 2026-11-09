import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'remote CLI adds device-local tool observations without asking the server for device paths',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final direct = await f.agents.first.call('/capabilities', {});
      expect(direct.containsKey('credentialTools'), false);
      expect(direct['capabilities'], isNot(contains('credential-tools.v1')));
      final cli = AgentClient.remote(f.profiles.first);
      addTearDown(cli.close);
      final capabilities = await cli.execute({'command': 'capabilities'});
      expect(capabilities['status'], 'ok');
      expect(
        capabilities['capabilities'],
        contains('credential-device-execution.v1'),
      );
      if (Platform.isMacOS) {
        expect(capabilities['credentialToolScope'], 'current_device');
        expect(capabilities['capabilities'], contains('credential-tools.v1'));
        final tools = capabilities['credentialTools'] as List;
        expect(tools, hasLength(3));
        final ssh = tools.cast<Map>().singleWhere(
          (t) => t['receiver'] == 'ssh_identity',
        );
        expect(ssh['executable'], '/usr/bin/ssh');
        expect(jsonEncode(tools), isNot(contains(f.root.path)));
      } else {
        expect(capabilities.containsKey('credentialTools'), false);
      }
      expect(cli.sessionSecret, isNull);
    },
  );
}
