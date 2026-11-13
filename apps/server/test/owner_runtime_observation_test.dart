import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/runtime_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';
import '../../../packages/info_core/test_support/operation_history.dart';

void main() {
  test(
    'new program runtime reports cross HTTPS without inspecting device paths and restored history is inactive',
    () async {
      final now = DateTime.utc(2026, 11, 14);
      final f = await DeviceCredentialFixture.create(clock: () => now);
      addTearDown(f.dispose);
      final records = OperationHistoryFixture(f.runtime.service, f.repo, now);
      await f.runtime.run(() => records.open(program: true, programFile: true));
      final launch = records.businessPlan;
      final claim = await f.runtime.run(
        () => f.runtime.service.agent.beginCredentialProgramOperation(
          records.session,
          records.request.deviceId,
          records.request.id,
          launch,
          DeviceCredentialLaunch.fromPrivateJson({
            'version': 1,
            'planHash': launch.planHash,
            'executable': records.plan.identity!.toJson(),
            'cwd': records.plan.cwd,
          }),
          'macos:AgentInfoRuntime-${'R' * 32}',
          operationId: 'https-runtime-program',
        ),
      );
      await f.runtime.run(
        () => f.runtime.service.agent.registerCredentialProgramMaterials(
          records.request.deviceId,
          claim.operation.id,
          claim.material!.executionCapability,
          CredentialMaterialLease(
            '/foreign-device-never-probe/runtime',
            'folder-id',
            {'credential-b1.bin': 'file-id'},
          ),
        ),
      );
      final wire = await f.owner.request('GET', '/v1/owner/runtime');
      expect(wire['wireVersion'], 2);
      final view = serverRuntimeFromJson(wire);
      expect(view.programs.single.holdsMaterial, isTrue);
      expect(view.programs.single.processUnconfirmed, isTrue);
      expect(view.unconfirmedProcesses, 1);
      expect(view.grants, 1);
      for (final private in [
        'NEVER-PAGE-THIS-MATERIAL',
        'executionCapability',
        'materialLease',
        'workerPid',
        'foreign-device-never-probe',
      ]) {
        expect(jsonEncode(wire), isNot(contains(private)));
      }
      expect(
        (await f.owner.request('GET', '/v1/owner/runtime'))['revision'],
        wire['revision'],
      );
      await f.reopen();
      final reopened = serverRuntimeFromJson(
        await f.owner.request('GET', '/v1/owner/runtime'),
      );
      expect(reopened.programs.single.holdsMaterial, isTrue);
      expect(reopened.unconfirmedProcesses, 1);
      final key = await f.runtime.run(() => f.repo.backups.enable());
      final archive = '${f.root.path}/program-runtime.aimbackup';
      await f.runtime.run(() async {
        await f.repo.backups.saveRecoveryKeyTo(
          '${f.root.path}/program-recovery.key',
        );
        await f.runtime.service.owner.exportLibrary(
          () => f.repo.backups.exportTo(archive),
        );
      });
      final target = await DeviceCredentialFixture.create(clock: () => now);
      addTearDown(target.dispose);
      await target.runtime.run(
        () => target.runtime.service.owner.restoreLibrary(
          () => target.repo.backups.restoreFrom(archive, key),
        ),
      );
      final restored = serverRuntimeFromJson(
        await target.owner.request('GET', '/v1/owner/runtime'),
      );
      expect(restored.programs, isEmpty);
      expect(restored.unconfirmedProcesses, 0);
      expect(restored.grants, 0);
      expect(target.repo.credentialProgramOperations.single.archived, isTrue);
    },
  );

  test(
    'server observes synthetic remote file reports without requiring device paths and portable restore keeps history without active reports',
    () async {
      final f = await DeviceCredentialFixture.create();
      var disposed = false;
      addTearDown(() async {
        if (!disposed) await f.dispose();
      });
      final credential = await f.runtime.run(() async {
        final c = await f.runtime.service.owner.createFileCredential(
          name: 'Synthetic remote file',
          publicPurpose: '',
          fileName: 'credentials',
          bytes: utf8.encode(
            '[default]\naws_access_key_id=SYNTHETIC_REMOTE_RUNTIME_CONTENT\naws_secret_access_key=SYNTHETIC_REMOTE_RUNTIME_SECRET\n',
          ),
        );
        return f.runtime.service.owner.updateCredentialMetadata(
          c.id,
          c.revision,
          name: c.name,
          publicPurpose: '',
          privateNote: '',
          suggestedBinding: 'material',
          discoverable: true,
        );
      });
      final chat = await f.agents.first.call('/session/lifecycle', {
        'chatLabel': 'Synthetic remote-only report',
      });
      final command = <String, dynamic>{
        'protocolVersion': 2,
        'command': 'request-use',
        'purpose': 'Synthetic report transport',
        'credentials': [
          {'alias': 'material', 'credentialId': credential.id, 'version': 1},
        ],
        'launch': {
          'receiver': 'aws_shared_credentials',
          'executable': '/synthetic-device-not-server/aws',
          'cwd': '/synthetic-device-not-server/work',
          'argv': ['sts', 'get-caller-identity', '--region', 'us-east-1'],
          'env': {
            'AWS_SHARED_CREDENTIALS_FILE': {'file': 'material'},
          },
        },
      };
      final input = CredentialUseInput.fromJson(command);
      final prepared = DeviceCredentialLaunch.fromPrivateJson({
        'version': 1,
        'planHash': input.launch.planHash,
        'executable': {
          'path': input.launch.path,
          'byteLength': 100,
          'modifiedMicros': 1,
          'sha256': 'sha256:${'a' * 64}',
        },
        'cwd': input.launch.cwd,
      });
      final request = await f.agents.first
          .call('/credential-use/device/request', {
            ...command,
            'sessionSecret': chat['sessionSecret'],
            'deviceLaunch': prepared.toPrivateJson(),
          });
      expect(request['status'], 'pending', reason: jsonEncode(request));
      final id = request['requestId'] as String;
      final detail = approvalDetailFromJson(
        await f.owner.request('GET', '/v1/owner/approvals/details/$id'),
      );
      await f.owner.request(
        'POST',
        '/v1/owner/approvals/decisions',
        approvalChangeToJson(
          WorkspaceApprovalChange(
            operationId: 'approve-runtime-report',
            requestId: id,
            reviewToken: detail.reviewToken,
            action: WorkspaceApprovalAction.approve,
            selected: detail.scopes.map((s) => s.id),
            credentialMinutes: 15,
          ),
        ),
      );
      final raw = await f.agents.first
          .call('/credential-use/device/operation', {
            'protocolVersion': 2,
            'command': 'run-use',
            'requestId': id,
            'operationId': 'report-preparing',
            'sessionSecret': chat['sessionSecret'],
            'launch': input.launch.toJson(),
            'deviceLaunch': prepared.toPrivateJson(),
            'deviceJob': 'macos:AgentInfoRuntime-${'c' * 32}',
          });
      expect(raw['status'], 'ok');
      final claim = CredentialOperationClaim.fromPrivateJson(
        Map<String, dynamic>.from(raw)..remove('status'),
      );
      final observed = serverRuntimeFromJson(
        await f.owner.request('GET', '/v1/owner/runtime'),
      );
      expect(
        observed.materials.single.state,
        WorkspaceExecutionState.preparing,
      );
      expect(observed.unconfirmedProcesses, 1);
      expect(observed.grants, 1);
      expect(await Directory(input.launch.cwd).exists(), isFalse);
      final serialized = jsonEncode(serverRuntimeToJson(observed));
      for (final secret in [
        'SYNTHETIC_REMOTE_RUNTIME_CONTENT',
        claim.material!.executionCapability,
        chat['sessionSecret'],
        chat['endCapability'],
      ]) {
        expect(serialized, isNot(contains(secret)));
      }
      final http = HttpClient(context: f.trust);
      try {
        final req = await http.getUrl(
          f.owner.address.resolve('/v1/owner/runtime'),
        );
        req.headers.set(
          'authorization',
          'Bearer ${f.profiles.first.deviceToken}',
        );
        final response = await req.close();
        expect(response.statusCode, 401);
        await response.drain<void>();
      } finally {
        http.close(force: true);
      }
      final key = await f.runtime.run(() => f.repo.backups.enable());
      final archive = '${f.root.path}/runtime.aimbackup';
      await f.runtime.run(() async {
        await f.repo.backups.saveRecoveryKeyTo('${f.root.path}/recovery.key');
        await f.runtime.service.owner.exportLibrary(
          () => f.repo.backups.exportTo(archive),
        );
      });
      final copy = await Directory.systemTemp.createTemp(
        'runtime-report-backup-',
      );
      addTearDown(() => copy.delete(recursive: true));
      final retained = (await File(
        archive,
      ).copy('${copy.path}/encrypted.aimbackup')).path;
      await f.dispose();
      disposed = true;
      final target = await DeviceCredentialFixture.create();
      addTearDown(target.dispose);
      await target.runtime.run(
        () => target.runtime.service.owner.restoreLibrary(
          () => target.repo.backups.restoreFrom(retained, key),
        ),
      );
      final restored = serverRuntimeFromJson(
        await target.owner.request('GET', '/v1/owner/runtime'),
      );
      expect(restored.materials, isEmpty);
      expect(restored.unconfirmedProcesses, 0);
      expect(restored.grants, 0);
      expect(
        target.runtime.service.owner.credentialExecutions.single.restoredAt,
        isNotNull,
      );
    },
  );

  test(
    'runtime wire rejects private injections, contradictory counts and extra copy fields',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final wire = await f.owner.request('GET', '/v1/owner/runtime');
      expect(serverRuntimeFromJson(wire).materials, isEmpty);
      for (final patch in [
        {...wire, 'pid': 123},
        {...wire, 'sessions': -1},
        {...wire, 'materials': 'not-a-list'},
        {
          ...wire,
          'copies': [
            {
              'id': 'a',
              'requestId': 'r',
              'itemId': 'i',
              'name': 'synthetic',
              'fileVersion': 1,
              'expiresAt': DateTime.now().toUtc().toIso8601String(),
              'state': 'pending',
              'reason': null,
              'path': '/synthetic',
            },
          ],
        },
      ]) {
        expect(() => serverRuntimeFromJson(patch), throwsFormatException);
      }
    },
  );
}
