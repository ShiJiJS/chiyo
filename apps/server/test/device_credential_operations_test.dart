import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import '../../../packages/info_core/test/fixtures/ssh_session_fixture.dart'
    show knownHostBytes;
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'lost first material response remains consumed through restart and never reissues bytes',
    () async {
      final f = await DeviceCredentialFixture.create(loseFirstClaim: true);
      addTearDown(f.dispose);
      final body = await f.tokenOperation();
      final lost = await f.agents.first.call(
        '/credential-use/device/operation',
        body,
      );
      expect(lost['status'], 'service_unavailable');
      expect(f.repo.credentialExecutions, hasLength(1));
      final id = f.repo.credentialExecutions.single.id;
      expect(f.repo.credentialExecutions.single.processStarted, false);
      await f.reopen();
      final status = Map<String, dynamic>.from(body)
        ..remove('deviceLaunch')
        ..remove('deviceJob');
      final queried = await f.agents.first.call(
        '/credential-use/device/operation/status',
        status,
      );
      expect(queried['executionId'], id);
      expect(queried['operationClaimed'], true);
      final replay = await f.agents.first.call(
        '/credential-use/device/operation',
        body,
      );
      expect(replay['newlyClaimed'], false);
      expect(replay.containsKey('material'), false);
      expect(f.repo.credentialExecutions, hasLength(1));
      expect(f.claimPosts, 2);
    },
  );

  test(
    'crash before the private proof checkpoint keeps the original operation unknown, never starts or reissues',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final body = await f.tokenOperation();
      final before = (await f.repo.openServerState()).payload['textRuntime'];
      final first = await f.agents.first.call(
        '/credential-use/device/operation',
        body,
      );
      expect(first['newlyClaimed'], true);
      final port = f.server.port;
      await f.server.close();
      await f.runtime.close();
      final snapshot = await f.repo.openServerState();
      await f.repo.commitServerState(snapshot, {
        ...snapshot.payload,
        'textRuntime': before,
      });
      await f.close();
      await f.open(port);
      f.agents
        ..clear()
        ..addAll(f.profiles.map(AgentConnection.new));
      final replay = await f.agents.first.call(
        '/credential-use/device/operation',
        body,
      );
      expect(replay['newlyClaimed'], false);
      expect(replay.containsKey('material'), false);
      expect((replay['execution'] as Map)['executionState'], 'unknown');
      expect(f.repo.credentialExecutions, hasLength(1));
      expect(f.repo.credentialExecutions.single.processStarted, false);
    },
  );

  for (final file in [false, true]) {
    test(
      '${file ? 'SSH file' : 'Token'} private device operation is issued once and reports synthetic remote facts without server filesystem/process checks',
      () async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        const secret = 'SYNTHETIC_DEVICE_OPERATION_PRIVATE_BYTES';
        final c = await f.runtime.run(() async {
          if (file)
            await f.runtime.service.owner.configureSshKnownHosts(
              'Synthetic trust',
              knownHostBytes(),
            );
          final raw = file
              ? await f.runtime.service.owner.createFileCredential(
                  name: 'Synthetic identity',
                  publicPurpose: '',
                  fileName: 'identity',
                  bytes: utf8.encode(secret),
                )
              : await f.runtime.service.owner.createStringCredential(
                  name: 'Synthetic token',
                  publicPurpose: '',
                  secret: secret,
                );
          return f.runtime.service.owner.updateCredentialMetadata(
            raw.id,
            raw.revision,
            name: raw.name,
            publicPurpose: '',
            privateNote: '',
            suggestedBinding: 'material',
            discoverable: true,
          );
        });
        final chat = await f.agents[0].call('/session/lifecycle', {
          'chatLabel': 'Synthetic operation chat',
        });
        final session = chat['sessionSecret'] as String;
        final launch = <String, dynamic>{
          'receiver': file ? 'ssh_identity' : 'gh_token',
          'executable': file ? '/execution-device/ssh' : '/execution-device/gh',
          'cwd': '/execution-device/work',
          'argv': file
              ? [
                  '-T',
                  '-o',
                  'BatchMode=yes',
                  '-i',
                  {'file': 'material'},
                  '-p',
                  '2222',
                  'developer@test.beichen.example',
                  '/usr/bin/true',
                ]
              : ['api', 'user'],
          'env': file
              ? <String, dynamic>{}
              : {
                  'GH_TOKEN': {'secret': 'material'},
                },
        };
        Map<String, Object?> prepared(CredentialLaunchPlan value) =>
            DeviceCredentialLaunch.fromPrivateJson({
              'version': 1,
              'planHash': value.planHash,
              'cwd': value.cwd,
              'executable': {
                'path': value.path,
                'byteLength': 100,
                'modifiedMicros': 1,
                'sha256': 'sha256:${'a' * 64}',
              },
            }).toPrivateJson();
        final requestInput = <String, dynamic>{
          'protocolVersion': 2,
          'command': 'request-use',
          'purpose': 'Synthetic private operation',
          'credentials': [
            {'alias': 'material', 'credentialId': c.id, 'version': 1},
          ],
          'launch': launch,
        };
        final requested = await f.agents[0]
            .call('/credential-use/device/request', {
              ...requestInput,
              'sessionSecret': session,
              'deviceLaunch': prepared(
                CredentialUseInput.fromJson(requestInput).launch,
              ),
            });
        expect(requested['status'], 'pending');
        final requestId = requested['requestId'] as String;
        final review = approvalDetailFromJson(
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
              operationId: 'approve',
              requestId: requestId,
              reviewToken: review.reviewToken,
              action: WorkspaceApprovalAction.approve,
              selected: review.scopes.map((s) => s.id),
              credentialMinutes: file ? null : 15,
            ),
          ),
        );
        final operation = CredentialOperationInput.fromJson({
          'protocolVersion': 2,
          'command': 'run-use',
          'requestId': requestId,
          'operationId': 'run-once',
          'launch': launch,
        });
        final job = 'macos:AgentInfoRuntime-${'b' * 32}';
        final body = <String, dynamic>{
          ...operation.toJson(),
          'sessionSecret': session,
          'deviceLaunch': prepared(operation.launch),
          'deviceJob': job,
        };
        expect(
          (await f.agents[1].call(
            '/credential-use/device/operation',
            body,
          ))['status'],
          'unauthorized',
        );
        final first = await f.agents[0].call(
          '/credential-use/device/operation',
          body,
        );
        expect(first['status'], 'ok', reason: '${first['errorCode']}');
        final privateClaim = Map<String, dynamic>.from(first)..remove('status');
        final claimed = CredentialOperationClaim.fromPrivateJson(privateClaim);
        expect(claimed.newlyClaimed, true);
        final material = claimed.material!, id = claimed.execution.id;
        final capability = material.executionCapability;
        expect(material.credentialMaterial.bytes, utf8.encode(secret));
        expect(material.materialLease, isNull);
        expect(f.repo.credentialExecutions.single.materialLease, isNull);
        expect(f.repo.credentialExecutions.single.supervisorPid, isNull);
        final duplicate = await f.agents[0].call(
          '/credential-use/device/operation',
          body,
        );
        expect(duplicate['newlyClaimed'], false);
        expect(duplicate.containsKey('material'), false);
        expect((duplicate['execution'] as Map)['executionId'], id);
        final statusBody = <String, dynamic>{
          ...operation.toJson(),
          'sessionSecret': session,
        };
        final originalStatus = await f.agents[0].call(
          '/credential-use/device/operation/status',
          statusBody,
        );
        expect(originalStatus['duplicate'], true);
        expect(jsonEncode(originalStatus), isNot(contains(capability)));
        final altered = await f.agents[0].call(
          '/credential-use/device/operation/status',
          {
            ...statusBody,
            'launch': {
              ...launch,
              'argv': file ? ['changed'] : ['api', 'repos/other'],
            },
          },
        );
        expect(altered['errorCode'], 'operation_conflict');
        final started = DateTime.now().toUtc();
        final running = CredentialExecutionReport(
          executionId: id,
          executionCapability: capability,
          state: 'running',
          pid: 700000001,
          processCreatedAt: 'SYNTHETIC_REMOTE_PROCESS_IDENTITY',
          startedAt: started,
          jobName: job,
        ).toPrivateJson();
        expect(
          (await f.agents[0].call(
            '/credential-use/device/execution/report',
            running,
          ))['errorCode'],
          'invalid_plan',
        );
        final worker = <String, dynamic>{
          'executionId': id,
          'executionCapability': capability,
          'workerPid': 700000002,
          'workerCreatedAt': 'SYNTHETIC_REMOTE_WORKER_IDENTITY',
        };
        expect(
          (await f.agents[1].call(
            '/credential-use/device/worker/register',
            worker,
          ))['status'],
          'unauthorized',
        );
        if (file) {
          expect(
            (await f.agents[0].call(
              '/credential-use/device/worker/register',
              worker,
            ))['errorCode'],
            'invalid_plan',
          );
          final lease = CredentialMaterialLease(
            '/execution-device/info-managed-synthetic',
            'SYNTHETIC_DIRECTORY_IDENTITY',
            {
              for (final name in [
                'credential.bin',
                'ssh-config',
                'known-hosts',
                'global-known-hosts',
              ])
                name: 'SYNTHETIC_FILE_$name',
            },
          );
          final registration = <String, dynamic>{
            'executionId': id,
            'executionCapability': capability,
            'lease': lease.toPrivateJson(),
          };
          expect(
            (await f.agents[0].call(
              '/credential-use/device/materials/register',
              registration,
            ))['status'],
            'ok',
          );
          expect(
            (await f.agents[0].call(
              '/credential-use/device/materials/register',
              registration,
            ))['status'],
            'ok',
          );
          expect(
            (await f.agents[0].call(
              '/credential-use/device/materials/register',
              {
                ...registration,
                'lease': lease.withFiles({
                  ...lease.files,
                  'credential.bin': 'CHANGED_IDENTITY',
                }).toPrivateJson(),
              },
            ))['errorCode'],
            'invalid_reference',
          );
          expect(await Directory(lease.path).exists(), false);
        }
        expect(
          (await f.agents[0].call(
            '/credential-use/device/worker/register',
            worker,
          ))['status'],
          'ok',
        );
        expect(
          (await f.agents[0].call(
            '/credential-use/device/execution/report',
            running,
          ))['executionState'],
          'running',
        );
        expect(
          (await f.agents[0].call(
            '/credential-use/device/execution/report',
            running,
          ))['executionState'],
          'running',
        );
        expect(
          (await f.agents[0].call('/credential-use/device/cleanup/complete', {
            'executionId': id,
            'executionCapability': capability,
            'treeEnded': true,
          }))['errorCode'],
          'cleanup_busy',
        );
        await f.reopen();
        expect(
          (await f.agents[0].call(
            '/credential-use/device/operation/status',
            statusBody,
          ))['executionState'],
          'running',
        );
        final replay = await f.agents[0].call(
          '/credential-use/device/operation',
          body,
        );
        expect(replay['newlyClaimed'], false);
        expect(replay.containsKey('material'), false);
        expect(f.repo.credentialExecutions, hasLength(1));
        final publicReview = await f.owner.request(
          'GET',
          '/v1/owner/approvals/details/$requestId',
        );
        for (final forbidden in [
          secret,
          capability,
          'SYNTHETIC_REMOTE_WORKER_IDENTITY',
          '/execution-device/info-managed-synthetic',
        ]) {
          expect(jsonEncode(publicReview), isNot(contains(forbidden)));
        }
        expect(
          (await f.agents[0].call('/session/end', {
            'endCapability': chat['endCapability'],
          }))['status'],
          'ended',
        );
        expect(
          (await f.agents[0].call(
            '/credential-use/device/operation',
            body,
          ))['status'],
          'unauthorized',
        );
        final exited = CredentialExecutionReport(
          executionId: id,
          executionCapability: capability,
          state: 'exited',
          pid: 700000001,
          processCreatedAt: 'SYNTHETIC_REMOTE_PROCESS_IDENTITY',
          startedAt: started,
          finishedAt: started.add(const Duration(seconds: 1)),
          exitCode: 0,
          jobName: job,
        ).toPrivateJson();
        expect(
          (await f.agents[1].call(
            '/credential-use/device/execution/report',
            exited,
          ))['status'],
          'unauthorized',
        );
        expect(
          (await f.agents[0].call(
            '/credential-use/device/execution/report',
            exited,
          ))['executionState'],
          'exited',
        );
        expect(
          (await f.agents[0].call(
            '/credential-use/device/execution/report',
            exited,
          ))['executionState'],
          'exited',
        );
        expect(
          (await f.agents[0].call('/credential-use/device/cleanup/complete', {
            'executionId': id,
            'executionCapability': capability,
            'treeEnded': false,
          }))['errorCode'],
          'cleanup_busy',
        );
        expect(
          (await f.agents[0].call('/credential-use/device/cleanup/complete', {
            'executionId': id,
            'executionCapability': capability,
            'treeEnded': true,
          }))['cleanupState'],
          file ? 'complete' : 'not_needed',
        );
        expect(
          jsonEncode((await f.repo.openServerState()).payload),
          isNot(contains(secret)),
        );
        await f.reopen();
        expect(
          f.repo.credentialExecutions.single.cleanupState,
          file ? 'complete' : 'not_needed',
        );
        expect(f.repo.credentialExecutions.single.state, 'exited');
        expect(
          (await f.agents[0].call('/credential-use/device/cleanup/complete', {
            'executionId': id,
            'executionCapability': capability,
            'treeEnded': true,
          }))['status'],
          'ok',
        );
      },
    );
  }
}
