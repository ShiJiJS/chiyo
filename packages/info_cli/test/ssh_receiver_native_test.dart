import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

void main() {
  final root = Platform.environment['D7_SSH_FIXTURE'];
  final port = Platform.environment['D7_SSH_PORT'];
  final executable = Platform.environment['D7_SSH_EXE'];
  test(
    'real Windows SSH authenticates only the approved key and confirmed host, preserves literal remote arguments, and cleans each attempt',
    () async {
      final key = await File('$root/client').readAsBytes();
      final wrong = await File('$root/wrong-client').readAsBytes();
      final host = (await File(
        '$root/host.pub',
      ).readAsString()).split(' ').take(2).join(' ');
      final changed = (await File(
        '$root/wrong-client.pub',
      ).readAsString()).split(' ').take(2).join(' ');
      Future<void> run(
        List<int> bytes,
        String known,
        int exit, {
        bool literal = false,
      }) async {
        final h = await RuntimeHarness.create(
          fileBytes: bytes,
          executablePath: executable!,
          inspectTool: true,
        );
        addTearDown(h.close);
        await h.service.owner.configureSshKnownHosts(
          'Synthetic explicitly confirmed host',
          utf8.encode('$known\n'),
        );
        final id = await h.approve(
          receiver: 'ssh_identity',
          argv: [
            '-T',
            '-o',
            'BatchMode=yes',
            '-i',
            {'file': 'token'},
            '-p',
            port!,
            'fixture@127.0.0.1',
            if (literal) ...[
              '/usr/bin/printf',
              '%s',
              'literal; printf SHOULD_NOT_EXECUTE',
            ] else
              '/usr/bin/true',
          ],
        );
        final accepted = await h.client.execute({
          'command': 'run-use',
          'requestId': id,
        });
        expect(accepted['status'], 'accepted');
        await h.client.drainCredentialExecutions();
        final status = await h.client.execute({
          'command': 'execution-status',
          'executionId': accepted['executionId'],
        });
        expect(
          status['executionState'],
          'exited',
          reason: '${status['errorCode']}',
        );
        expect(status['exitCode'], exit);
        expect(status['cleanupState'], 'complete');
        final output = await h.client.execute({
          'command': 'execution-output',
          'executionId': accepted['executionId'],
        });
        if (literal) {
          final stdout = (output['chunks'] as List)
              .where((c) => c['stream'] == 'stdout')
              .expand<int>((c) => base64Decode(c['dataBase64'] as String))
              .toList();
          expect(utf8.decode(stdout), 'literal; printf SHOULD_NOT_EXECUTE');
        }
        expect(
          (await h.client.execute({
            'command': 'run-use',
            'requestId': id,
          }))['errorCode'],
          'attempt_consumed',
        );
      }

      await run(key, '[127.0.0.1]:$port $host', 0, literal: true);
      await run(wrong, '[127.0.0.1]:$port $host', 255);
      await run(key, '[unknown.invalid]:$port $host', 255);
      await run(key, '[127.0.0.1]:$port $changed', 255);
    },
    skip:
        !Platform.isWindows ||
        root == null ||
        port == null ||
        executable == null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
