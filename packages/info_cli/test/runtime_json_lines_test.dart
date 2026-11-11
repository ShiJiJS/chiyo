import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

void main() {
  test(
    'real CLI runs only the approved plan and EOF waits for its tree without ending the shared session',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'runtime-json-tree-',
      );
      final release = File('${folder.path}/release');
      final ready = File('${folder.path}/ready');
      await File('${folder.path}/api').writeAsString('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  stdout.writeln(jsonEncode({'tokenMatches': Platform.environment['GH_TOKEN'] == 'synthetic-token',
    'parentTokenAbsent': !Platform.environment.containsKey('GITHUB_TOKEN')}));
  await stdout.flush();
  await Process.start(Platform.resolvedExecutable, ['descendant.dart'], mode: ProcessStartMode.detached);
  exit(7);
}
''');
      await File('${folder.path}/descendant.dart').writeAsString('''
import 'dart:io';
Future<void> main() async {
  await File('ready').writeAsString('ready');
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (!await File('release').exists()) {
    if (DateTime.now().isAfter(end)) exit(70);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
''');
      final h = await RuntimeHarness.create();
      final cli = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'bin/info.dart', '--port', '${h.server.port}'],
        environment: {'GITHUB_TOKEN': 'synthetic-parent-must-not-reach-child'},
      );
      final lines = StreamIterator(
        cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = cli.stderr.drain<void>();
      addTearDown(() async {
        await release.writeAsString('release');
        await cli.stdin.close();
        await cli.exitCode.timeout(const Duration(seconds: 15));
        await lines.cancel();
        await errors;
        await h.close();
        await folder.delete(recursive: true);
      });
      Future<Map<String, dynamic>> command(Map<String, Object?> data) async {
        cli.stdin.writeln(jsonEncode(data));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      expect(
        (await command({
          'command': 'session',
          'chatLabel': 'Real CLI tree',
          'externalChatId': 'synthetic-runtime-cli',
        }))['status'],
        'ok',
      );
      Future<String> request() async {
        final result = await command({
          'protocolVersion': 1,
          'command': 'request-use',
          'purpose': 'Real CLI controlled launch',
          'credentials': [
            {'alias': 'token', 'credentialId': h.credential.id, 'version': 1},
          ],
          'launch': {
            'receiver': 'gh_token',
            'executable': Platform.resolvedExecutable,
            'argv': ['api', 'user'],
            'cwd': folder.path,
            'env': {
              'GH_TOKEN': {'secret': 'token'},
            },
          },
        });
        expect(result['status'], 'pending', reason: jsonEncode(result));
        final id = result['requestId'] as String;
        await h.service.owner.decideCredentialUse(id, approveCredential: true);
        return id;
      }

      final used = await request();
      final unused = await request();
      final modified = await command({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': used,
        'launch': {},
      });
      expect(modified['errorCode'], 'unknown_field');
      expect(
        h.service.owner.credentialUseRequests
            .singleWhere((r) => r.id == used)
            .attemptConsumed,
        isFalse,
      );
      final accepted = await command({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': used,
      });
      expect(accepted['status'], 'accepted');
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await ready.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Real CLI descendant did not start');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final replay = await command({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': used,
      });
      expect(replay['errorCode'], 'attempt_consumed');
      expect(replay['executionId'], accepted['executionId']);
      final output = await command({
        'command': 'execution-output',
        'executionId': accepted['executionId'],
      });
      final raw = <int>[
        for (final dynamic chunk in output['chunks'] as List)
          ...base64Decode(chunk['dataBase64'] as String),
      ];
      expect(jsonDecode(utf8.decode(raw)), {
        'tokenMatches': true,
        'parentTokenAbsent': true,
      });
      await cli.stdin.close();
      expect(
        await cli.exitCode
            .then((_) => true)
            .timeout(const Duration(milliseconds: 150), onTimeout: () => false),
        isFalse,
      );
      await release.writeAsString('release');
      expect(await cli.exitCode.timeout(const Duration(seconds: 10)), 0);
      final execution = h.service.owner.credentialExecutions.single;
      expect(execution.state, 'exited');
      expect(execution.exitCode, 7);
      expect(
        h.service.owner.credentialGrantState(
          h.service.owner.credentialUseRequests.singleWhere(
            (r) => r.id == unused,
          ),
        ),
        'available',
      );
    },
    skip: !Platform.isWindows,
  );
  test(
    'real JSON-lines CLI bounds and rejects each invalid byte line and continues the same session',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final server = await AgentServer.start(service.agent, port: 0);
      final cli = await Process.start(Platform.resolvedExecutable, [
        'run',
        'bin/info.dart',
        '--port',
        '${server.port}',
      ]);
      final lines = StreamIterator(
        cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = cli.stderr.drain<void>();
      addTearDown(() async {
        await cli.stdin.close();
        await cli.exitCode.timeout(const Duration(seconds: 10));
        await lines.cancel();
        await errors;
        await server.close();
        await service.close();
      });
      Future<Map<String, dynamic>> response() async {
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      cli.stdin.writeln('{"command":"session","chatLabel":"Transport limits"}');
      expect((await response())['status'], 'ok');
      cli.stdin.add([
        ...utf8.encode('{"command":"request-use","purpose":"'),
        ...List<int>.filled(262144, 120),
        ...utf8.encode('"}\n'),
      ]);
      expect((await response())['errorCode'], 'limit_exceeded');
      cli.stdin.add([0xff, 0x0a]);
      expect((await response())['errorCode'], 'invalid_json');
      cli.stdin.writeln(
        '{"command":"run-use","command":"session","requestId":"fake"}',
      );
      expect((await response())['errorCode'], 'invalid_json');
      cli.stdin.writeln('{"command":"credential-catalog"}');
      expect((await response())['status'], 'ok');
      cli.stdin.writeln(
        '{"protocolVersion":1,"command":"run-use","requestId":"unknown"}',
      );
      expect((await response())['errorCode'], 'session_mismatch');
    },
  );
}
