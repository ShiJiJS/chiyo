import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';
import 'credential_reuse_runtime_test.dart' show removeFixture;

void main() {
  test(
    'independent JSON-lines CLI negotiates v2, runs distinct operations and never repeats a claimed operation',
    () async {
      final root = await Directory.systemTemp.createTemp('reuse-json-lines-');
      final h = await RuntimeHarness.create(enableReusableCredentialUse: true);
      final compiled = Platform.environment['D6_COMPILED_CLI'];
      for (final name in ['api', 'repo']) {
        await File('${root.path}/$name').writeAsString('''
import 'dart:io';
void main() {
  File('started.txt').writeAsStringSync('$name\\n', mode: FileMode.append);
  stdout.writeln('operation-$name');
  stdout.writeln(Platform.environment['GH_TOKEN']);
  ${name == 'repo' ? 'exit(7);' : ''}
}
''');
      }
      final cli = await Process.start(compiled ?? Platform.resolvedExecutable, [
        if (compiled == null) ...['run', 'bin/info.dart'],
        '--port',
        '${h.server.port}',
      ]);
      final lines = StreamIterator(
        cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = cli.stderr.drain<void>();
      addTearDown(() async {
        await cli.stdin.close();
        await cli.exitCode.timeout(const Duration(seconds: 15));
        await lines.cancel();
        await errors;
        await h.close();
        await removeFixture(root);
      });
      final responses = <Map<String, dynamic>>[];
      Future<Map<String, dynamic>> command(Map<String, Object?> input) async {
        cli.stdin.writeln(jsonEncode(input));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        final result = jsonDecode(lines.current) as Map<String, dynamic>;
        responses.add(result);
        return result;
      }

      final capabilities = await command({'command': 'capabilities'});
      expect(capabilities['capabilities'], ['credential-use-reuse.v1']);
      await command({'command': 'session', 'chatLabel': 'Independent v2 CLI'});
      Map<String, Object?> launch(List<String> argv) => {
        'receiver': 'gh_token',
        'executable': h.executablePath,
        'argv': argv,
        'cwd': root.path,
        'env': {
          'GH_TOKEN': {'secret': 'token'},
        },
      };
      final request = await command({
        'protocolVersion': 2,
        'command': 'request-use',
        'purpose': 'Independent reusable CLI flow',
        'credentials': [
          {'alias': 'token', 'credentialId': h.credential.id, 'version': 1},
        ],
        'launch': launch(['api', 'user']),
      });
      expect(request['status'], 'pending');
      final id = request['requestId'] as String;
      await h.service.owner.decideCredentialUse(id, approveCredential: true);
      final expires =
          h.service.owner.credentialUseRequests.single.credentialExpiresAt;
      final approved = await command({'command': 'status', 'requestId': id});
      expect(
        (approved['decision'] as Map)['credentialUse']['reusable'],
        isTrue,
      );
      expect(
        (approved['decision'] as Map)['credentialUse'].containsKey(
          'maxAttempts',
        ),
        isFalse,
      );
      Map<String, Object?> run(String operation, List<String> argv) => {
        'protocolVersion': 2,
        'command': 'run-use',
        'requestId': id,
        'operationId': operation,
        'launch': launch(argv),
      };
      final first = await command(run('json-a', ['api', 'user']));
      expect(first['status'], 'accepted');
      final duplicate = await command(run('json-a', ['api', 'user']));
      expect(duplicate['duplicate'], isTrue);
      expect(duplicate['executionId'], first['executionId']);
      final second = await command(
        run('json-b', ['repo', 'view', 'northstar/agent-skills']),
      );
      expect(second['status'], 'accepted');
      for (final accepted in [first, second]) {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (true) {
          final status = await command({
            'protocolVersion': 2,
            'command': 'execution-status',
            'executionId': accepted['executionId'],
          });
          if (status['executionState'] == 'exited') break;
          if (DateTime.now().isAfter(deadline)) {
            fail('V2 execution did not produce a terminal receipt');
          }
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        final output = await command({
          'protocolVersion': 2,
          'command': 'execution-output',
          'executionId': accepted['executionId'],
        });
        final text = (output['chunks'] as List)
            .map((c) => utf8.decode(base64Decode(c['dataBase64'] as String)))
            .join();
        expect(text, contains('[REDACTED]'));
        expect(text, isNot(contains('synthetic-token')));
      }
      expect(h.service.owner.credentialExecutions.map((e) => e.exitCode), [
        0,
        7,
      ]);
      expect(
        h.service.owner.credentialExecutions.every((e) => e.workerPid != null),
        isTrue,
      );
      expect(
        h.service.owner.credentialUseRequests.single.credentialExpiresAt,
        expires,
      );
      expect((await File('${root.path}/started.txt').readAsLines())..sort(), [
        'api',
        'repo',
      ]);
      expect(
        (await command(run('json-a', ['api', 'user'])))['duplicate'],
        isTrue,
      );
      expect(h.service.owner.credentialExecutions, hasLength(2));
      expect(jsonEncode(responses), isNot(contains('synthetic-token')));
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
