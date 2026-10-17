import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

void main() {
  test(
    'changing executable bytes while preserving size and modification time consumes the attempt without spawning',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'runtime-image-change-',
      );
      final image = await File(
        Platform.resolvedExecutable,
      ).copy('${folder.path}/controlled.exe');
      var spawned = false;
      final h = await RuntimeHarness.create(
        executablePath: image.path,
        starter: (exe, argv, cwd, env) async {
          spawned = true;
          throw StateError('Changed executable must never be started');
        },
      );
      addTearDown(() async {
        await h.close();
        await folder.delete(recursive: true);
      });
      final request = await h.approve();
      final stat = await image.stat();
      final bytes = await image.readAsBytes();
      bytes[0] ^= 1;
      await image.writeAsBytes(bytes, flush: true);
      await image.setLastModified(stat.modified);
      expect((await image.stat()).size, stat.size);
      expect((await image.stat()).modified, stat.modified);
      final accepted = await h.client.execute({
        'command': 'run-use',
        'requestId': request,
      });
      expect(accepted['status'], 'accepted');
      await h.client.drainCredentialExecutions();
      final status = await h.client.execute({
        'command': 'execution-status',
        'executionId': accepted['executionId'],
      });
      expect(status['executionState'], 'prepare_failed');
      expect(status['errorCode'], 'executable_changed');
      expect(status['processStarted'], isFalse);
      expect(spawned, isFalse);
      expect(
        (await h.client.execute({
          'command': 'run-use',
          'requestId': request,
        }))['errorCode'],
        'attempt_consumed',
      );
    },
  );
  test(
    'a lost private consume response is never reported as an unconsumed retryable attempt',
    () async {
      final h = await RuntimeHarness.create();
      final request = await h.approve();
      final cut = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final handling = cut.listen((incoming) async {
        final body =
            jsonDecode(await utf8.decoder.bind(incoming).join())
                as Map<String, dynamic>;
        try {
          await h.service.agent.consumeCredentialUse(
            body['sessionSecret'] as String,
            body['requestId'] as String,
          );
          (await incoming.response.detachSocket()).destroy();
        } on CredentialUseFailure catch (error) {
          incoming.response.write(jsonEncode(error.toJson()));
          await incoming.response.close();
        }
      });
      final client = AgentClient(
        cut.port,
        sessionSecret: h.client.sessionSecret,
      );
      addTearDown(() async {
        client.close();
        await cut.close(force: true);
        await handling.cancel();
        await h.close();
      });
      final result = await client.execute({
        'command': 'run-use',
        'requestId': request,
      });
      expect(result['attemptConsumed'], isTrue);
      expect(result['retryable'], isFalse);
      expect(
        h.service.owner.credentialUseRequests.single.attemptConsumed,
        isTrue,
      );
      expect(h.service.owner.credentialExecutions, hasLength(1));
      expect(
        (await h.client.execute({
          'command': 'status',
          'requestId': request,
        }))['executionId'],
        isNotNull,
      );
    },
  );
  test(
    'sixteen active executions reject the next attempt before consuming its permission',
    () async {
      final gate = Completer<void>();
      Future<void> previous = gate.future;
      final h = await RuntimeHarness.create(
        starter: (exe, argv, cwd, env) async {
          final turn = previous;
          final next = Completer<void>();
          previous = next.future;
          await turn;
          final process = await Process.start(
            exe,
            [File('test/support/credential_child.dart').absolute.path, ...argv],
            workingDirectory: cwd,
            environment: env,
            includeParentEnvironment: false,
          );
          unawaited(process.exitCode.whenComplete(next.complete));
          return process;
        },
      );
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await h.close();
      });
      for (var i = 0; i < 16; i++) {
        final request = await h.approve();
        expect(
          (await h.client.execute({
            'command': 'run-use',
            'requestId': request,
          }))['status'],
          'accepted',
        );
      }
      final pending = await h.approve();
      final rejected = await h.client.execute({
        'command': 'run-use',
        'requestId': pending,
      });
      expect(rejected['errorCode'], 'execution_capacity');
      expect(rejected['attemptConsumed'], isFalse);
      expect(
        h.service.owner.credentialUseRequests
            .singleWhere((r) => r.id == pending)
            .attemptConsumed,
        isFalse,
      );
      gate.complete();
      await h.client.drainCredentialExecutions();
      expect(
        (await h.client.execute({
          'command': 'run-use',
          'requestId': pending,
        }))['status'],
        'accepted',
      );
      await h.client.drainCredentialExecutions();
      expect(h.service.owner.credentialExecutions.length, 17);
    },
  );
  test(
    'real output is limited to the first 4 MiB and is unavailable from another CLI process context',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'runtime-output-test-',
      );
      await File('${folder.path}/api').writeAsString('''
import 'dart:io';
Future<void> main() async {
  stdout.add(List<int>.filled(4194304 + 8192, 120));
  await stdout.flush();
  stderr.writeln('synthetic-tail');
}
''');
      final h = await RuntimeHarness.create();
      addTearDown(() async {
        await h.close();
        await folder.delete(recursive: true);
      });
      final request = await h.approve(cwd: folder.path);
      final accepted = await h.client.execute({
        'command': 'run-use',
        'requestId': request,
      });
      await h.client.drainCredentialExecutions();
      var cursor = 0, bytes = 0;
      while (true) {
        final output = await h.client.execute({
          'command': 'execution-output',
          'executionId': accepted['executionId'],
          'cursor': cursor,
          'limit': 16,
        });
        expect(output['status'], 'ok');
        expect(output['outputComplete'], isTrue);
        expect(output['outputTruncated'], isTrue);
        final chunks = output['chunks'] as List;
        expect(chunks.length, lessThanOrEqualTo(16));
        for (final dynamic chunk in chunks) {
          expect(chunk['seq'], cursor++);
          expect(chunk['stream'], anyOf('stdout', 'stderr'));
          final raw = base64Decode(chunk['dataBase64'] as String);
          expect(raw.length, inInclusiveRange(1, 4096));
          bytes += raw.length;
        }
        expect(output['nextCursor'], cursor);
        if (output['hasMore'] != true) break;
      }
      expect(bytes, 4194304);
      final other = AgentClient(
        h.server.port,
        sessionSecret: h.client.sessionSecret,
      );
      addTearDown(other.close);
      expect(
        (await other.execute({
          'command': 'execution-status',
          'executionId': accepted['executionId'],
        }))['executionState'],
        'exited',
      );
      expect(
        (await other.execute({
          'command': 'execution-output',
          'executionId': accepted['executionId'],
        }))['errorCode'],
        'output_unavailable',
      );
      expect(
        (await h.client.execute({
          'command': 'execution-output',
          'executionId': accepted['executionId'],
          'cursor': cursor + 1,
        }))['errorCode'],
        'cursor_out_of_range',
      );
      expect(
        jsonEncode(h.service.owner.credentialExecutions.single.toStorageJson()),
        isNot(contains('synthetic-tail')),
      );
    },
    skip: !Platform.isWindows,
  );
  test(
    'worker crash preserves monitoring until the remaining tree ends and records unknown',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'runtime-worker-crash-',
      );
      final release = File('${folder.path}/release');
      await File('${folder.path}/api').writeAsString(
        await File('test/support/credential_crash_child.dart').readAsString(),
      );
      final h = await RuntimeHarness.create();
      addTearDown(() async {
        await release.writeAsString('release');
        await h.close();
        await folder.delete(recursive: true);
      });
      final request = await h.approve(cwd: folder.path);
      final accepted = await h.client.execute({
        'command': 'run-use',
        'requestId': request,
      });
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      Future<void> waitFor(bool Function() ready) async {
        while (!ready()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Controlled worker did not reach the expected state');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      await waitFor(
        () =>
            File('${folder.path}/target-ready').existsSync() &&
            h.service.owner.credentialExecutions.single.state == 'running',
      );
      await File('${folder.path}/kill-worker').writeAsString('kill');
      await waitFor(() => File('${folder.path}/worker-killed').existsSync());
      expect(
        await h.client
            .drainCredentialExecutions()
            .then((_) => true)
            .timeout(const Duration(milliseconds: 150), onTimeout: () => false),
        isFalse,
      );
      await release.writeAsString('release');
      await h.client.drainCredentialExecutions();
      final status = await h.client.execute({
        'command': 'execution-status',
        'executionId': accepted['executionId'],
      });
      expect(status['executionState'], 'unknown');
      expect(status['processStarted'], isTrue);
      expect(status['exitCode'], isNull);
      expect(
        (await h.client.execute({
          'command': 'run-use',
          'requestId': request,
        }))['errorCode'],
        'attempt_consumed',
      );
    },
    skip: !Platform.isWindows,
  );
  test(
    'production starter monitors a detached descendant after the approved parent exits',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'runtime-tree-test-',
      );
      final release = File('${folder.path}/release');
      final ready = File('${folder.path}/descendant-ready');
      await File('${folder.path}/api').writeAsString('''
import 'dart:io';
Future<void> main() async {
  await Process.start(Platform.resolvedExecutable, ['descendant.dart'], mode: ProcessStartMode.detached);
  exit(7);
}
''');
      await File('${folder.path}/descendant.dart').writeAsString('''
import 'dart:io';
Future<void> main() async {
  await File('descendant-ready').writeAsString('ready');
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (!await File('release').exists()) {
    if (DateTime.now().isAfter(end)) exit(70);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
''');
      final h = await RuntimeHarness.create();
      addTearDown(() async {
        await release.writeAsString('release');
        await h.close();
        await folder.delete(recursive: true);
      });
      final request = await h.approve(cwd: folder.path);
      final accepted = await h.client.execute({
        'command': 'run-use',
        'requestId': request,
      });
      expect(accepted['status'], 'accepted');
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await ready.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Controlled descendant did not become ready');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        await h.client
            .drainCredentialExecutions()
            .then((_) => true)
            .timeout(const Duration(milliseconds: 150), onTimeout: () => false),
        isFalse,
        reason: 'Parent exit is not the end of its process tree.',
      );
      await release.writeAsString('release');
      await h.client.drainCredentialExecutions();
      final result = await h.client.execute({
        'command': 'execution-status',
        'executionId': accepted['executionId'],
      });
      expect(result['executionState'], 'exited');
      expect(result['exitCode'], 7);
    },
    skip: !Platform.isWindows,
  );
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
      for (final invalid in [
        <String, Object?>{'cursor': null},
        <String, Object?>{'limit': null},
      ]) {
        final rejected = await client.execute({
          'command': 'execution-output',
          'executionId': executionId,
          ...invalid,
        });
        expect(rejected['errorCode'], 'invalid_type');
      }
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
