import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

const base = '/credential-use/program';
const password = 'PRIVATE_PROGRAM_PASSWORD_中文😀';
const token = 'PRIVATE_PROGRAM_TOKEN';
const fileBytes = 'PRIVATE_PROGRAM_FILE';
const jobA = r'Local\AgentInfoRuntime-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const jobB = r'Local\AgentInfoRuntime-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

void publicOnly(Object value) {
  final text = jsonEncode(value);
  for (final hidden in [
    password,
    token,
    fileBytes,
    'executionCapability',
    'bytesBase64',
    'materialLease',
    'sessionBinding',
    'workerPid',
    'workerCreatedAt',
    'jobName',
  ]) {
    expect(text, isNot(contains(hidden)));
  }
}

Future<
  ({
    String session,
    String id,
    Map<String, Object?> launch,
    Map<String, Object?> prepared,
  })
>
request(DeviceCredentialFixture f) async {
  final cs = await f.runtime.run(() async {
    final owner = f.runtime.service.owner;
    final values = [
      await owner.createStringCredential(
        name: 'Synthetic DB',
        publicPurpose: '',
        secret: password,
      ),
      await owner.createStringCredential(
        name: 'Synthetic Token',
        publicPurpose: '',
        secret: token,
      ),
      await owner.createFileCredential(
        name: 'Synthetic Key',
        publicPurpose: '',
        fileName: 'client.key',
        bytes: utf8.encode(fileBytes),
      ),
    ];
    return [
      for (final c in values)
        await owner.updateCredentialMetadata(
          c.id,
          c.revision,
          name: c.name,
          publicPurpose: '',
          privateNote: '',
          suggestedBinding: 'TOKEN',
          discoverable: true,
        ),
    ];
  });
  final session =
      (await f.agents.first.call('/session/lifecycle', {
            'chatLabel': 'Synthetic program HTTPS',
          }))['sessionSecret']
          as String;
  final launch = CredentialProgramPlan.fromJson({
    'executable': r'C:\device\business-tool.exe',
    'cwd': r'C:\device\work',
    'argv': [
      'sync',
      {
        'file': {'credentialId': cs.last.id},
      },
    ],
    'env': {
      'DB_PASSWORD': {'credentialId': cs.first.id},
      'SERVICE_TOKEN': {'credentialId': cs[1].id},
    },
  }, allowPortablePaths: true);
  final prepared = {
    'version': 1,
    'planHash': launch.planHash,
    'cwd': launch.cwd,
    'executable': ExecutableIdentity(
      launch.path,
      100,
      1,
      'sha256:${'a' * 64}',
    ).toJson(),
  };
  final submitted = await f.agents.first.call('$base/request', {
    'sessionSecret': session,
    'operationId': 'program-submit',
    'prepared': prepared,
    'input': {
      'purpose': 'Query synthetic deployment',
      'agentName': 'Independent Program Agent',
      'externalChatId': 'synthetic-program-chat',
      'submissionVersion': 1,
      'launch': launch.toJson(),
    },
  });
  expect(submitted['status'], 'pending', reason: '$submitted');
  publicOnly(submitted);
  final id = submitted['requestId'] as String;
  final detail = approvalDetailFromJson(
    await f.owner.request(
      'GET',
      '/v1/owner/approvals/details/${Uri.encodeComponent(id)}',
    ),
  );
  expect(detail.scopes.first.label, contains('受管文件路径'));
  expect(detail.scopes[1].label, contains('环境变量 DB_PASSWORD'));
  final change = WorkspaceApprovalChange(
    operationId: 'program-approved',
    requestId: id,
    reviewToken: detail.reviewToken,
    action: WorkspaceApprovalAction.approve,
    selected: ['b1', 'b2', 'b3'],
  );
  final receipt = approvalReceiptFromJson(
    await f.owner.request(
      'POST',
      '/v1/owner/approvals/decisions',
      approvalChangeToJson(change),
    ),
  );
  expect(receipt.matches(change), true);
  return (
    session: session,
    id: id,
    launch: launch.toJson(),
    prepared: prepared,
  );
}

void main() {
  test(
    'HTTPS program delivery is original-device only, all receivers share one process, and private cleanup survives server restart',
    () async {
      var now = DateTime.utc(2026, 11, 14);
      final f = await DeviceCredentialFixture.create(clock: () => now);
      addTearDown(f.dispose);
      final r = await request(f), b = f.agents.last;
      var a = f.agents.first;
      final begin = <String, dynamic>{
        'sessionSecret': r.session,
        'requestId': r.id,
        'operationId': 'program-start',
        'launch': r.launch,
        'prepared': r.prepared,
        'jobName': jobA,
      };
      final claimed = await a.call('$base/begin', begin);
      expect(claimed['status'], 'ok', reason: '$claimed');
      final material = CredentialProgramMaterial.fromPrivateJson(
        Map<String, dynamic>.from(claimed['material'] as Map),
      );
      expect(material.materials['b1']!.bytes, utf8.encode(fileBytes));
      expect(material.materials['b2']!.stringValue, password);
      expect(material.materials['b3']!.stringValue, token);
      final repeat = await a.call('$base/begin', begin);
      expect(repeat['executionId'], claimed['executionId']);
      expect(repeat.containsKey('material'), false);
      publicOnly(repeat);
      final proof = {
        'executionId': material.executionId,
        'executionCapability': material.executionCapability,
      };
      expect(
        (await b.call('$base/authorize', proof))['status'],
        'unauthorized',
      );
      expect((await b.call('$base/begin', begin))['status'], 'unauthorized');
      expect((await a.call('$base/authorize', proof))['status'], 'ok');
      expect(
        (await a.call('$base/worker/register', {
          ...proof,
          'workerPid': 900,
          'workerCreatedAt': 'synthetic-worker',
        }))['errorCode'],
        'invalid_plan',
      );
      expect(
        (await a.call('$base/materials/register', {
          ...proof,
          'lease': CredentialMaterialLease(
            r'C:\device\private',
            'synthetic-folder',
            {'credential-b1.bin': 'synthetic-file'},
          ).toPrivateJson(),
        }))['status'],
        'ok',
      );
      final worker = {
        ...proof,
        'workerPid': 900,
        'workerCreatedAt': 'synthetic-worker',
      };
      expect((await a.call('$base/worker/register', worker))['status'], 'ok');
      expect((await a.call('$base/worker/register', worker))['status'], 'ok');
      final running = CredentialExecutionReport(
        executionId: material.executionId,
        executionCapability: material.executionCapability,
        state: 'running',
        pid: 901,
        processCreatedAt: 'synthetic-child',
        startedAt: now,
        jobName: jobA,
      );
      final runningResult = await a.call(
        '$base/report',
        running.toPrivateJson(),
      );
      expect(
        runningResult['executionState'],
        'running',
        reason: '$runningResult',
      );
      publicOnly(runningResult);
      await f.reopen();
      a = f.agents.first;
      now = now.add(const Duration(hours: 3));
      final status = await a.call('$base/operation', {
        'sessionSecret': r.session,
        'operationId': 'program-start',
      });
      expect(status['executionState'], 'running');
      publicOnly(status);
      expect(
        (await a.call('$base/cleanup', {
          ...proof,
          'treeEnded': true,
        }))['errorCode'],
        'cleanup_busy',
      );
      final ended = CredentialExecutionReport(
        executionId: material.executionId,
        executionCapability: material.executionCapability,
        state: 'exited',
        pid: 901,
        processCreatedAt: 'synthetic-child',
        startedAt: running.startedAt,
        finishedAt: now,
        exitCode: 0,
        jobName: jobA,
      );
      expect(
        (await a.call('$base/report', ended.toPrivateJson()))['executionState'],
        'exited',
      );
      expect(
        (await a.call('$base/cleanup', {
          ...proof,
          'treeEnded': false,
        }))['errorCode'],
        'cleanup_busy',
      );
      final cleaned = await a.call('$base/cleanup', {
        ...proof,
        'treeEnded': true,
      });
      expect(cleaned['cleanupState'], 'complete');
      publicOnly(cleaned);
      await f.reopen();
      a = f.agents.first;
      expect(
        (await a.call('$base/cleanup', {
          ...proof,
          'treeEnded': true,
        }))['revision'],
        cleaned['revision'],
      );
      final original = await a.call('$base/begin', begin);
      expect(original['executionId'], material.executionId);
      expect(original['executionState'], 'exited');
      expect(original.containsKey('material'), false);
      expect(
        (await a.call('$base/begin', {
          ...begin,
          'operationId': 'expired-new-start',
          'jobName': jobB,
        }))['errorCode'],
        'grant_expired',
      );
      final lookup = await a.call('/operations/show', {
        'sessionSecret': r.session,
        'id': 'program-start',
      });
      expect(lookup['kind'], 'credential-program');
      expect(lookup['state'], 'exited');
      publicOnly(lookup);
      final caps = (await a.call('/capabilities', {}))['capabilities'] as List;
      expect(caps, contains('credential-programs.v3'));
    },
  );

  test(
    'lost material reply and server reopen query the original operation; no retry returns material or renews approval',
    () async {
      var now = DateTime.utc(2026, 11, 14);
      final f = await DeviceCredentialFixture.create(
        clock: () => now,
        loseFirstPath: '/v1/agent$base/begin',
      );
      addTearDown(f.dispose);
      final r = await request(f);
      var a = f.agents.first;
      final before = await a.call('$base/status', {
        'sessionSecret': r.session,
        'requestId': r.id,
      });
      final begin = <String, dynamic>{
        'sessionSecret': r.session,
        'requestId': r.id,
        'operationId': 'lost-program-start',
        'launch': r.launch,
        'prepared': r.prepared,
        'jobName': jobA,
      };
      expect(
        (await a.call('$base/begin', begin))['status'],
        'service_unavailable',
      );
      expect(
        (await a.call('$base/begin', begin)).containsKey('material'),
        false,
      );
      now = now.add(const Duration(seconds: 31));
      await f.reopen();
      a = f.agents.first;
      final original = await a.call('$base/begin', begin);
      expect(original['executionState'], 'unknown');
      expect(original.containsKey('material'), false);
      publicOnly(original);
      final list = await a.call('/operations/list', {
        'sessionSecret': r.session,
      });
      expect(
        (list['records'] as List).where(
          (r) => (r as Map)['kind'] == 'credential-program',
        ),
        hasLength(1),
      );
      final after = await a.call('$base/status', {
        'sessionSecret': r.session,
        'requestId': r.id,
      });
      expect(
        (after['items'] as List).first['expiresAt'],
        (before['items'] as List).first['expiresAt'],
      );
      publicOnly(after);
      final next = await a.call('$base/begin', {
        ...begin,
        'operationId': 'explicit-new-program',
        'jobName': jobB,
      });
      expect(next['material'], isA<Map>());
      expect(next['executionId'], isNot(original['executionId']));
      final bad = await a.call('$base/request', {
        'sessionSecret': r.session,
        'operationId': 'bad-device-override',
        'deviceId': 'forged',
        'prepared': r.prepared,
        'input': {'purpose': 'Bad body', 'launch': r.launch},
      });
      expect(bad['errorCode'], 'unknown_field');
      final seed = await f.runtime.run(
        () => f.runtime.service.owner.createInformation(
          'Synthetic read target',
          '',
          [const FieldInput('Host', '', 'synthetic.invalid')],
        ),
      );
      expect(
        (await a.call('/request', {
          'sessionSecret': r.session,
          'purpose': 'Wrong reuse',
          'protocolVersion': 2,
          'operationId': 'lost-program-start',
          'fields': [
            {'itemId': seed.id, 'fieldId': seed.fields.single.id},
          ],
        }))['status'],
        'operation_conflict',
      );
    },
  );
}
