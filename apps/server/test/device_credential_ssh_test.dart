import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';
import 'support/device_ssh_fixture.dart';

void main() {
  for (final ending in ['revoke', 'chat-end']) {
    test(
      'remote device real SSH survives server reopen; $ending blocks another command',
      () async {
        final ssh = await DeviceSshFixture.start();
        addTearDown(ssh.close);
        final f = await DeviceCredentialFixture.create();
        final root = Directory(await f.root.resolveSymbolicLinks());
        final work = await Directory('${root.path}/device-work').create();
        final client = AgentClient.remote(
          f.profiles.first,
          deviceFileStateDirectory: Directory(
            '${root.path}/device-private/device-files',
          ),
        );
        addTearDown(() async {
          await client.drainCredentialExecutions();
          client.close();
          await f.dispose();
        });
        await f.importHostTrust(await ssh.trust);
        final c = await f.runtime.run(() async {
          final raw = await f.runtime.service.owner.createFileCredential(
            name: 'Synthetic SSH identity',
            publicPurpose: '',
            fileName: 'identity',
            bytes: await ssh.key,
          );
          return f.runtime.service.owner.updateCredentialMetadata(
            raw.id,
            raw.revision,
            name: raw.name,
            publicPurpose: '',
            privateNote: '',
            suggestedBinding: 'identity',
            discoverable: true,
          );
        });
        expect(
          (await client.openLifecycleSession(
            'Synthetic real SSH device',
          ))['status'],
          'ok',
        );
        Map<String, dynamic> launch({bool slow = false}) => {
          'receiver': 'ssh_identity',
          'executable': '/usr/bin/ssh',
          'argv': ssh.argv(slow: slow),
          'cwd': work.path,
          'env': <String, Object?>{},
        };
        final request = await client.execute({
          'command': 'request-use',
          'purpose': 'Synthetic local SSH container only',
          'credentials': [
            {'alias': 'identity', 'credentialId': c.id, 'version': 1},
          ],
          'launch': launch(),
        });
        expect(request['status'], 'pending', reason: jsonEncode(request));
        final requestId = request['requestId'] as String;
        final detail = approvalDetailFromJson(
          await f.owner.request(
            'GET',
            '/v1/owner/approvals/details/$requestId',
          ),
        );
        await f.owner.request(
          'POST',
          '/v1/owner/approvals/decisions',
          approvalChangeToJson(
            WorkspaceApprovalChange(
              operationId: 'approve-ssh',
              requestId: requestId,
              reviewToken: detail.reviewToken,
              action: WorkspaceApprovalAction.approve,
              selected: detail.scopes.map((s) => s.id),
              credentialMinutes: null,
            ),
          ),
        );
        Map<String, dynamic> operation(String id, {bool slow = false}) => {
          'command': 'run-use',
          'requestId': requestId,
          'operationId': id,
          'launch': launch(slow: slow),
        };
        final first = await client.execute(operation('ssh-first'));
        expect(first['status'], 'accepted', reason: jsonEncode(first));
        await client.drainCredentialExecutions();
        final state = await client.execute({
          'command': 'execution-status',
          'executionId': first['executionId'],
        });
        expect(state['executionState'], 'exited', reason: jsonEncode(state));
        expect(state['exitCode'], 0, reason: jsonEncode(state));
        expect(state['cleanupState'], 'complete');
        final output = await client.execute({
          'command': 'execution-output',
          'executionId': first['executionId'],
        });
        expect(
          utf8.decode(
            (output['chunks'] as List)
                .expand<int>((c) => base64Decode(c['dataBase64'] as String))
                .toList(),
          ),
          contains('SYNTHETIC_SSH_OK'),
        );
        await f.reopen();
        final next = await client.execute(operation('ssh-next', slow: true));
        expect(next['status'], 'accepted', reason: jsonEncode(next));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (f.repo.credentialExecutions.last.state != 'running') {
          if (DateTime.now().isAfter(deadline))
            fail('Original SSH did not enter running');
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        if (ending == 'revoke') {
          final current = approvalDetailFromJson(
            await f.owner.request(
              'GET',
              '/v1/owner/approvals/details/$requestId',
            ),
          );
          await f.owner.request(
            'POST',
            '/v1/owner/approvals/decisions',
            approvalChangeToJson(
              WorkspaceApprovalChange(
                operationId: 'revoke-ssh',
                requestId: requestId,
                reviewToken: current.reviewToken,
                action: WorkspaceApprovalAction.revoke,
              ),
            ),
          );
        } else {
          expect(
            (await client.endLifecycleSession(client.endCapability!))['status'],
            'ended',
          );
        }
        final blocked = await client.execute(operation('ssh-not-started'));
        expect(
          blocked['status'],
          isNot('accepted'),
          reason: jsonEncode(blocked),
        );
        await client.drainCredentialExecutions();
        final original = f.repo.credentialExecutions.singleWhere(
          (e) => e.id == next['executionId'],
        );
        expect(original.state, 'exited');
        expect(original.exitCode, 0);
        expect(original.cleanupState, 'complete');
        expect(f.repo.credentialExecutions, hasLength(2));
        expect(
          await Directory(
            '${root.path}/device-private/credential-executions',
          ).list().where((e) => e.path.endsWith('.json')).toList(),
          isEmpty,
        );
      },
      skip: !Platform.isMacOS,
    );
  }
}
