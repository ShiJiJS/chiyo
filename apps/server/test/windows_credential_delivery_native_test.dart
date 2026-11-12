import 'dart:convert';
import 'dart:io';

import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';

import 'support/device_credential_fixture.dart';

Future<void> decide(
  DeviceCredentialFixture fixture,
  String id,
  WorkspaceApprovalAction action,
) async {
  final detail = approvalDetailFromJson(
    await fixture.owner.request('GET', '/v1/owner/approvals/details/$id'),
  );
  await fixture.owner.request(
    'POST',
    '/v1/owner/approvals/decisions',
    approvalChangeToJson(
      WorkspaceApprovalChange(
        operationId: 'windows-${action.name}-${id.replaceAll('=', '')}',
        requestId: id,
        reviewToken: detail.reviewToken,
        action: action,
        selected: action == WorkspaceApprovalAction.approve
            ? detail.scopes.map((scope) => scope.id)
            : const [],
        credentialMinutes: 15,
      ),
    ),
  );
}

Future<ManagedCredential> credential(
  DeviceCredentialFixture fixture,
  String secret,
) => fixture.runtime.run(() async {
  final saved = await fixture.runtime.service.owner.createStringCredential(
    name: 'Synthetic Windows credential',
    publicPurpose: '',
    secret: secret,
  );
  return fixture.runtime.service.owner.updateCredentialMetadata(
    saved.id,
    saved.revision,
    name: saved.name,
    publicPurpose: '',
    privateNote: '',
    suggestedBinding: '',
    discoverable: true,
  );
});

void main() {
  for (final receiver in CredentialLaunchPlan.programReceivers) {
    test(
      'Windows HTTPS $receiver preserves Unicode and whitespace through the native worker',
      () async {
        final fixture = await DeviceCredentialFixture.create();
        final root = Directory(await fixture.root.resolveSymbolicLinks());
        final client = AgentClient.remote(
          fixture.profiles.first,
          requireSubmissionMetadata: true,
          sourceAgent: 'Synthetic Windows program agent',
          externalChatId: 'synthetic-windows-program-chat',
          deviceFileStateDirectory: Directory(
            '${root.path}/private/Windows 材料 空格',
          ),
        );
        addTearDown(() async {
          await client.drainCredentialExecutions();
          client.close();
          await fixture.dispose();
        });
        const secret = '  Synthetic 中文🧭 "quote" \\slash\r\nline\n  ';
        final saved = await credential(fixture, secret);
        await client.openLifecycleSession('Synthetic Windows program chat');
        final launch = <String, dynamic>{
          'receiver': receiver,
          'executable': Platform.resolvedExecutable,
          'argv': [
            File(
              '../../packages/info_cli/test/support/program_credential_child.dart',
            ).absolute.path,
            receiver,
            if (receiver == 'program_file') {'file': 'token'},
          ],
          'cwd': root.path,
          'env': {
            if (receiver == 'program_env')
              'SYNTHETIC_SECRET': {'secret': 'token'},
          },
          if (receiver == 'program_stdin') 'stdin': {'secret': 'token'},
        };
        final request = await client.execute({
          'protocolVersion': 2,
          'command': 'request-use',
          'purpose': 'Synthetic Windows exact bytes',
          'credentials': [
            {
              'alias': 'token',
              'credentialId': saved.id,
              'version': saved.version,
            },
          ],
          'launch': launch,
        });
        expect(request['status'], 'pending', reason: '$request');
        final run = {
          'protocolVersion': 2,
          'command': 'run-use',
          'requestId': request['requestId'],
          'operationId': 'exact-input',
          'launch': launch,
        };
        expect((await client.execute(run))['errorCode'], 'request_pending');
        expect(fixture.repo.credentialExecutions, isEmpty);
        await decide(
          fixture,
          request['requestId'] as String,
          WorkspaceApprovalAction.approve,
        );
        final accepted = await client.execute(run);
        expect(accepted['status'], 'accepted', reason: '$accepted');
        await client.drainCredentialExecutions();
        final status = await client.execute({
          'command': 'execution-status',
          'executionId': accepted['executionId'],
        });
        expect(status['executionState'], 'exited', reason: '$status');
        expect(status['exitCode'], 0, reason: '$status');
        expect(
          status['cleanupState'],
          receiver == 'program_file' ? 'complete' : 'not_needed',
        );
        final output = await client.execute({
          'command': 'execution-output',
          'executionId': accepted['executionId'],
        });
        String stream(String name) => utf8.decode([
          for (final dynamic chunk in output['chunks'] as List)
            if (chunk['stream'] == name)
              ...base64Decode(chunk['dataBase64'] as String),
        ]);
        // The child echoes the actual bytes. Exact full redaction on stderr
        // proves Unicode, CRLF and spaces survived, not just the byte count.
        expect(stream('stderr'), '[REDACTED]');
        expect(
          stream('stdout'),
          matches(
            RegExp(
              '^received:${utf8.encode(secret).length}\\r?\\n\\[REDACTED\\]',
            ),
          ),
        );
        if (receiver == 'program_file') {
          final material = RegExp(
            r'material:([^\r\n]+)',
          ).firstMatch(stream('stdout'))![1]!;
          expect(await File(material).exists(), isFalse);
        }
        expect((await client.execute(run))['duplicate'], isTrue);
        expect(fixture.repo.credentialExecutions, hasLength(1));
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'Windows HTTPS plaintext reads require separate live approval and durable audit',
    () async {
      var now = DateTime.now().toUtc();
      final fixture = await DeviceCredentialFixture.create(clock: () => now);
      final client = AgentClient.remote(
        fixture.profiles.first,
        requireSubmissionMetadata: true,
        sourceAgent: 'Synthetic Windows reveal agent',
        externalChatId: 'synthetic-windows-reveal-chat',
      );
      addTearDown(() async {
        client.close();
        await fixture.dispose();
      });
      const secret = 'Synthetic Windows 原文🧭';
      final saved = await credential(fixture, secret);
      await client.openLifecycleSession('Synthetic Windows reveal chat');
      Future<String> request() async {
        final response = await client.execute({
          'protocolVersion': 2,
          'command': 'request-reveal',
          'credentialId': saved.id,
          'version': saved.version,
          'purpose': 'Synthetic Windows read test',
          'fallbackReason': 'Synthetic unsupported target',
        });
        expect(response['status'], 'pending', reason: '$response');
        expect(jsonEncode(response), isNot(contains(secret)));
        return response['requestId'] as String;
      }

      Future<Map<String, dynamic>> read(String id, String operation) =>
          client.execute({
            'protocolVersion': 2,
            'command': 'read-reveal',
            'requestId': id,
            'operationId': operation,
          });
      Future<void> denied(String id, String operation, String code) async {
        final response = await read(id, operation);
        expect(response['errorCode'], code);
        expect(response.containsKey('secret'), isFalse);
        expect(jsonEncode(response), isNot(contains(secret)));
      }

      final first = await request();
      await denied(first, 'unapproved', 'request_pending');
      await decide(fixture, first, WorkspaceApprovalAction.approve);
      expect((await read(first, 'approved'))['secret'], secret);
      await denied(first, 'approved', 'attempt_consumed');
      await decide(fixture, first, WorkspaceApprovalAction.revoke);
      await denied(first, 'revoked', 'grant_revoked');

      final second = await request();
      await decide(fixture, second, WorkspaceApprovalAction.approve);
      now = now.add(const Duration(minutes: 16));
      await denied(second, 'expired', 'grant_expired');
      expect(
        fixture.repo.credentialUseRequests.expand(
          (request) => request.revealReads,
        ),
        hasLength(1),
      );
      final history = await fixture.owner.request(
        'GET',
        '/v1/owner/credentials/${saved.id}/history',
      );
      expect(jsonEncode(history), isNot(contains(secret)));
      expect(
        jsonEncode(fixture.repo.credentialUseRequests),
        isNot(contains(secret)),
      );
    },
    skip: !Platform.isWindows,
  );
}
