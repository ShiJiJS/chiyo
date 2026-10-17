import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'private Token material launches a real controlled process and exposes only bounded execution events',
    () async {
      final executable = File(Platform.resolvedExecutable);
      final stat = await executable.stat();
      final service = InformationService(
        repository: MemoryInformationRepository(),
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(
              path,
              stat.size,
              stat.modified.microsecondsSinceEpoch,
              'sha256:${sha256.convert(await executable.readAsBytes())}',
            ),
      );
      final server = await AgentServer.start(service.agent, port: 0);
      final client = AgentClient(
        server.port,
        credentialProcessStarter: (executable, argv, cwd, environment) =>
            Process.start(
              executable,
              [
                File('test/support/credential_child.dart').absolute.path,
                ...argv,
              ],
              workingDirectory: cwd,
              environment: environment,
              includeParentEnvironment: false,
              runInShell: false,
            ),
      );
      addTearDown(() async {
        await client.drainCredentialExecutions();
        client.close();
        await server.close();
        await service.close();
      });
      var c = await service.owner.createStringCredential(
        name: 'Synthetic',
        publicPurpose: 'Synthetic task',
        secret: 'synthetic-token',
      );
      c = await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: c.publicPurpose,
        privateNote: '',
        suggestedBinding: 'GH_TOKEN',
        discoverable: true,
      );
      expect(
        await client.execute({
          'command': 'session',
          'chatLabel': 'Synthetic process',
        }),
        {'status': 'ok'},
      );
      final request = await client.execute({
        'command': 'request-use',
        'purpose': 'Verify isolated process',
        'credentials': [
          {'alias': 'token', 'credentialId': c.id, 'version': 1},
        ],
        'launch': {
          'receiver': 'gh_token',
          'executable': executable.path,
          'argv': ['api', 'user', '--method', 'GET'],
          'cwd': Directory.current.path,
          'env': {
            'GH_TOKEN': {'secret': 'token'},
          },
        },
      });
      expect(request['status'], 'pending');
      final id = request['requestId'] as String;
      await service.owner.decideCredentialUse(id, approveCredential: true);
      final accepted = await client.execute({
        'command': 'run-use',
        'requestId': id,
      });
      expect(accepted['status'], 'accepted');
      expect(accepted['processStarted'], isFalse);
      expect(jsonEncode(accepted), isNot(contains('synthetic-token')));
      expect(
        (await client.execute({
          'command': 'run-use',
          'requestId': id,
        }))['errorCode'],
        'attempt_consumed',
      );
      final executionId = accepted['executionId'] as String;
      await client.drainCredentialExecutions();
      final status = await client.execute({
        'command': 'execution-status',
        'executionId': executionId,
      });
      expect(status['executionState'], 'exited');
      expect(status['exitCode'], 0);
      expect(status['cleanupState'], 'not_needed');
      final output = await client.execute({
        'command': 'execution-output',
        'executionId': executionId,
        'cursor': 0,
        'limit': 16,
      });
      expect(output['outputComplete'], isTrue);
      final chunks = output['chunks'] as List;
      final text = utf8.decode([
        for (final dynamic c in chunks)
          ...base64Decode(c['dataBase64'] as String),
      ]);
      expect(jsonDecode(text), {
        'tokenMatches': true,
        'argsMatch': true,
        'privateConfig': true,
        'sessionAbsent': true,
      });
      expect(
        jsonEncode(service.owner.credentialExecutions.single.toJson()),
        isNot(contains('synthetic-token')),
      );
    },
  );
}
