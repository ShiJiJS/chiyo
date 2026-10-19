import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/credential_execution_host.dart';
import 'package:info_cli/codex_association.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';
import 'codex_process_test.dart' show invoke;

void main() {
  test(
    'resident output expiry preserves active work and durable facts but does not retain completed output after thirty minutes',
    () async {
      var now = DateTime.utc(2026, 10, 18);
      final h = await RuntimeHarness.create();
      final root = await Directory.systemTemp.createTemp('hosted-expiry-');
      final gate = File('${root.path}/release');
      late CredentialExecutionHost host;
      final server = await AgentServer.start(
        h.service.agent,
        port: 0,
        credentialExecutionHandler: (session, input) =>
            host.execute(session, input),
      );
      host = CredentialExecutionHost(
        port: server.port,
        clock: () => now,
        processStarter: (exe, argv, cwd, env) => Process.start(
          exe,
          [
            File('test/support/hosted_waiting_child.dart').absolute.path,
            gate.path,
            ...argv,
          ],
          workingDirectory: cwd,
          environment: env,
          includeParentEnvironment: false,
          runInShell: false,
        ),
      );
      final client = AgentClient(
        server.port,
        sessionSecret: h.client.sessionSecret,
        hostedCredentialExecutions: true,
      );
      addTearDown(() async {
        await gate.writeAsString('release');
        await host.drain();
        host.close();
        client.close();
        await server.close();
        await h.close();
        final actual = await root.resolveSymbolicLinks(),
            temp = await Directory.systemTemp.resolveSymbolicLinks();
        if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
            !actual.toLowerCase().startsWith(
              '${temp.toLowerCase()}${Platform.pathSeparator}',
            )) {
          throw StateError('Unexpected expiry fixture');
        }
        await root.delete(recursive: true);
      });
      final request = await h.approve();
      final run = await client.execute({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': request,
      });
      expect(run['status'], 'accepted');
      final id = run['executionId'];
      now = now.add(const Duration(minutes: 40));
      expect(
        (await client.execute({
          'command': 'execution-status',
          'executionId': id,
        }))['outputAvailable'],
        isTrue,
      );
      await gate.writeAsString('release');
      await host.drain();
      now = now.add(const Duration(minutes: 31));
      final status = await client.execute({
        'command': 'execution-status',
        'executionId': id,
      });
      expect(status['executionState'], 'exited');
      expect(status['exitCode'], 0);
      expect(status['outputAvailable'], isFalse);
      expect(
        (await client.execute({
          'command': 'execution-output',
          'executionId': id,
        }))['errorCode'],
        'output_unavailable',
      );
      expect(
        (await client.execute({
          'protocolVersion': 1,
          'command': 'run-use',
          'requestId': request,
        }))['errorCode'],
        'attempt_consumed',
      );
      expect(h.service.owner.credentialExecutions, hasLength(1));
    },
    skip: !Platform.isWindows,
  );
  test(
    'the resident limit is global across sessions, preserves running tasks, and evicts only finished output',
    () async {
      final h = await RuntimeHarness.create();
      final root = await Directory.systemTemp.createTemp('hosted-capacity-');
      final release = File('${root.path}/release');
      late CredentialExecutionHost host;
      final server = await AgentServer.start(
        h.service.agent,
        port: 0,
        credentialExecutionHandler: (session, input) =>
            host.execute(session, input),
      );
      host = CredentialExecutionHost(
        port: server.port,
        processStarter: (exe, argv, cwd, env) => Process.start(
          exe,
          [
            File('test/support/hosted_waiting_child.dart').absolute.path,
            release.path,
            ...argv,
          ],
          workingDirectory: cwd,
          environment: env,
          includeParentEnvironment: false,
          runInShell: false,
        ),
      );
      final a = AgentClient(
            server.port,
            sessionSecret: h.client.sessionSecret,
            hostedCredentialExecutions: true,
          ),
          b = AgentClient(server.port, hostedCredentialExecutions: true);
      addTearDown(() async {
        await release.writeAsString('release');
        await host.drain();
        host.close();
        a.close();
        b.close();
        await server.close();
        await h.close();
        final actual = await root.resolveSymbolicLinks(),
            parent = await Directory.systemTemp.resolveSymbolicLinks();
        if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
            !actual.toLowerCase().startsWith(
              '${parent.toLowerCase()}${Platform.pathSeparator}',
            )) {
          throw StateError('Unexpected capacity fixture');
        }
        await root.delete(recursive: true);
      });
      await b.execute({
        'command': 'session',
        'chatLabel': 'Second capacity session',
      });
      final requests = <String>[], clients = <AgentClient>[];
      for (var i = 0; i < 17; i++) {
        final client = i.isEven ? a : b;
        final result = await client.execute({
          'protocolVersion': 1,
          'command': 'request-use',
          'purpose': 'Capacity test $i',
          'credentials': [
            {'alias': 'token', 'credentialId': h.credential.id, 'version': 1},
          ],
          'launch': {
            'receiver': 'gh_token',
            'executable': h.executablePath,
            'argv': ['api', 'user'],
            'cwd': Directory.current.path,
            'env': {
              'GH_TOKEN': {'secret': 'token'},
            },
          },
        });
        expect(result['status'], 'pending');
        final id = result['requestId'] as String;
        await h.service.owner.decideCredentialUse(id, approveCredential: true);
        requests.add(id);
        clients.add(client);
      }
      final results = await Future.wait([
        for (var i = 0; i < 17; i++)
          clients[i].execute({
            'protocolVersion': 1,
            'command': 'run-use',
            'requestId': requests[i],
          }),
      ]);
      expect(results.where((r) => r['status'] == 'accepted'), hasLength(16));
      final denied = results.indexWhere(
        (r) => r['errorCode'] == 'execution_capacity',
      );
      expect(denied, greaterThanOrEqualTo(0));
      expect(results[denied]['attemptConsumed'], isFalse);
      expect(
        h.service.owner.credentialUseRequests.where((r) => !r.attemptConsumed),
        hasLength(1),
      );
      await release.writeAsString('release');
      await host.drain();
      final resumed = await clients[denied].execute({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': requests[denied],
      });
      expect(resumed['status'], 'accepted');
      results[denied] = resumed;
      await host.drain();
      var retained = 0;
      for (var i = 0; i < 17; i++) {
        final status = await clients[i].execute({
          'command': 'execution-status',
          'executionId': results[i]['executionId'],
        });
        expect(status['executionState'], 'exited');
        expect(status['exitCode'], 0);
        if (status['outputAvailable'] == true) retained++;
      }
      expect(retained, 16);
      expect(h.service.owner.credentialExecutions, hasLength(17));
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 40)),
  );
  test(
    'an unavailable resident host never falls back to local execution or consumes the approved attempt',
    () async {
      final h = await RuntimeHarness.create();
      addTearDown(h.close);
      final request = await h.approve();
      final client = AgentClient(
        h.server.port,
        sessionSecret: h.client.sessionSecret,
        hostedCredentialExecutions: true,
      );
      addTearDown(client.close);
      final result = await client.execute({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': request,
      });
      expect(result['errorCode'], 'service_unavailable');
      expect(result['attemptConsumed'], isFalse);
      expect(
        h.service.owner.credentialUseRequests.single.attemptConsumed,
        isFalse,
      );
      expect(h.service.owner.credentialExecutions, isEmpty);
    },
  );
  test(
    'closing a host during worker availability inspection rejects the launch before consuming its attempt',
    () async {
      final h = await RuntimeHarness.create();
      addTearDown(h.close);
      final request = await h.approve();
      final host = CredentialExecutionHost(
        port: h.server.port,
        workerExecutable: File('pubspec.yaml').absolute.path,
      );
      addTearDown(() async {
        await host.drain();
        host.close();
      });
      final pending = host.execute(h.client.sessionSecret!, {
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': request,
      });
      host.close();
      final result = await pending;
      expect(result['errorCode'], 'service_unavailable');
      expect(result['attemptConsumed'], isFalse);
      expect(
        h.service.owner.credentialUseRequests.single.attemptConsumed,
        isFalse,
      );
      expect(h.service.owner.credentialExecutions, isEmpty);
    },
    skip: !Platform.isWindows,
  );
  test(
    'separate actual Codex adapter processes start and query one hosted task without losing output or repeating approval',
    () async {
      final h = await RuntimeHarness.create();
      addTearDown(h.close);
      final request = await h.approve(argv: ['api', 'user', '--method', 'GET']);
      await h.server.close();
      late CredentialExecutionHost host;
      final server = await AgentServer.start(
        h.service.agent,
        port: 0,
        credentialExecutionHandler: (session, input) =>
            host.execute(session, input),
      );
      host = CredentialExecutionHost(
        port: server.port,
        processStarter: (exe, argv, cwd, env) => Process.start(
          exe,
          [
            File('test/support/hosted_credential_child.dart').absolute.path,
            ...argv,
          ],
          workingDirectory: cwd,
          environment: env,
          includeParentEnvironment: false,
          runInShell: false,
        ),
      );
      addTearDown(() async {
        await host.drain();
        host.close();
        await server.close();
      });
      final root = await Directory.systemTemp.createTemp(
        'hosted-codex-association-',
      );
      addTearDown(() async {
        final actual = await root.resolveSymbolicLinks(),
            parent = await Directory.systemTemp.resolveSymbolicLinks();
        if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
            !actual.toLowerCase().startsWith(
              '${parent.toLowerCase()}${Platform.pathSeparator}',
            )) {
          throw StateError('Refusing unexpected test association cleanup');
        }
        await root.delete(recursive: true);
      });
      final reference = await CodexAssociation(
        'hosted-test-chat',
        server.port,
        h.client.sessionSecret!,
      ).save(root);
      Future<Map<String, dynamic>> call(Map<String, dynamic> input) => invoke(
        'bin/codex_info.dart',
        {'association': reference, ...input},
        chat: 'hosted-test-chat',
      );
      final accepted = await call({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': request,
      });
      expect(accepted['status'], 'accepted');
      await host.drain();
      final status = await call({
        'command': 'execution-status',
        'executionId': accepted['executionId'],
      });
      expect(status['executionState'], 'exited');
      expect(status['exitCode'], 0);
      expect(status['outputAvailable'], isTrue);
      final output = await call({
        'command': 'execution-output',
        'executionId': accepted['executionId'],
      });
      expect(output['chunks'], isNotEmpty);
      expect(
        (await call({
          'protocolVersion': 1,
          'command': 'run-use',
          'requestId': request,
        }))['errorCode'],
        'attempt_consumed',
      );
    },
    skip: !Platform.isWindows,
  );
  test(
    'a hosted task survives its calling client closing and another call retrieves the same authorized output',
    () async {
      final h = await RuntimeHarness.create();
      addTearDown(h.close);
      final request = await h.approve(argv: ['api', 'user', '--method', 'GET']);
      await h.server.close();
      late CredentialExecutionHost host;
      final server = await AgentServer.start(
        h.service.agent,
        port: 0,
        credentialExecutionHandler: (session, input) =>
            host.execute(session, input),
      );
      host = CredentialExecutionHost(
        port: server.port,
        processStarter: (exe, argv, cwd, env) => Process.start(
          exe,
          [
            File('test/support/hosted_credential_child.dart').absolute.path,
            ...argv,
          ],
          workingDirectory: cwd,
          environment: env,
          includeParentEnvironment: false,
          runInShell: false,
        ),
      );
      addTearDown(() async {
        await host.drain();
        host.close();
        await server.close();
      });
      final first = AgentClient(
        server.port,
        sessionSecret: h.client.sessionSecret,
        hostedCredentialExecutions: true,
      );
      final accepted = await first.execute({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': request,
      });
      expect(accepted['status'], 'accepted');
      first.close();
      final second = AgentClient(
        server.port,
        sessionSecret: h.client.sessionSecret,
        hostedCredentialExecutions: true,
      );
      addTearDown(second.close);
      await host.drain();
      final status = await second.execute({
        'command': 'execution-status',
        'executionId': accepted['executionId'],
      });
      expect(status['executionState'], 'exited');
      expect(status['exitCode'], 0);
      expect(status['outputAvailable'], isTrue);
      final output = await second.execute({
        'command': 'execution-output',
        'executionId': accepted['executionId'],
      });
      final bytes = (output['chunks'] as List)
          .where((c) => c['stream'] == 'stdout')
          .expand<int>((c) => base64Decode(c['dataBase64'] as String))
          .toList();
      expect(jsonDecode(utf8.decode(bytes)), {
        'tokenMatches': true,
        'literalArguments': true,
      });
      expect(
        (await second.execute({
          'protocolVersion': 1,
          'command': 'run-use',
          'requestId': request,
        }))['errorCode'],
        'attempt_consumed',
      );
      final stranger = AgentClient(
        server.port,
        hostedCredentialExecutions: true,
      );
      addTearDown(stranger.close);
      await stranger.execute({'command': 'session', 'chatLabel': 'Unrelated'});
      expect(
        (await stranger.execute({
          'command': 'execution-output',
          'executionId': accepted['executionId'],
        }))['errorCode'],
        'session_mismatch',
      );
    },
    skip: !Platform.isWindows,
  );
}
