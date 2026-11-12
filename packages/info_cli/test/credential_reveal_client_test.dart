import 'dart:convert';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'CLI only delivers saved plaintext after separately approving reveal',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      var c = await service.owner.createStringCredential(
        name: 'Synthetic saved',
        publicPurpose: '',
        secret: 'SYNTHETIC_REVEAL_CLI',
      );
      c = await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'TOKEN',
        discoverable: true,
      );
      final server = await AgentServer.start(
        service.agent,
        port: 0,
        enableReusableCredentialUse: true,
      );
      final cli = AgentClient(server.port);
      addTearDown(() async {
        cli.close();
        await server.close();
        await service.close();
      });
      await cli.execute({
        'command': 'session',
        'externalChatId': 'synthetic-reveal-client',
        'chatLabel': 'Synthetic reveal',
      });
      final caps = await cli.execute({'command': 'capabilities'});
      expect(caps['capabilities'], contains('credential-reveal.v1'));
      expect(caps['supportedCredentialReceivers'], contains('program_stdin'));
      final pending = await cli.execute({
        'command': 'request-reveal',
        'protocolVersion': 2,
        'credentialId': c.id,
        'version': c.version,
        'purpose': 'Synthetic login',
        'fallbackReason': 'No focused input or program receiver is available',
      });
      expect(pending['status'], 'pending');
      expect(jsonEncode(pending), isNot(contains('SYNTHETIC_REVEAL_CLI')));
      final input = {
        'command': 'read-reveal',
        'protocolVersion': 2,
        'requestId': pending['requestId'],
        'operationId': 'read-1',
      };
      expect((await cli.execute(input))['errorCode'], 'request_pending');
      await service.owner.decideCredentialUse(
        pending['requestId'] as String,
        approveCredential: true,
      );
      expect((await cli.execute(input))['secret'], 'SYNTHETIC_REVEAL_CLI');
      expect((await cli.execute(input))['errorCode'], 'attempt_consumed');
      expect(service.owner.credentialUseRequests.single.revealReads.length, 1);
    },
  );
}
