import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

void main() {
  final root = Platform.environment['D7_SSH_FIXTURE'];
  final port = Platform.environment['D7_SSH_PORT'];
  final executable = Platform.environment['D7_SSH_EXE'];
  for (final protocol in [1, 2]) {
    test(
      'v$protocol real Windows SSH authenticates only the approved key and confirmed host, preserves literal remote arguments, and cleans each attempt',
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
            enableReusableCredentialUse: protocol == 2,
          );
          addTearDown(h.close);
          await h.service.owner.configureSshKnownHosts(
            'Synthetic explicitly confirmed host',
            utf8.encode('$known\n'),
          );
          final id = await h.approve(
            receiver: 'ssh_identity',
            protocolVersion: protocol,
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
          final approved = h.service.owner.credentialUseRequests.single;
          final deadline = approved.credentialExpiresAt;
          final call = <String, dynamic>{
            'protocolVersion': protocol,
            'command': 'run-use',
            'requestId': id,
            if (protocol == 2) ...{
              'operationId': 'ssh-first',
              'launch': approved.toRequestInputJson()['launch'],
            },
          };
          final accepted = await h.client.execute(call);
          expect(accepted['status'], 'accepted', reason: jsonEncode(accepted));
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
          expect(
            (await h.waitForMaterialCleanup(
              accepted['executionId'] as String,
            ))['cleanupState'],
            'complete',
          );
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
          final repeated = await h.client.execute(call);
          if (protocol == 1) {
            expect(repeated['errorCode'], 'attempt_consumed');
          } else {
            expect(repeated['duplicate'], isTrue);
            expect(repeated['executionId'], accepted['executionId']);
            expect(
              h.service.owner.credentialGrantState(
                h.service.owner.credentialUseRequests.single,
              ),
              'available',
            );
            if (literal) {
              final next = await h.client.execute({
                ...call,
                'operationId': 'ssh-second',
                'launch': {
                  ...Map<String, dynamic>.from(
                    approved.toRequestInputJson()['launch'] as Map,
                  ),
                  'argv': [
                    '-T',
                    '-o',
                    'BatchMode=yes',
                    '-i',
                    {'file': 'token'},
                    '-p',
                    port,
                    'fixture@127.0.0.1',
                    '/usr/bin/true',
                  ],
                },
              });
              expect(next['status'], 'accepted');
              await h.client.drainCredentialExecutions();
              final second = await h.client.execute({
                'command': 'execution-status',
                'executionId': next['executionId'],
              });
              expect(second['executionState'], 'exited');
              expect(second['exitCode'], 0);
              expect(
                (await h.waitForMaterialCleanup(
                  next['executionId'] as String,
                ))['cleanupState'],
                'complete',
              );
              expect(h.service.owner.credentialUseRequests, hasLength(1));
              expect(h.service.owner.credentialExecutions, hasLength(2));
              expect(
                h.service.owner.credentialExecutions
                    .map((e) => e.jobName)
                    .toSet(),
                hasLength(2),
              );
            }
            expect(
              h.service.owner.credentialUseRequests.single.credentialExpiresAt,
              deadline,
            );
          }
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
}
