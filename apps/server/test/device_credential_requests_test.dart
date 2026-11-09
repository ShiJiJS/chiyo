import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  for (final windows in [false, true]) {
    test(
      '${windows ? 'Windows' : 'POSIX'} device-prepared request uses real owner approval and keeps its original field grant across encrypted restart',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'device-use-request-',
        );
        await initializeServerSecrets('${root.path}/secrets');
        final fixture = await createTlsFixture(root);
        final tls = SecurityContext()
          ..useCertificateChain(fixture.certificate)
          ..usePrivateKey(fixture.privateKey);
        final trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(fixture.ca);
        final token = base64Url
            .encode(
              await File('${root.path}/secrets/owner.token').readAsBytes(),
            )
            .replaceAll('=', '');
        late EncryptedInformationRepository repo;
        late OnlineInformationRuntime runtime;
        late OnlineServer server;
        late OwnerClient owner;
        Future<void> open([int port = 0]) async {
          repo = await EncryptedInformationRepository.openOnline(
            '${root.path}/data',
            MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
          );
          runtime = await OnlineInformationRuntime.open(repository: repo);
          server = await OnlineServer.start(
            runtime: runtime,
            devices: AgentDeviceRegistry(repo),
            tls: tls,
            ownerToken: token,
            serverId: 'synthetic-device-credential-requests',
            port: port,
          );
          owner = await OwnerClient.connect(
            address: Uri.parse('https://127.0.0.1:${server.port}'),
            token: token,
            trust: trust,
          );
        }

        Future<void> close() async {
          owner.close();
          await server.close();
          await runtime.close();
          await repo.close();
        }

        await open();
        addTearDown(() async {
          await close();
          await root.delete(recursive: true);
        });
        final profiles = <AgentConnectionProfile>[];
        for (var i = 0; i < 2; i++) {
          final enrolled = await owner.request('POST', '/v1/owner/devices', {
            'operationId': 'device-$i',
            'name': 'Synthetic device $i',
          });
          profiles.add(
            AgentConnectionProfile(
              address: owner.address,
              deviceToken: enrolled['deviceToken'] as String,
              serverId: owner.serverId,
              certificate: await File(fixture.ca).readAsString(),
            ),
          );
        }
        var agent = AgentConnection(profiles[0]),
            other = AgentConnection(profiles[1]);
        addTearDown(() {
          agent.close();
          other.close();
        });
        final c = await runtime.run(() async {
          final raw = await runtime.service.owner.createStringCredential(
            name: 'Synthetic use token',
            publicPurpose: '',
            secret: 'SYNTHETIC_SERVER_PRIVATE_USE_TOKEN',
          );
          return runtime.service.owner.updateCredentialMetadata(
            raw.id,
            raw.revision,
            name: raw.name,
            publicPurpose: '',
            privateNote: '',
            suggestedBinding: 'GH_TOKEN',
            discoverable: true,
          );
        });
        final item = await runtime.run(
          () => runtime.service.owner.createInformation(
            'Synthetic address',
            '',
            [const FieldInput('Host', '', 'SYNTHETIC_HOST')],
          ),
        );
        final chat = await agent.call('/session/lifecycle', {
          'chatLabel': 'Synthetic device use',
        });
        final session = chat['sessionSecret'] as String;
        final command = <String, dynamic>{
          'protocolVersion': 2,
          'command': 'request-use',
          'purpose': 'Synthetic use request',
          'credentials': [
            {'alias': 'token', 'credentialId': c.id, 'version': 1},
          ],
          'readFields': [FieldRef(item.id, item.fields.single.id).toJson()],
          'launch': {
            'receiver': 'gh_token',
            'executable': windows
                ? r'C:\device-not-server\gh.exe'
                : '/device-not-server/gh',
            'argv': ['api', 'user'],
            'cwd': windows
                ? r'C:\device-not-server\work'
                : '/device-not-server/work',
            'env': {
              'GH_TOKEN': {'secret': 'token'},
            },
          },
        };
        final input = CredentialUseInput.fromJson(
          command,
          allowPortableLaunchPaths: true,
        );
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
        final body = <String, dynamic>{
          ...command,
          'sessionSecret': session,
          'deviceLaunch': prepared.toPrivateJson(),
        };
        expect(
          (await other.call('/credential-use/device/request', body))['status'],
          'unauthorized',
        );
        final requested = await agent.call(
          '/credential-use/device/request',
          body,
        );
        expect(requested['status'], 'pending', reason: jsonEncode(requested));
        final id = requested['requestId'] as String;
        expect(await Directory(input.launch.cwd).exists(), false);
        expect(runtime.service.owner.credentialUseRequests, hasLength(1));
        final forged = await agent.call('/credential-use/device/request', {
          ...body,
          'deviceLaunch': {
            ...prepared.toPrivateJson(),
            'planHash': 'sha256:${'b' * 64}',
          },
        });
        expect(forged['errorCode'], 'invalid_plan', reason: jsonEncode(forged));
        expect(runtime.service.owner.credentialUseRequests, hasLength(1));
        final detail = approvalDetailFromJson(
          await owner.request('GET', '/v1/owner/approvals/details/$id'),
        );
        expect(detail.scopes, hasLength(2));
        await owner.request(
          'POST',
          '/v1/owner/approvals/decisions',
          approvalChangeToJson(
            WorkspaceApprovalChange(
              operationId: 'approve-device-use',
              requestId: id,
              reviewToken: detail.reviewToken,
              action: WorkspaceApprovalAction.approve,
              selected: detail.scopes.map((s) => s.id),
              credentialMinutes: 15,
              fieldMinutes: 30,
            ),
          ),
        );
        final status = await agent.call('/status', {
          'sessionSecret': session,
          'requestId': id,
        });
        expect(
          ((status['decision'] as Map)['credentialUse'] as Map)['state'],
          'available',
        );
        final claimed = await agent.call('/claim', {
          'sessionSecret': session,
          'requestId': id,
        });
        expect(claimed['status'], 'ok', reason: jsonEncode(claimed));
        final read = <String, dynamic>{
          'token': claimed['token'],
          'itemId': item.id,
          'fieldId': item.fields.single.id,
        };
        expect((await other.call('/read', read))['status'], 'unauthorized');
        expect((await agent.call('/read', read))['value'], 'SYNTHETIC_HOST');
        for (final value in [
          requested,
          status,
          claimed,
          await owner.request('GET', '/v1/owner/approvals/details/$id'),
        ]) {
          expect(
            jsonEncode(value),
            isNot(contains('SYNTHETIC_SERVER_PRIVATE_USE_TOKEN')),
          );
        }
        final port = server.port;
        agent.close();
        other.close();
        await close();
        await open(port);
        agent = AgentConnection(profiles[0]);
        other = AgentConnection(profiles[1]);
        final resumed = await agent.call('/status', {
          'sessionSecret': session,
          'requestId': id,
        });
        expect(resumed, status);
        expect(
          await agent.call('/claim', {
            'sessionSecret': session,
            'requestId': id,
          }),
          claimed,
        );
        expect((await agent.call('/read', read))['value'], 'SYNTHETIC_HOST');
        expect(
          (await other.call('/status', {
            'sessionSecret': session,
            'requestId': id,
          }))['status'],
          'unauthorized',
        );
        expect(runtime.service.owner.credentialExecutions, isEmpty);
        final caps = await agent.call('/capabilities', {});
        expect(
          caps['capabilities'],
          containsAll([
            'credential-use-reuse.v1',
            'credential-device-execution.v1',
            'credential-ssh-session-validity.v1',
          ]),
        );
        expect(
          caps['capabilities'],
          isNot(contains('credential-focused-fill.v1')),
        );
        expect(
          (await agent.call('/session/end', {
            'endCapability': chat['endCapability'],
          }))['status'],
          'ended',
        );
        expect((await agent.call('/read', read))['status'], 'unauthorized');
      },
    );
  }
}
