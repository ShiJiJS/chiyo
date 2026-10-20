import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:info_core/info_core.dart';
import 'support/runtime_harness.dart';
import '../../info_core/test/ssh_credential_use_test.dart' show knownHostBytes;

void main() {
  test(
    'approved SSH receives exactly one key path and immutable host snapshot with private empty configurations',
    () async {
      late List<String> paths;
      final h = await RuntimeHarness.create(
        fileBytes: utf8.encode('SYNTHETIC_SSH_PRIVATE_MATERIAL'),
        starter: (exe, argv, cwd, env) async {
          String option(String name) => argv
              .firstWhere((v) => v.startsWith('$name='))
              .substring(name.length + 1)
              .replaceAll('"', '');
          paths = [
            argv[argv.indexOf('-i') + 1],
            argv[argv.indexOf('-F') + 1],
            option('UserKnownHostsFile'),
            option('GlobalKnownHostsFile'),
          ];
          return Process.start(
            exe,
            [
              File('test/support/ssh_file_child.dart').absolute.path,
              base64Encode(knownHostBytes()),
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
      await h.service.owner.configureSshKnownHosts(
        'explicit-test-host',
        knownHostBytes(),
      );
      final request = await h.approve(
        receiver: 'ssh_identity',
        argv: [
          '-T',
          '-o',
          'BatchMode=yes',
          '-i',
          {'file': 'token'},
          '-i',
          {'file': 'token'},
          '-p',
          '2222',
          'developer@test.beichen.example',
          '/usr/bin/printf',
          '%s',
          '{{SSH_KEY_FILE}}',
        ],
      );
      final run = await h.client.execute({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': request,
      });
      expect(run['status'], 'accepted');
      await h.client.drainCredentialExecutions();
      final status = await h.client.execute({
        'command': 'execution-status',
        'executionId': run['executionId'],
      });
      expect(
        status['executionState'],
        'exited',
        reason: '${status['errorCode']}',
      );
      expect(status['exitCode'], 0);
      expect(status['cleanupState'], 'complete');
      final output = await h.client.execute({
        'command': 'execution-output',
        'executionId': run['executionId'],
      });
      final bytes = (output['chunks'] as List)
          .where((c) => c['stream'] == 'stdout')
          .expand<int>((c) => base64Decode(c['dataBase64'] as String))
          .toList();
      expect(jsonDecode(utf8.decode(bytes)), {
        'keyExact': true,
        'hostsExact': true,
        'emptyConfig': true,
        'emptyGlobal': true,
        'strictHost': true,
        'oneIdentity': true,
        'batch': true,
        'noAmbientAuth': true,
        'sameFileReference': true,
        'literalPlaceholder': true,
      });
      for (final path in paths) {
        expect(await File(path).exists(), isFalse);
      }
      expect(
        (await h.client.execute({
          'protocolVersion': 1,
          'command': 'run-use',
          'requestId': request,
        }))['errorCode'],
        'attempt_consumed',
      );
    },
    skip: !Platform.isWindows,
  );
}
