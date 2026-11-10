import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/runtime_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';
import 'support/device_test_receiver.dart';

Future<void> _until(Future<bool> Function() condition) async {
  final until = DateTime.now().add(const Duration(seconds: 25));
  while (!await condition()) {
    if (DateTime.now().isAfter(until))
      fail('Original device report did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

void main() {
  test(
    'Owner runtime reads actual device file execution reports without inspecting or cleaning active material; Agent identity cannot read it',
    () async {
      final f = await DeviceCredentialFixture.create();
      final root = Directory(await f.root.resolveSymbolicLinks());
      final work = await Directory('${root.path}/work').create();
      final executable = File('${work.path}/aws');
      await executable.writeAsString(syntheticCredentialReceiver);
      expect(
        (await Process.run('/bin/chmod', ['700', executable.path])).exitCode,
        0,
      );
      final release = File('${work.path}/release'),
          counter = File('${work.path}/counter');
      final client = AgentClient.remote(
        f.profiles.first,
        deviceFileStateDirectory: Directory('${root.path}/cli/device-files'),
      );
      addTearDown(() async {
        await release.writeAsString('release');
        await client.drainCredentialExecutions();
        client.close();
        await f.dispose();
      });
      final credential = await f.runtime.run(() async {
        final c = await f.runtime.service.owner.createFileCredential(
          name: 'Synthetic runtime file',
          publicPurpose: '',
          fileName: 'credentials',
          bytes: utf8.encode(
            '[default]\naws_access_key_id=SYNTHETIC_DEVICE_FILE\naws_secret_access_key=SYNTHETIC_DEVICE_FILE_SECRET\n',
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
      await client.openLifecycleSession('Synthetic runtime metadata');
      final launch = <String, dynamic>{
        'receiver': 'aws_shared_credentials',
        'executable': executable.path,
        'cwd': work.path,
        'argv': [
          'sts',
          'get-caller-identity',
          counter.path,
          release.path,
          '--region',
          'us-east-1',
        ],
        'env': {
          'AWS_SHARED_CREDENTIALS_FILE': {'file': 'material'},
        },
      };
      final requested = await client.execute({
        'command': 'request-use',
        'purpose': 'Synthetic runtime observation',
        'credentials': [
          {'alias': 'material', 'credentialId': credential.id, 'version': 1},
        ],
        'launch': launch,
      });
      expect(requested['status'], 'pending', reason: jsonEncode(requested));
      final id = requested['requestId'] as String;
      final detail = approvalDetailFromJson(
        await f.owner.request('GET', '/v1/owner/approvals/details/$id'),
      );
      await f.owner.request(
        'POST',
        '/v1/owner/approvals/decisions',
        approvalChangeToJson(
          WorkspaceApprovalChange(
            operationId: 'runtime-approve',
            requestId: id,
            reviewToken: detail.reviewToken,
            action: WorkspaceApprovalAction.approve,
            selected: detail.scopes.map((s) => s.id),
            credentialMinutes: 15,
          ),
        ),
      );
      final accepted = await client.execute({
        'command': 'run-use',
        'requestId': id,
        'operationId': 'runtime-running',
        'launch': launch,
      });
      expect(accepted['status'], 'accepted', reason: jsonEncode(accepted));
      await _until(
        () async =>
            await counter.exists() &&
            (await counter.readAsLines()).length == 1 &&
            await File('${counter.path}.material-path').exists(),
      );
      final material = await File(
        '${counter.path}.material-path',
      ).readAsString();
      final active = serverRuntimeFromJson(
        await f.owner.request('GET', '/v1/owner/runtime'),
      );
      expect(active.materials.single.state, WorkspaceExecutionState.running);
      expect(
        active.materials.single.cleanup,
        WorkspaceExecutionCleanup.needsCheck,
      );
      expect(active.unconfirmedProcesses, 1);
      expect(active.sessions, 1);
      for (var i = 0; i < 3; i++)
        await f.owner.request('GET', '/v1/owner/runtime');
      expect(await File(material).exists(), isTrue);
      expect(await counter.readAsLines(), hasLength(1));
      final text = jsonEncode(serverRuntimeToJson(active));
      for (final secret in [
        'SYNTHETIC_DEVICE_FILE_SECRET',
        material,
        client.sessionSecret!,
        f.token,
        f.profiles.first.deviceToken,
      ]) {
        expect(text, isNot(contains(secret)));
      }
      final http = HttpClient(context: f.trust);
      try {
        final request = await http.getUrl(
          f.owner.address.resolve('/v1/owner/runtime'),
        );
        request.headers.set(
          'authorization',
          'Bearer ${f.profiles.first.deviceToken}',
        );
        final response = await request.close();
        expect(response.statusCode, 401);
        await response.drain<void>();
      } finally {
        http.close(force: true);
      }
      await release.writeAsString('release');
      await client.drainCredentialExecutions();
      await _until(
        () async =>
            serverRuntimeFromJson(
              await f.owner.request('GET', '/v1/owner/runtime'),
            ).materials.single.cleanup ==
            WorkspaceExecutionCleanup.complete,
      );
      final done = serverRuntimeFromJson(
        await f.owner.request('GET', '/v1/owner/runtime'),
      );
      expect(done.materials.single.state, WorkspaceExecutionState.exited);
      expect(done.materials.single.exitCode, 0);
      expect(done.unconfirmedProcesses, 0);
      expect(await File(material).exists(), isFalse);
      await f.reopen();
      final reopened = serverRuntimeFromJson(
        await f.owner.request('GET', '/v1/owner/runtime'),
      );
      expect(
        reopened.materials.single.cleanup,
        WorkspaceExecutionCleanup.complete,
      );
      expect(reopened.revision, isNot(done.revision));
    },
  );
}
