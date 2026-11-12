import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  for (final receiver in CredentialLaunchPlan.programReceivers) {
    test(
      'HTTPS owner approval delivers $receiver to native device worker with private cleanup',
      () async {
        final f = await DeviceCredentialFixture.create();
        final root = Directory(await f.root.resolveSymbolicLinks());
        final client = AgentClient.remote(
          f.profiles.first,
          requireSubmissionMetadata: true,
          sourceAgent: 'Synthetic program Agent',
          externalChatId: 'synthetic-program-chat',
          deviceFileStateDirectory: Directory(
            '${root.path}/private/device-files',
          ),
        );
        addTearDown(() async {
          await client.drainCredentialExecutions();
          client.close();
          await f.dispose();
        });
        final c = await f.runtime.run(() async {
          final raw = await f.runtime.service.owner.createStringCredential(
            name: 'Synthetic program',
            publicPurpose: '',
            secret: 'synthetic-remote-program',
          );
          return f.runtime.service.owner.updateCredentialMetadata(
            raw.id,
            raw.revision,
            name: raw.name,
            publicPurpose: '',
            privateNote: '',
            suggestedBinding: '',
            discoverable: true,
          );
        });
        expect(
          (await client.openLifecycleSession(
            'Synthetic program chat',
          ))['status'],
          'ok',
        );
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
        final requested = await client.execute({
          'protocolVersion': 2,
          'command': 'request-use',
          'purpose': 'Synthetic remote program use',
          'credentials': [
            {'alias': 'token', 'credentialId': c.id, 'version': 1},
          ],
          'launch': launch,
        });
        expect(requested['status'], 'pending', reason: '$requested');
        final request = requested['requestId'] as String;
        final detail = approvalDetailFromJson(
          await f.owner.request('GET', '/v1/owner/approvals/details/$request'),
        );
        expect(detail.request.agentClaim, 'Synthetic program Agent');
        await f.owner.request(
          'POST',
          '/v1/owner/approvals/decisions',
          approvalChangeToJson(
            WorkspaceApprovalChange(
              operationId: 'approve-program',
              requestId: request,
              reviewToken: detail.reviewToken,
              action: WorkspaceApprovalAction.approve,
              selected: detail.scopes.map((s) => s.id),
              credentialMinutes: 15,
            ),
          ),
        );
        // The executable snapshot and stdin binding survive encrypted persistence.
        await f.reopen();
        final run = {
          'protocolVersion': 2,
          'command': 'run-use',
          'requestId': request,
          'operationId': 'once',
          'launch': launch,
        };
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
        expect(f.repo.credentialExecutions.single.materialLease, isNull);
        final output = await client.execute({
          'command': 'execution-output',
          'executionId': accepted['executionId'],
        });
        final text = utf8.decode(
          (output['chunks'] as List)
              .expand<int>((c) => base64Decode(c['dataBase64'] as String))
              .toList(),
        );
        expect(text, contains('received:24'));
        expect(text, contains('[REDACTED]'));
        expect(text, isNot(contains('synthetic-remote-program')));
        if (receiver == 'program_file') {
          final path = RegExp(r'material:([^\r\n]+)').firstMatch(text)![1]!;
          expect(await File(path).exists(), isFalse);
        }
        final repeated = await client.execute(run);
        expect(repeated['duplicate'], true);
        expect(f.repo.credentialExecutions, hasLength(1));
        final journal = Directory('${root.path}/private/credential-executions');
        expect(
          await journal.list().where((f) => f.path.endsWith('.json')).toList(),
          isEmpty,
        );
      },
      skip: !Platform.isMacOS && !Platform.isWindows,
    );
  }
}
