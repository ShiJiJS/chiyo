import 'dart:io';
import 'package:info_cli/chiyo_cli.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'public CLI loses a real HTTPS submission reply, finds one request, and retries the same intent without renewal',
    () async {
      final f = await DeviceCredentialFixture.create(
        loseFirstPath: '/v1/agent/request',
      );
      addTearDown(f.dispose);
      final item = await f.runtime.run(
        () => f.runtime.service.owner.createInformation(
          'Synthetic service',
          '',
          [const FieldInput('Host', '', 'PRIVATE-HOST-CONTENT')],
        ),
      );
      final opened = await f.agents.first.call('/session/lifecycle', {
        'chatLabel': 'Synthetic CLI recovery',
      });
      final contextFile = File('${f.root.path}/private-chat/context.json');
      final context = ChiyoContext(
        chatId: 'synthetic-cli-chat',
        agentName: 'Trial Agent',
        secret: opened['sessionSecret'] as String,
        port: f.profiles.first.address.port,
        connection: f.profiles.first,
        endCapability: opened['endCapability'] as String,
      );
      await context.saveNew(contextFile);
      Future<ChiyoRunResult> call(List<String> args) => ChiyoCli(
        environment: {'CHIYO_CONTEXT': contextFile.path},
      ).run([...args, '--json']);
      final command = [
        'access',
        'request',
        '--item',
        item.id,
        '--field',
        item.fields.single.id,
        '--purpose',
        'Read the synthetic host',
        '--operation',
        'recover-public-request',
      ];
      final lost = await call(command);
      expect(lost.exitCode, 7, reason: lost.render());
      expect(
        (lost.output['data'] as Map)['operationId'],
        'recover-public-request',
      );
      expect(f.runtime.service.owner.informationRequests, hasLength(1));
      final original = f.runtime.service.owner.informationRequests.single;
      final operations = await call(['operations', 'list']);
      expect(operations.exitCode, 0, reason: operations.render());
      final remote =
          ((operations.output['data'] as Map)['records'] as List).single as Map;
      expect(remote['requestId'], original.id);
      final recovery = await call([
        'operations',
        'retry',
        'recover-public-request',
      ]);
      expect(recovery.exitCode, 0, reason: recovery.render());
      expect((recovery.output['data'] as Map)['requestId'], original.id);
      expect(f.runtime.service.owner.informationRequests, hasLength(1));
      expect(
        f.runtime.service.owner.informationRequests.single.requestExpiresAt,
        original.requestExpiresAt,
      );
      expect(recovery.render(), isNot(contains('PRIVATE-HOST-CONTENT')));
      expect(recovery.render(), isNot(contains(context.secret)));
      final changed = await call([
        ...command,
        '--purpose',
        'Different content',
      ]);
      expect(changed.exitCode, 8);
      expect(f.runtime.service.owner.informationRequests, hasLength(1));
      final ownState = await call(['requests', 'show', original.id]);
      expect(ownState.exitCode, 0);
      expect((ownState.output['data'] as Map)['status'], 'pending');
    },
  );
}
