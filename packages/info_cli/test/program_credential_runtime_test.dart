import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_cli/agent_client.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

void main() {
  test(
    'legacy private response cannot substitute a program receiver and start it',
    () async {
      final h = await RuntimeHarness.create();
      addTearDown(h.close);
      final request = await h.approve();
      var starts = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((http) async {
        final input =
            jsonDecode(await utf8.decoder.bind(http).join())
                as Map<String, dynamic>;
        Map<String, Object?> response;
        if (http.uri.path == '/credential-use/consume') {
          final material = await h.service.agent.consumeCredentialUse(
            input['sessionSecret'] as String,
            input['requestId'] as String,
          );
          final forged = Map<String, dynamic>.from(material.toPrivateJson());
          final plan = Map<String, dynamic>.from(forged['approvedPlan'] as Map);
          plan['receiver'] = 'program_stdin';
          plan['env'] = <String, dynamic>{};
          plan['stdin'] = {'secret': 'token'};
          forged['approvedPlan'] = plan;
          response = forged;
        } else {
          await h.service.agent.reportCredentialExecution(
            CredentialExecutionReport.fromPrivateJson(input),
          );
          response = {'status': 'ok'};
        }
        http.response.headers.contentType = ContentType.json;
        http.response.write(jsonEncode(response));
        await http.response.close();
      });
      final client = AgentClient(
        server.port,
        sessionSecret: h.client.sessionSecret,
        credentialProcessStarter: (exe, argv, cwd, env) async {
          starts++;
          throw StateError('Unapproved legacy program reached process starter');
        },
      );
      addTearDown(() async {
        client.close();
        await subscription.cancel();
        await server.close(force: true);
      });
      final accepted = await client.execute({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': request,
      });
      expect(accepted['status'], 'accepted');
      await client.drainCredentialExecutions();
      expect(starts, 0);
      expect(
        h.service.owner.credentialExecutions.single.state,
        'prepare_failed',
      );
    },
  );
  test(
    'CLI rejects v1 program requests without creating approval or execution',
    () async {
      final h = await RuntimeHarness.create(enableReusableCredentialUse: true);
      addTearDown(h.close);
      for (final receiver in CredentialLaunchPlan.programReceivers) {
        final result = await h.client.execute({
          'protocolVersion': 1,
          'command': 'request-use',
          'purpose': 'Synthetic v1 rejection',
          'credentials': [
            {'alias': 'token', 'credentialId': h.credential.id, 'version': 1},
          ],
          'launch': {
            'receiver': receiver,
            'executable': h.executablePath,
            'cwd': Directory.current.path,
            'argv': [
              if (receiver == 'program_file') {'file': 'token'},
            ],
            'env': {
              if (receiver == 'program_env') 'TOKEN': {'secret': 'token'},
            },
            if (receiver == 'program_stdin') 'stdin': {'secret': 'token'},
          },
        });
        expect(result['errorCode'], 'unsupported_protocol');
      }
      expect(h.service.owner.credentialUseRequests, isEmpty);
      expect(h.service.owner.credentialExecutions, isEmpty);
    },
  );

  for (final receiver in CredentialLaunchPlan.programReceivers) {
    for (final fileForm in [false, if (receiver == 'program_file') true]) {
      for (final largeInput in [false, if (receiver == 'program_stdin') true]) {
        test(
          '$receiver delivers ${fileForm ? 'file' : 'string'} with native worker and masks output (largeInput=$largeInput)',
          () async {
            final h = await RuntimeHarness.create(
              inspectTool: true,
              enableReusableCredentialUse: true,
              fileBytes: fileForm ? utf8.encode('synthetic-file-secret') : null,
            );
            addTearDown(h.close);
            var version = h.credential.version;
            if (largeInput) {
              final c = await h.service.owner.rotateStringCredential(
                h.credential.id,
                h.credential.revision,
                'S' * 65536,
              );
              version = c.version;
            }
            final launch = <String, dynamic>{
              'receiver': receiver,
              'executable': h.executablePath,
              'argv': [
                File(
                  'test/support/program_credential_child.dart',
                ).absolute.path,
                receiver,
                if (receiver == 'program_file') {'file': 'token'},
              ],
              'cwd': Directory.current.path,
              'env': {
                if (receiver == 'program_env')
                  'SYNTHETIC_SECRET': {'secret': 'token'},
                // These target-only overrides must not break worker receipt paths.
                'TMPDIR': 'target-only-temp',
                'TEMP': 'target-only-temp',
              },
              if (receiver == 'program_stdin') 'stdin': {'secret': 'token'},
            };
            final request = await h.client.execute({
              'protocolVersion': 2,
              'command': 'request-use',
              'purpose': 'Synthetic program test',
              'credentials': [
                {
                  'alias': 'token',
                  'credentialId': h.credential.id,
                  'version': version,
                },
              ],
              'launch': launch,
            });
            expect(request['status'], 'pending', reason: '$request');
            await h.service.owner.decideCredentialUse(
              request['requestId'] as String,
              approveCredential: true,
            );
            final run = {
              'protocolVersion': 2,
              'command': 'run-use',
              'requestId': request['requestId'],
              'operationId': 'one',
              'launch': launch,
            };
            final accepted = await h.client.execute(run);
            expect(accepted['status'], 'accepted', reason: '$accepted');
            await h.client.drainCredentialExecutions();
            final status = await h.client.execute({
              'protocolVersion': 2,
              'command': 'execution-status',
              'executionId': accepted['executionId'],
            });
            expect(status['executionState'], 'exited', reason: '$status');
            expect(status['exitCode'], 0, reason: '$status');
            final output = await h.client.execute({
              'protocolVersion': 2,
              'command': 'execution-output',
              'executionId': accepted['executionId'],
            });
            String stream(String name) => utf8.decode(
              (output['chunks'] as List)
                  .where((c) => c['stream'] == name)
                  .expand<int>((c) => base64Decode(c['dataBase64'] as String))
                  .toList(),
            );
            expect(
              stream('stdout'),
              contains(
                'received:${largeInput
                    ? 65536
                    : fileForm
                    ? 21
                    : 15}',
              ),
            );
            expect(stream('stdout'), contains('[REDACTED]'));
            expect(stream('stderr'), '[REDACTED]');
            expect(jsonEncode(output), isNot(contains('synthetic-token')));
            final duplicate = await h.client.execute(run);
            expect(duplicate['duplicate'], isTrue);
            expect(h.service.owner.credentialExecutions, hasLength(1));
            if (receiver == 'program_file') {
              final finalStatus = await h.waitForMaterialCleanup(
                accepted['executionId'] as String,
              );
              expect(finalStatus['cleanupState'], 'complete');
              final lease =
                  h.service.owner.credentialExecutions.single.materialLease!;
              expect(await Directory(lease.path).exists(), isFalse);
            }
            final changed = {
              ...launch,
              'executable': Platform.isWindows
                  ? r'C:\Windows\System32\cmd.exe'
                  : '/bin/sh',
            };
            final denied = await h.client.execute({
              ...run,
              'operationId': 'different-tool',
              'launch': changed,
            });
            expect(denied['errorCode'], 'scope_not_approved');
            expect(h.service.owner.credentialExecutions, hasLength(1));
          },
          skip: !Platform.isMacOS && !Platform.isWindows,
        );
      }
    }
  }
}
