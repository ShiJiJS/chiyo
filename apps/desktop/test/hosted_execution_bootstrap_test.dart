import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'support/desktop_platform_fixture.dart';

void main() {
  test(
    'desktop advertises reuse and accepts default v2 CLI requests through its production bootstrap',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(path, 1, 1, 'sha256:synthetic'),
      );
      final bootstrap = DesktopBootstrap(
        port: 0,
        platform: NativeDesktopFixture(),
        openLibrary: () async =>
            DesktopLibrary(service: service, close: () async {}),
      );
      addTearDown(() async {
        await bootstrap.runtime?.stop();
        bootstrap.dispose();
      });
      await bootstrap.start();
      expect(bootstrap.state, DesktopStartupState.ready);
      final client = AgentClient(bootstrap.boundPort!);
      addTearDown(client.close);
      final capability = await client.execute({'command': 'capabilities'});
      expect(capability['protocolVersions'], contains(2));
      expect(capability['capabilities'], contains('credential-use-reuse.v1'));
      await client.execute({
        'command': 'session',
        'chatLabel': 'Default desktop v2',
      });
      var c = await service.owner.createStringCredential(
        name: 'Synthetic desktop v2',
        publicPurpose: '',
        secret: 'synthetic-token',
      );
      c = await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'GH_TOKEN',
        discoverable: true,
      );
      final result = await client.execute({
        'command': 'request-use',
        'purpose': 'Verify default desktop v2',
        'credentials': [
          {'alias': 'token', 'credentialId': c.id, 'version': 1},
        ],
        'launch': {
          'receiver': 'gh_token',
          'executable': Platform.resolvedExecutable,
          'argv': ['api', 'user'],
          'cwd': Directory.current.path,
          'env': {
            'GH_TOKEN': {'secret': 'token'},
          },
        },
      });
      expect(result['status'], 'pending');
      expect(service.owner.credentialUseRequests.single.protocolVersion, 2);
      await service.owner.decideCredentialUse(
        result['requestId'] as String,
        approveCredential: true,
      );
      final status = await client.execute({
        'command': 'status',
        'requestId': result['requestId'],
      });
      expect((status['decision'] as Map)['credentialUse']['reusable'], isTrue);
      expect(
        (status['decision'] as Map)['credentialUse'].containsKey('maxAttempts'),
        isFalse,
      );
    },
    skip: !Platform.isWindows && !Platform.isMacOS,
  );
  test(
    'desktop bootstrap exposes authorized hosted execution facts and removes the endpoint on shutdown',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(path, 1, 1, 'sha256:synthetic'),
      );
      final bootstrap = DesktopBootstrap(
        port: 0,
        platform: NativeDesktopFixture(),
        openLibrary: () async =>
            DesktopLibrary(service: service, close: () async {}),
      );
      addTearDown(() async {
        await bootstrap.runtime?.stop();
        bootstrap.dispose();
      });
      await bootstrap.start();
      expect(bootstrap.state, DesktopStartupState.ready);
      var credential = await service.owner.createStringCredential(
        name: 'Synthetic bootstrap',
        publicPurpose: '',
        secret: 'synthetic-token',
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'GH_TOKEN',
        discoverable: true,
      );
      final session = service.agent.openSession('Bootstrap hosted status');
      final request = await service.agent.requestCredentialUse(
        session,
        CredentialUseInput.fromJson({
          'protocolVersion': 1,
          'command': 'request-use',
          'purpose': 'Verify resident endpoint',
          'credentials': [
            {'alias': 'token', 'credentialId': credential.id, 'version': 1},
          ],
          'launch': {
            'receiver': 'gh_token',
            'executable': Platform.resolvedExecutable,
            'argv': ['api', 'user'],
            'cwd': Directory.current.path,
            'env': {
              'GH_TOKEN': {'secret': 'token'},
            },
          },
        }),
      );
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      final material = await service.agent.consumeCredentialUse(
        session,
        request.id,
      );
      await service.agent.reportCredentialExecution(
        CredentialExecutionReport(
          executionId: material.executionId,
          executionCapability: material.executionCapability,
          state: 'prepare_failed',
          errorCode: 'material_prepare_failed',
          finishedAt: DateTime.now().toUtc(),
        ),
      );
      final client = AgentClient(
        bootstrap.boundPort!,
        sessionSecret: session,
        hostedCredentialExecutions: true,
      );
      addTearDown(client.close);
      final status = await client.execute({
        'command': 'execution-status',
        'executionId': material.executionId,
      });
      expect(status['executionState'], 'prepare_failed');
      expect(status['attemptConsumed'], isTrue);
      expect(status['outputAvailable'], isFalse);
      await bootstrap.runtime!.stop();
      expect(
        (await client.execute({
          'command': 'execution-status',
          'executionId': material.executionId,
        }))['status'],
        'service_unavailable',
      );
    },
  );
}
