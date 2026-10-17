import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a transient running audit failure does not stop monitoring a live process',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'runtime-monitor-test-',
      );
      final release = File('${folder.path}/release');
      final repo = _FailFirstRunningAudit();
      final executable = File(Platform.resolvedExecutable);
      final stat = await executable.stat();
      final service = InformationService(
        repository: repo,
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
        credentialProcessStarter: (exe, argv, cwd, env) => Process.start(
          exe,
          [
            File('test/support/credential_waiting_child.dart').absolute.path,
            release.path,
          ],
          workingDirectory: cwd,
          environment: env,
          includeParentEnvironment: false,
        ),
      );
      addTearDown(() async {
        await release.writeAsString('release');
        await client.drainCredentialExecutions();
        client.close();
        await server.close();
        await service.close();
        await folder.delete(recursive: true);
      });
      var credential = await service.owner.createStringCredential(
        name: 'Synthetic',
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
      await client.execute({'command': 'session', 'chatLabel': 'Audit outage'});
      final request = await client.execute({
        'command': 'request-use',
        'purpose': 'Monitor despite audit outage',
        'credentials': [
          {'alias': 'token', 'credentialId': credential.id, 'version': 1},
        ],
        'launch': {
          'receiver': 'gh_token',
          'executable': executable.path,
          'argv': ['api', 'user'],
          'cwd': Directory.current.path,
          'env': {
            'GH_TOKEN': {'secret': 'token'},
          },
        },
      });
      expect(request['status'], 'pending');
      await service.owner.decideCredentialUse(
        request['requestId'] as String,
        approveCredential: true,
      );
      final accepted = await client.execute({
        'command': 'run-use',
        'requestId': request['requestId'],
      });
      expect(accepted['status'], 'accepted');
      await repo.failureObserved.future.timeout(const Duration(seconds: 10));
      expect(
        await client
            .drainCredentialExecutions()
            .then((_) => true)
            .timeout(const Duration(milliseconds: 150), onTimeout: () => false),
        isFalse,
        reason:
            'The child is still waiting; audit failure must not mark it complete.',
      );
      final output = await client.execute({
        'command': 'execution-output',
        'executionId': accepted['executionId'],
      });
      expect(output['outputComplete'], isFalse);
      await release.writeAsString('release');
      await client.drainCredentialExecutions();
      final status = await client.execute({
        'command': 'execution-status',
        'executionId': accepted['executionId'],
      });
      expect(status['executionState'], 'exited');
      expect(status['exitCode'], 0);
      expect(repo.failures, 1);
    },
  );
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

class _FailFirstRunningAudit extends MemoryInformationRepository {
  final failureObserved = Completer<void>();
  int failures = 0;
  @override
  Future<void> commitCredentialRuntime(
    List<CredentialUseRequest> requests,
    List<CredentialExecution> executions, {
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    void Function()? validate,
  }) async {
    if (failures == 0 && executions.any((e) => e.state == 'running')) {
      failures++;
      failureObserved.complete();
      throw StateError('synthetic audit outage');
    }
    await super.commitCredentialRuntime(
      requests,
      executions,
      fieldGrant: fieldGrant,
      fieldRequest: fieldRequest,
      validate: validate,
    );
  }
}
