import 'dart:typed_data';
import 'package:info_workspace/file_transport.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:crypto/crypto.dart';
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
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test(
    'HTTPS device delivery checks scope, exact bytes, confirmation and cleanup through encrypted restart',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-device-delivery-',
      );
      await initializeServerSecrets('${root.path}/secrets');
      final fixture = await createTlsFixture(root);
      final tls = SecurityContext()
        ..useCertificateChain(fixture.certificate)
        ..usePrivateKey(fixture.privateKey);
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(fixture.ca);
      final token = base64Url
          .encode(await File('${root.path}/secrets/owner.token').readAsBytes())
          .replaceAll('=', '');
      final keys = MountedDatabaseKeyStore('${root.path}/secrets/database.key');
      late EncryptedInformationRepository repo;
      late OnlineInformationRuntime runtime;
      late OnlineServer server;
      late OwnerClient owner;
      var now = DateTime.utc(2026, 11, 8);
      Future<void> open({int port = 0}) async {
        repo = await EncryptedInformationRepository.openOnline(
          '${root.path}/data',
          keys,
        );
        runtime = await OnlineInformationRuntime.open(
          repository: repo,
          clock: () => now,
        );
        server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: 'file-proposals-synthetic',
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

      Future<void> reopen() async {
        final port = server.port;
        await close();
        await open(port: port);
      }

      await open();
      addTearDown(() async {
        await close();
        await root.delete(recursive: true);
      });
      Future<AgentConnectionProfile> enroll(String op) async {
        final device = await owner.request('POST', '/v1/owner/devices', {
          'operationId': op,
          'name': op,
        });
        return AgentConnectionProfile(
          address: owner.address,
          deviceToken: device['deviceToken'] as String,
          serverId: owner.serverId,
          certificate: await File(fixture.ca).readAsString(),
        );
      }

      final profile = await enroll('file-enroll');
      var agent = AgentConnection(profile);
      final otherDevice = AgentConnection(await enroll('other-device'));
      addTearDown(() {
        agent.close();
        otherDevice.close();
      });
      final opened = await agent.call('/session/lifecycle', {
        'chatLabel': 'Synthetic file requester',
      });
      final session = opened['sessionSecret'] as String;
      final end = opened['endCapability'] as String;
      Future<Map<String, dynamic>> command(
        String action,
        Map<String, dynamic> values,
      ) => agent.call('/information-file/$action', {
        'protocolVersion': 2,
        'command': 'file-$action',
        'sessionSecret': session,
        ...values,
      }, timeout: const Duration(seconds: 30));
      final caps =
          (await agent.call('/capabilities', {}))['capabilities'] as List;
      expect(
        caps,
        containsAll([
          'information-attachments.v1',
          'information-device-delivery.v1',
          'information-file-cleanup-watch.v1',
        ]),
      );
      final bytes = Uint8List(informationFileByteLimit);
      for (var n = 0; n < bytes.length; n++) {
        bytes[n] = n % 251;
      }
      final uploaded = fileCandidateFromJson(
        (await owner.request('POST', '/v1/owner/files/uploads', {
          'operationId': 'source',
          'originalName': 'synthetic.bin',
          'mediaType': 'application/octet-stream',
          'bytes': base64Encode(bytes),
        }))['candidate'],
      );
      await owner.request(
        'POST',
        '/v1/owner/files/import',
        fileImportToJson(
          WorkspaceFileImport(
            operationId: 'save',
            selectionId: uploaded.selectionId,
            name: 'Synthetic file',
          ),
        ),
      );
      final item = (await owner.information()).single;
      final field = item.fields.single;
      final requested = await agent.call('/request', {
        'protocolVersion': 2,
        'sessionSecret': session,
        'purpose': 'Synthetic file use',
        'operationId': 'request',
        'fields': [FieldRef(item.id, field.id).toJson()],
      });
      expect(requested['status'], 'pending');
      final requestId = requested['requestId'] as String;
      final fetch = {
        'requestId': requestId,
        'itemId': item.id,
        'fieldId': field.id,
        'operationId': 'fetch',
      };
      expect((await command('fetch', fetch))['errorCode'], 'not_authorized');
      final detail = approvalDetailFromJson(
        await owner.request('GET', '/v1/owner/approvals/$requestId'),
      );
      expect(detail.scopes.single.available, true);
      await owner.request(
        'POST',
        '/v1/owner/approvals/decisions',
        approvalChangeToJson(
          WorkspaceApprovalChange(
            operationId: 'approve',
            requestId: requestId,
            reviewToken: detail.reviewToken,
            action: WorkspaceApprovalAction.approve,
            selected: [detail.scopes.single.id],
            fileVersions: {
              detail.scopes.single.id:
                  detail.scopes.single.fileVersions.single.ref.version,
            },
            fieldMinutes: 5,
          ),
        ),
      );
      Map<String, dynamic> delivery(Map<String, dynamic> result) =>
          Map<String, dynamic>.from(result['delivery'] as Map);
      final first = delivery(await command('fetch', fetch));
      final id = first['deliveryId'] as String;
      final cleanup = first['cleanupCapability'] as String;
      Future<Map<String, dynamic>> watch({
        AgentConnection? from,
        String? proof,
        String? target,
        String action = 'watch',
      }) => (from ?? agent).call('/information-file/$action', {
        'protocolVersion': 2,
        'command': 'file-$action',
        'deliveryId': target ?? id,
        'cleanupCapability': proof ?? cleanup,
      });
      expect(first['state'], 'preparing');
      expect(first, isNot(contains('path')));
      expect(first, isNot(contains('bytes')));
      expect(delivery(await command('fetch', fetch)), first);
      final observed = delivery(await watch());
      expect(observed['state'], 'preparing');
      for (final key in [
        'cleanupCapability',
        'path',
        'bytes',
        'fileName',
        'sha256',
      ]) {
        expect(observed, isNot(contains(key)));
      }
      expect((await watch(from: otherDevice))['status'], 'unauthorized');
      expect((await watch(proof: 'A' * 43))['status'], 'unauthorized');
      expect(
        (await watch(target: 'another-delivery'))['status'],
        'unauthorized',
      );
      expect(
        delivery(await command('status', {'deliveryId': id})),
        isNot(contains('cleanupCapability')),
      );
      expect(
        (await agent.call('/information-file/watch', {
          'protocolVersion': 2,
          'command': 'file-watch',
          'deliveryId': id,
          'cleanupCapability': cleanup,
          'sessionSecret': session,
        }))['status'],
        'invalid_request',
      );
      expect(
        (await agent.call('/information-file/download', {
          'protocolVersion': 2,
          'command': 'file-download',
          'deliveryId': id,
          'sessionSecret': cleanup,
        }))['status'],
        'unauthorized',
      );
      final wrongDevice = await otherDevice.call('/information-file/download', {
        'sessionSecret': session,
        'protocolVersion': 2,
        'command': 'file-download',
        'deliveryId': id,
      });
      expect(wrongDevice['status'], 'unauthorized');
      expect(wrongDevice, isNot(contains('bytes')));
      final wrongSession = await agent.call('/session', {
        'chatLabel': 'Another chat',
      });
      final wrong = await agent.call('/information-file/download', {
        'sessionSecret': wrongSession['sessionSecret'],
        'protocolVersion': 2,
        'command': 'file-download',
        'deliveryId': id,
      });
      expect(wrong['status'], 'unauthorized');
      expect(wrong, isNot(contains('bytes')));
      final raw = await command('download', {'deliveryId': id});
      expect(base64Decode(raw['bytes'] as String), bytes);
      expect(delivery(raw)['sha256'], sha256.convert(bytes).toString());
      expect(
        delivery(raw)['state'],
        'preparing',
      ); // Receiving bytes alone is not a verified device result.
      expect(
        (await command('complete', {
          'deliveryId': id,
          'byteLength': bytes.length,
          'sha256': '0' * 64,
        }))['errorCode'],
        'attachment_integrity_failed',
      );
      final done = delivery(
        await command('complete', {
          'deliveryId': id,
          'byteLength': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        }),
      );
      expect(done['state'], 'ready');
      expect(done, isNot(contains('path')));
      agent.close();
      await reopen();
      agent = AgentConnection(profile);
      expect(delivery(await command('fetch', fetch)), done);
      expect(delivery(await watch())['state'], 'ready');
      final privateRecord =
          runtime.service.owner.informationFileDeliveries.single;
      expect(
        jsonEncode(privateRecord.toArchiveJson()),
        isNot(contains(cleanup)),
      );
      expect(jsonEncode(privateRecord.historyJson()), isNot(contains(cleanup)));
      expect(
        base64Decode(
          (await command('download', {'deliveryId': id}))['bytes'] as String,
        ),
        bytes,
      );
      expect(
        runtime.service.owner.informationFileDeliveries.single.lease,
        isNull,
      );
      expect(
        delivery(await command('release', {'deliveryId': id}))['state'],
        'cleanup_pending',
      );
      expect(
        (await command('download', {'deliveryId': id}))['status'],
        'unauthorized',
      );
      expect(
        delivery(await command('cleanup', {'deliveryId': id}))['state'],
        'released',
      );
      expect(
        delivery(await command('cleanup', {'deliveryId': id}))['state'],
        'released',
      );
      final ended = delivery(
        await command('fetch', {...fetch, 'operationId': 'root-ends'}),
      );
      final endedId = ended['deliveryId'] as String;
      final endedCleanup = ended['cleanupCapability'] as String;
      expect((await watch(target: endedId))['status'], 'unauthorized');
      expect(
        (await agent.call('/session/end', {'endCapability': end}))['status'],
        'ended',
      );
      agent.close();
      await reopen();
      agent = AgentConnection(profile);
      expect(
        (await command('download', {'deliveryId': endedId}))['errorCode'],
        'session_ended',
      );
      expect(
        delivery(await watch(target: endedId, proof: endedCleanup))['state'],
        'cleanup_pending',
      );
      expect(
        delivery(
          await watch(target: endedId, proof: endedCleanup, action: 'discard'),
        )['state'],
        'expired',
      );
      expect(
        delivery(
          await watch(target: endedId, proof: endedCleanup, action: 'discard'),
        )['state'],
        'expired',
      );
      expect(
        runtime.service.owner.informationFileDeliveries.every(
          (r) => !r.holdsCopy,
        ),
        true,
      );
      // Internal messages are strict and cannot carry paths or enlarge scope.
      expect(
        (await command('cleanup', {
          'deliveryId': endedId,
          'path': '/not-a-client-path',
        }))['status'],
        'invalid_request',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
