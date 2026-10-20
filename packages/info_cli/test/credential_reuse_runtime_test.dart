import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/credential_execution_host.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

Map<String, dynamic> run(
  RuntimeHarness h,
  String requestId,
  String operationId, {
  List<String> argv = const ['api', 'user', '--method', 'GET'],
}) => {
  'protocolVersion': 2,
  'command': 'run-use',
  'requestId': requestId,
  'operationId': operationId,
  'launch': {
    'receiver': 'gh_token',
    'executable': h.executablePath,
    'argv': argv,
    'cwd': Directory.current.path,
    'env': {
      'GH_TOKEN': {'secret': 'token'},
    },
  },
};

void main() {
  test(
    'v2 output masks credential bytes across chunks while preserving binary data and stream identity',
    () async {
      final root = await Directory.systemTemp.createTemp('reuse-output-');
      final child = File('${root.path}/echo.dart');
      await child.writeAsString('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  final token = utf8.encode(Platform.environment['GH_TOKEN']!);
  stdout.add([0,255,...utf8.encode('prefix:')]);
  for (final byte in token) {
    stdout.add([byte]); await stdout.flush();
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  stdout.add(utf8.encode(':suffix')); await stdout.flush();
  stderr.add(token.sublist(0, 3)); await stderr.flush();
  await Future<void>.delayed(const Duration(milliseconds: 20));
  stderr.add(token.sublist(3)); await stderr.flush();
}
''');
      final h = await RuntimeHarness.create(
        enableReusableCredentialUse: true,
        starter: (exe, argv, cwd, env) => Process.start(
          exe,
          [child.path],
          workingDirectory: cwd,
          environment: env,
          includeParentEnvironment: false,
          runInShell: false,
        ),
      );
      addTearDown(() async {
        await h.close();
        await removeFixture(root);
      });
      final request = await h.approve(protocolVersion: 2);
      final accepted = await h.client.execute(run(h, request, 'echo'));
      await h.client.drainCredentialExecutions();
      final output = await h.client.execute({
        'protocolVersion': 2,
        'command': 'execution-output',
        'executionId': accepted['executionId'],
      });
      List<int> stream(String name) => (output['chunks'] as List)
          .where((c) => c['stream'] == name)
          .expand<int>((c) => base64Decode(c['dataBase64'] as String))
          .toList();
      expect(stream('stdout'), [
        0,
        255,
        ...utf8.encode('prefix:[REDACTED]:suffix'),
      ]);
      expect(stream('stderr'), utf8.encode('[REDACTED]'));
    },
  );

  test(
    'native platform workers run three operations with separate groups and one unchanged grant',
    () async {
      final root = await Directory.systemTemp.createTemp('reuse-native 中文 ');
      final h = await RuntimeHarness.create(enableReusableCredentialUse: true);
      addTearDown(() async {
        await h.close();
        await removeFixture(root);
      });
      for (final name in ['api', 'repo']) {
        await File('${root.path}/$name').writeAsString('''
import 'dart:io';
void main() {
  final marker = File('$name-count.txt');
  final count = marker.existsSync() ? int.parse(marker.readAsStringSync()) : 0;
  marker.writeAsStringSync((count + 1).toString());
  stdout.writeln(Platform.environment['GH_TOKEN'] == 'synthetic-token' ? 'injected' : 'missing');
  stdout.writeln(Platform.environment['GH_TOKEN']);
  ${name == 'repo' ? 'exit(7);' : ''}
}
''');
      }
      final request = await h.approve(protocolVersion: 2, cwd: root.path);
      final deadline =
          h.service.owner.credentialUseRequests.single.credentialExpiresAt;
      Map<String, dynamic> nativeRun(String id, List<String> argv) {
        final input = run(h, request, id, argv: argv);
        (input['launch'] as Map)['cwd'] = root.path;
        return input;
      }

      final results = <Map<String, dynamic>>[];
      for (final plan in [
        nativeRun('native-a', ['api', 'user']),
        nativeRun('native-b', ['repo', 'view', 'northstar/agent-skills']),
        nativeRun('native-c', ['api', 'user', '--method', 'GET']),
      ]) {
        final result = await h.client.execute(plan);
        expect(result['status'], 'accepted');
        results.add(result);
        await h.client.drainCredentialExecutions();
      }
      final records = h.service.owner.credentialExecutions;
      expect(records.map((e) => e.exitCode), [0, 7, 0]);
      expect(
        records.every(
          (e) =>
              e.workerPid != null && e.supervisorPid == pid && e.processStarted,
        ),
        isTrue,
      );
      expect(records.map((e) => e.jobName).toSet(), hasLength(3));
      expect(await File('${root.path}/api-count.txt').readAsString(), '2');
      expect(await File('${root.path}/repo-count.txt').readAsString(), '1');
      expect(
        h.service.owner.credentialUseRequests.single.credentialExpiresAt,
        deadline,
      );
      expect(
        h.service.owner.credentialGrantState(
          h.service.owner.credentialUseRequests.single,
        ),
        'available',
      );
      final duplicate = await h.client.execute(
        nativeRun('native-a', ['api', 'user']),
      );
      expect(duplicate['duplicate'], isTrue);
      expect(await File('${root.path}/api-count.txt').readAsString(), '2');
      for (final result in results) {
        final output = await h.client.execute({
          'protocolVersion': 2,
          'command': 'execution-output',
          'executionId': result['executionId'],
        });
        final text = (output['chunks'] as List)
            .where((c) => c['stream'] == 'stdout')
            .map((c) => utf8.decode(base64Decode(c['dataBase64'] as String)))
            .join();
        expect(text.trim(), 'injected\n[REDACTED]');
      }
    },
    skip: !Platform.isWindows && !Platform.isMacOS,
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test(
    'native file workers inject two independent paths and clear their registered material',
    () async {
      const contents =
          '[default]\naws_access_key_id=TEST_ACCESS_ONLY\naws_secret_access_key=SYNTHETIC_NOT_A_REAL_SECRET\n';
      final root = await Directory.systemTemp.createTemp('reuse-native-files-');
      final h = await RuntimeHarness.create(
        enableReusableCredentialUse: true,
        fileBytes: utf8.encode(contents),
      );
      addTearDown(() async {
        await h.close();
        await removeFixture(root);
      });
      await File('${root.path}/sts').writeAsString('''
import 'dart:io';
import 'dart:convert';
void main() {
  final path = Platform.environment['AWS_SHARED_CREDENTIALS_FILE']!;
  final matches = File(path).readAsStringSync() == ${jsonEncode(contents)};
  File('delivered.txt').writeAsStringSync(jsonEncode({'path':path, 'matches':matches}) + '\\n', mode: FileMode.append);
  stdout.writeln(matches ? 'injected' : 'mismatch');
  stdout.write(File(path).readAsStringSync());
  stdout.writeln('SYNTHETIC_NOT_A_REAL_SECRET');
}
''');
      final request = await h.approve(
        protocolVersion: 2,
        cwd: root.path,
        argv: ['sts', 'get-caller-identity', '--region', 'us-east-1'],
      );
      for (final region in ['us-east-1', 'us-west-2']) {
        final result = await h.client.execute({
          'protocolVersion': 2,
          'command': 'run-use',
          'requestId': request,
          'operationId': region,
          'launch': {
            'receiver': 'aws_shared_credentials',
            'executable': h.executablePath,
            'argv': ['sts', 'get-caller-identity', '--region', region],
            'cwd': root.path,
            'env': {
              'AWS_SHARED_CREDENTIALS_FILE': {'file': 'token'},
            },
          },
        });
        expect(result['status'], 'accepted');
        await h.client.drainCredentialExecutions();
        // Target exit/pipe drain may precede the end of the worker's Windows
        // Job. Query and clean the original operation, never rerun the command.
        final beforeCleanup = await h.client.execute({
          'command': 'execution-status',
          'executionId': result['executionId'],
        });
        print(
          jsonEncode({
            'phase': 'native_file_cleanup_before_wait',
            'operationId': region,
            'executionState': beforeCleanup['executionState'],
            'cleanupState': beforeCleanup['cleanupState'],
          }),
        );
        final cleaned = await h.waitForMaterialCleanup(
          result['executionId'] as String,
        );
        expect(cleaned['cleanupState'], 'complete');
        final output = await h.client.execute({
          'protocolVersion': 2,
          'command': 'execution-output',
          'executionId': result['executionId'],
        });
        final text = (output['chunks'] as List)
            .map((c) => utf8.decode(base64Decode(c['dataBase64'] as String)))
            .join();
        expect(text, contains('[REDACTED]'));
        expect(text, isNot(contains('SYNTHETIC_NOT_A_REAL_SECRET')));
        expect(text, isNot(contains('TEST_ACCESS_ONLY')));
      }
      final rows = (await File(
        '${root.path}/delivered.txt',
      ).readAsLines()).map((s) => jsonDecode(s) as Map).toList();
      expect(rows, hasLength(2));
      expect(rows.map((r) => r['path']).toSet(), hasLength(2));
      for (final row in rows) {
        expect(row['matches'], isTrue);
        expect(await File(row['path'] as String).exists(), isFalse);
      }
      expect(
        h.service.owner.credentialExecutions.every(
          (e) =>
              e.state == 'exited' &&
              e.exitCode == 0 &&
              e.cleanupState == 'complete' &&
              e.workerPid != null,
        ),
        isTrue,
      );
    },
    skip: !Platform.isWindows && !Platform.isMacOS,
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test(
    'full resident capacity still returns duplicate facts without another start',
    () async {
      final h = await RuntimeHarness.create(enableReusableCredentialUse: true);
      addTearDown(h.close);
      final root = await Directory.systemTemp.createTemp('reuse-capacity-');
      final gate = File('${root.path}/release');
      late CredentialExecutionHost host;
      final server = await AgentServer.start(
        h.service.agent,
        port: 0,
        enableReusableCredentialUse: true,
        credentialExecutionHandler: (session, input) =>
            host.execute(session, input),
      );
      host = CredentialExecutionHost(
        port: server.port,
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
        await gate.delete();
        await root.delete();
      });
      final request = await h.approve(protocolVersion: 2);
      final results = await Future.wait(
        List.generate(16, (i) => client.execute(run(h, request, 'slot-$i'))),
      );
      expect(results.every((r) => r['status'] == 'accepted'), isTrue);
      final full = await client.execute(run(h, request, 'slot-17'));
      expect(full['errorCode'], 'execution_capacity');
      expect(full['operationClaimed'], isFalse);
      final duplicate = await client.execute(run(h, request, 'slot-0'));
      expect(duplicate['executionId'], results.first['executionId']);
      expect(duplicate['duplicate'], isTrue);
      expect(h.service.owner.credentialExecutions, hasLength(16));
      await gate.writeAsString('release');
      await host.drain();
      final resumed = await client.execute(run(h, request, 'slot-17'));
      expect(resumed['status'], 'accepted');
      await host.drain();
      expect(h.service.owner.credentialExecutions, hasLength(17));
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'each file operation writes exact bytes into its own path and cleans only its lease',
    () async {
      final bytes = utf8.encode(
        '[default]\naws_access_key_id = TEST_ACCESS_ONLY\naws_secret_access_key = SYNTHETIC_NOT_A_REAL_SECRET\n',
      );
      final paths = <String>[];
      final h = await RuntimeHarness.create(
        enableReusableCredentialUse: true,
        fileBytes: bytes,
        starter: (exe, argv, cwd, env) async {
          final path = env['AWS_SHARED_CREDENTIALS_FILE']!;
          expect(await File(path).readAsBytes(), bytes);
          paths.add(path);
          return Process.start(
            exe,
            [
              File('test/support/credential_file_child.dart').absolute.path,
              ...argv,
            ],
            workingDirectory: cwd,
            environment: env,
            includeParentEnvironment: false,
            runInShell: false,
          );
        },
      );
      addTearDown(h.close);
      final request = await h.approve(
        protocolVersion: 2,
        argv: ['sts', 'get-caller-identity', '--region', 'us-east-1'],
      );
      Map<String, dynamic> fileRun(String id) => {
        'protocolVersion': 2,
        'command': 'run-use',
        'requestId': request,
        'operationId': id,
        'launch': {
          'receiver': 'aws_shared_credentials',
          'executable': h.executablePath,
          'argv': ['sts', 'get-caller-identity', '--region', 'us-east-1'],
          'cwd': Directory.current.path,
          'env': {
            'AWS_SHARED_CREDENTIALS_FILE': {'file': 'token'},
          },
        },
      };
      final results = await Future.wait(
        ['file-a', 'file-b'].map((id) => h.client.execute(fileRun(id))),
      );
      expect(results.every((r) => r['status'] == 'accepted'), isTrue);
      await h.client.drainCredentialExecutions();
      expect(paths.toSet(), hasLength(2));
      for (final path in paths) {
        expect(await File(path).exists(), isFalse);
      }
      for (final e in h.service.owner.credentialExecutions) {
        expect(e.cleanupState, 'complete');
        expect(e.state, 'exited');
        expect(e.operationPlan, isNotNull);
      }
      final duplicate = await h.client.execute(fileRun('file-a'));
      expect(duplicate['duplicate'], isTrue);
      expect(paths, hasLength(2));
    },
    skip: !Platform.isWindows,
  );

  test(
    'default and explicit v2 refuse an old service without silently creating a v1 request',
    () async {
      final h = await RuntimeHarness.create();
      addTearDown(h.close);
      final capabilities = await h.client.execute({'command': 'capabilities'});
      expect(capabilities['protocolVersions'], [1]);
      expect(capabilities['capabilities'], isEmpty);
      for (final version in [null, 2]) {
        final result = await h.client.execute({
          'protocolVersion': ?version,
          'command': 'request-use',
          'purpose': 'Capability check',
          'credentials': [
            {'alias': 'token', 'credentialId': h.credential.id, 'version': 1},
          ],
          'launch': run(h, 'unused', 'unused')['launch'],
        });
        expect(result['errorCode'], 'unsupported_capability');
        expect(result['protocolVersion'], 2);
        expect(h.service.owner.credentialUseRequests, isEmpty);
      }
    },
  );

  test(
    'one CLI grant runs two distinct plans and duplicate commands only query facts',
    () async {
      var starts = 0;
      final h = await RuntimeHarness.create(
        enableReusableCredentialUse: true,
        starter: (exe, argv, cwd, env) {
          starts++;
          return Process.start(
            exe,
            [File('test/support/credential_child.dart').absolute.path, ...argv],
            workingDirectory: cwd,
            environment: env,
            includeParentEnvironment: false,
            runInShell: false,
          );
        },
      );
      addTearDown(h.close);
      final request = await h.approve(protocolVersion: 2);
      final expires =
          h.service.owner.credentialUseRequests.single.credentialExpiresAt;
      final first = await h.client.execute(run(h, request, 'first'));
      expect(first['status'], 'accepted');
      expect(first['operationClaimed'], isTrue);
      expect(first.containsKey('attemptConsumed'), isFalse);
      await h.client.drainCredentialExecutions();
      final duplicate = await h.client.execute(run(h, request, 'first'));
      expect(duplicate['duplicate'], isTrue);
      expect(duplicate['executionState'], 'exited');
      expect(duplicate['executionId'], first['executionId']);
      final second = await h.client.execute(
        run(
          h,
          request,
          'second',
          argv: ['repo', 'view', 'northstar/agent-skills'],
        ),
      );
      expect(second['status'], 'accepted');
      await h.client.drainCredentialExecutions();
      expect(starts, 2);
      expect(
        h.service.owner.credentialUseRequests.single.credentialExpiresAt,
        expires,
      );
      expect(
        h.service.owner.credentialUseRequests.single.attemptConsumed,
        isFalse,
      );
      expect(h.service.owner.credentialExecutions.map((e) => e.operationId), [
        'first',
        'second',
      ]);
      final output = await h.client.execute({
        'protocolVersion': 2,
        'command': 'execution-output',
        'executionId': first['executionId'],
      });
      expect(output['protocolVersion'], 2);
      final text = (output['chunks'] as List)
          .map((c) => utf8.decode(base64Decode(c['dataBase64'] as String)))
          .join();
      expect(jsonDecode(text)['tokenMatches'], isTrue);
      for (final result in [first, second, duplicate, output]) {
        expect(jsonEncode(result), isNot(contains('synthetic-token')));
        expect(result, isNot(contains('material')));
      }
      expect(
        (await h.client.execute(
          run(h, request, 'first', argv: ['repo', 'list']),
        ))['errorCode'],
        'operation_conflict',
      );
      expect(starts, 2);
    },
  );

  test(
    'failed CLI operation does not consume approval and is not replayed',
    () async {
      var starts = 0;
      final h = await RuntimeHarness.create(
        enableReusableCredentialUse: true,
        starter: (exe, argv, cwd, env) async {
          starts++;
          if (starts == 1) {
            throw const ProcessException('synthetic-missing.exe', []);
          }
          return Process.start(
            exe,
            [File('test/support/credential_child.dart').absolute.path, ...argv],
            workingDirectory: cwd,
            environment: env,
            includeParentEnvironment: false,
            runInShell: false,
          );
        },
      );
      addTearDown(h.close);
      final request = await h.approve(protocolVersion: 2);
      await h.client.execute(run(h, request, 'failed'));
      await h.client.drainCredentialExecutions();
      final duplicate = await h.client.execute(run(h, request, 'failed'));
      expect(duplicate['executionState'], 'start_failed');
      expect(starts, 1);
      expect(
        (await h.client.execute(run(h, request, 'retry-explicitly')))['status'],
        'accepted',
      );
      await h.client.drainCredentialExecutions();
      expect(starts, 2);
      expect(h.service.owner.credentialExecutions.last.state, 'exited');
    },
  );

  for (final defect in [
    'truncated',
    'wrong-operation',
    'wrong-request',
    'duplicate-key',
  ]) {
    test(
      '$defect private claim is uncertain, and same operation retry cannot reissue material',
      () async {
        final h = await RuntimeHarness.create(
          enableReusableCredentialUse: true,
        );
        addTearDown(h.close);
        final request = await h.approve(protocolVersion: 2);
        final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final handling = proxy.listen((http) async {
          final input =
              jsonDecode(await utf8.decoder.bind(http).join())
                  as Map<String, dynamic>;
          final operation = Map<String, dynamic>.of(input)
            ..remove('sessionSecret');
          Object result;
          if (http.uri.path == '/capabilities') {
            result = {
              'status': 'ok',
              'protocolVersions': [1, 2],
              'capabilities': ['credential-use-reuse.v1'],
            };
          } else if (http.uri.path == '/credential-use/operation/status') {
            result =
                h.service.agent
                    .credentialUseOperationStatus(
                      h.client.sessionSecret!,
                      CredentialOperationInput.fromJson(operation),
                    )
                    ?.toPublicJson() ??
                {'protocolVersion': 2, 'status': 'not_found'};
          } else {
            final claim = await h.service.agent.beginCredentialUseOperation(
              h.client.sessionSecret!,
              CredentialOperationInput.fromJson(operation),
            );
            final payload =
                jsonDecode(jsonEncode(claim.toPrivateJson()))
                    as Map<String, dynamic>;
            if (defect == 'wrong-operation') {
              (payload['execution'] as Map)['operationId'] =
                  'another-operation';
            }
            if (defect == 'wrong-request') {
              (payload['execution'] as Map)['requestId'] = 'another-request';
            }
            http.response.headers.contentType = ContentType.json;
            http.response.write(switch (defect) {
              'truncated' => '{',
              'duplicate-key' => jsonEncode(
                payload,
              ).replaceFirst('{', '{"grantState":"available",'),
              _ => jsonEncode(payload),
            });
            await http.response.close();
            return;
          }
          http.response.headers.contentType = ContentType.json;
          http.response.write(jsonEncode(result));
          await http.response.close();
        });
        var starts = 0;
        final client = AgentClient(
          proxy.port,
          sessionSecret: h.client.sessionSecret,
          credentialProcessStarter: (exe, argv, cwd, env) async {
            starts++;
            throw StateError('Lost material cannot start a process');
          },
        );
        addTearDown(() async {
          client.close();
          await proxy.close(force: true);
          await handling.cancel();
        });
        final first = await client.execute(run(h, request, 'lost'));
        expect(first['errorCode'], 'material_claim_failed');
        expect(first['operationClaimed'], isTrue);
        expect(first['retryable'], isFalse);
        final duplicate = await client.execute(run(h, request, 'lost'));
        expect(duplicate['status'], 'ok');
        expect(duplicate['duplicate'], isTrue);
        expect(duplicate['executionState'], 'preparing');
        expect(starts, 0);
        expect(h.service.owner.credentialExecutions, hasLength(1));
      },
    );
  }

  test(
    'a lost hosted acknowledgement remains uncertain and does not replay a command',
    () async {
      var starts = 0, loseFirst = true;
      final h = await RuntimeHarness.create(enableReusableCredentialUse: true);
      addTearDown(h.close);
      late CredentialExecutionHost host;
      final server = await AgentServer.start(
        h.service.agent,
        port: 0,
        enableReusableCredentialUse: true,
        credentialExecutionHandler: (session, input) async {
          final result = await host.execute(session, input);
          if (input['command'] == 'run-use' &&
              result['status'] == 'accepted' &&
              loseFirst) {
            loseFirst = false;
            throw StateError(
              'Synthetic lost hosted acknowledgement after claim',
            );
          }
          return result;
        },
      );
      host = CredentialExecutionHost(
        port: server.port,
        processStarter: (exe, argv, cwd, env) {
          starts++;
          return Process.start(
            exe,
            [File('test/support/credential_child.dart').absolute.path, ...argv],
            workingDirectory: cwd,
            environment: env,
            includeParentEnvironment: false,
            runInShell: false,
          );
        },
      );
      final client = AgentClient(
        server.port,
        sessionSecret: h.client.sessionSecret,
        hostedCredentialExecutions: true,
      );
      addTearDown(() async {
        await host.drain();
        host.close();
        client.close();
        await server.close();
      });
      final request = await h.approve(protocolVersion: 2);
      final lost = await client.execute(run(h, request, 'host-lost'));
      expect(lost['operationClaimed'], isTrue);
      expect(lost['errorCode'], 'execution_unknown');
      expect(lost['retryable'], isFalse);
      await host.drain();
      final repeated = await client.execute(run(h, request, 'host-lost'));
      expect(repeated['executionState'], 'exited');
      expect(repeated['duplicate'], isTrue);
      expect(starts, 1);
    },
  );

  test(
    'protocol errors never upgrade old grants or create malformed operations',
    () async {
      final h = await RuntimeHarness.create(enableReusableCredentialUse: true);
      addTearDown(h.close);
      final v1 = await h.approve();
      expect(
        (await h.client.execute(run(h, v1, 'upgrade')))['errorCode'],
        'unsupported_protocol',
      );
      final v2 = await h.approve(protocolVersion: 2);
      final missing = run(h, v2, 'missing')..remove('operationId');
      expect((await h.client.execute(missing))['errorCode'], 'invalid_type');
      final unknown = run(h, v2, 'unsupported')..['protocolVersion'] = 3;
      expect(
        (await h.client.execute(unknown))['errorCode'],
        'unsupported_protocol',
      );
      final query = run(h, v2, 'unclaimed')..['command'] = 'operation-status';
      expect((await h.client.execute(query))['status'], 'not_found');
      expect(h.service.owner.credentialExecutions, isEmpty);
      final other = AgentClient(h.server.port);
      addTearDown(other.close);
      await other.execute({'command': 'session', 'chatLabel': 'Another'});
      expect((await other.execute(query))['errorCode'], 'session_mismatch');
    },
  );

  test(
    'hosted concurrent clients use one operation, including after revocation',
    () async {
      var starts = 0;
      final h = await RuntimeHarness.create(enableReusableCredentialUse: true);
      addTearDown(h.close);
      late CredentialExecutionHost host;
      final server = await AgentServer.start(
        h.service.agent,
        port: 0,
        enableReusableCredentialUse: true,
        credentialExecutionHandler: (session, input) =>
            host.execute(session, input),
      );
      host = CredentialExecutionHost(
        port: server.port,
        processStarter: (exe, argv, cwd, env) {
          starts++;
          return Process.start(
            exe,
            [File('test/support/credential_child.dart').absolute.path, ...argv],
            workingDirectory: cwd,
            environment: env,
            includeParentEnvironment: false,
            runInShell: false,
          );
        },
      );
      final clients = List.generate(
        5,
        (_) => AgentClient(
          server.port,
          sessionSecret: h.client.sessionSecret,
          hostedCredentialExecutions: true,
        ),
      );
      addTearDown(() async {
        await host.drain();
        host.close();
        for (final c in clients) {
          c.close();
        }
        await server.close();
      });
      final request = await h.approve(protocolVersion: 2);
      final results = await Future.wait(
        clients.map((c) => c.execute(run(h, request, 'concurrent'))),
      );
      expect(results.where((r) => r['status'] == 'accepted'), hasLength(1));
      expect(results.map((r) => r['executionId']).toSet(), hasLength(1));
      await host.drain();
      expect(starts, 1);
      await h.service.owner.revokeCredentialUse(request);
      final duplicate = await clients.first.execute(
        run(h, request, 'concurrent'),
      );
      expect(duplicate['executionState'], 'exited');
      expect(duplicate['grantState'], 'revoked');
      expect(
        (await clients.first.execute(
          run(h, request, 'new-after-revoke'),
        ))['errorCode'],
        'grant_revoked',
      );
      expect(starts, 1);
    },
  );
}

Future<void> removeFixture(Directory root) async {
  final resolved = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  if (resolved.toLowerCase() != root.absolute.path.toLowerCase() ||
      !resolved.toLowerCase().startsWith(
        '${temp.toLowerCase()}${Platform.pathSeparator}',
      )) {
    throw StateError('Unexpected native fixture directory');
  }
  await root.delete(recursive: true);
}
