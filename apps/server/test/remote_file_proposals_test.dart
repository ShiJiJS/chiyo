import 'dart:typed_data';
import 'package:info_workspace/file_transport.dart';
import 'package:info_workspace/proposal_transport.dart';
import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test(
    'Agent CLI uploads file versions, owner previews exact proposal originals and saves whole file records',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-file-proposals-',
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
        repo = await EncryptedInformationRepository.open(
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
      final device = await owner.request('POST', '/v1/owner/devices', {
        'operationId': 'file-enroll',
        'name': 'Synthetic file CLI',
      });
      final profile = AgentConnectionProfile(
        address: owner.address,
        deviceToken: device['deviceToken'] as String,
        serverId: owner.serverId,
        certificate: await File(fixture.ca).readAsString(),
      );
      final cli = AgentClient.remote(profile);
      addTearDown(cli.close);
      expect(
        (await cli.openLifecycleSession('Synthetic file import'))['status'],
        'ok',
      );
      Future<Map<String, dynamic>> run(
        String command, [
        Map<String, dynamic> values = const {},
      ]) => cli.execute({'command': command, ...values});
      final capabilities = await run('capabilities');
      expect(
        capabilities['capabilities'],
        contains('information-file-upload.v1'),
      );
      expect(
        capabilities['capabilities'],
        isNot(contains('information-attachments.v1')),
      );
      final first = File('${root.path}/version-one.txt');
      await first.writeAsString('FIRST_SYNTHETIC_FILE');
      final second = File('${root.path}/version-two.bin');
      final large = Uint8List(informationFileByteLimit);
      for (var n = 0; n < large.length; n++) {
        large[n] = n % 251;
      }
      await second.writeAsBytes(large);
      final template =
          (await run('template-read', {'templateId': 'file'}))['template']
              as Map;
      final example = Map<String, dynamic>.from(
        ((template['submissionExample'] as Map)['items'] as List).single as Map,
      );
      final item = <String, dynamic>{
        ...example,
        'key': 'original',
        'name': 'Synthetic versioned file',
        'attachments': [
          {
            'key': 'primary',
            'name': 'Original',
            'templateField': 'file',
            'currentVersion': 2,
            'versions': [
              {'filePath': first.path, 'label': 'First'},
              {'filePath': second.path, 'label': 'Second'},
            ],
          },
        ],
      };
      final submitted = await run('import-submit', {
        'operationId': 'file-proposal-once',
        'items': [item],
      });
      expect(submitted['status'], 'pending');
      final id = submitted['proposalId'] as String;
      expect(
        (await run('import-submit', {
          'operationId': 'file-proposal-once',
          'items': [item],
        }))['proposalId'],
        id,
      );
      final detailJson = await owner.request('GET', '/v1/owner/proposals/$id');
      final detail = proposalDetailFromJson(detailJson);
      expect(detail.items.single.proposed.record.type.id, 'file');
      expect(detail.items.single.attachments.single.versions, hasLength(2));
      expect(jsonEncode(detailJson), isNot(contains(first.path)));
      expect(jsonEncode(detailJson), isNot(contains('FIRST_SYNTHETIC_FILE')));
      expect(await owner.information(), isEmpty);
      Future<WorkspaceFileOriginal> pending(
        int version, {
        int? proposalVersion,
      }) async => fileOriginalFromJson(
        await owner
            .request('POST', '/v1/owner/proposals/$id/originals/pending', {
              'proposalVersion': proposalVersion ?? detail.summary.version,
              'itemId': detail.items.single.id,
              'attachmentKey': 'primary',
              'version': version,
            }),
      );
      expect(utf8.decode((await pending(1)).bytes), 'FIRST_SYNTHETIC_FILE');
      expect((await pending(2)).bytes, large);
      await expectLater(
        pending(1, proposalVersion: detail.summary.version + 1),
        throwsA(isA<RemoteFailure>().having((e) => e.code, 'code', 'conflict')),
      );
      final decision = WorkspaceProposalChange(
        operationId: 'confirm-files',
        proposalId: id,
        version: detail.summary.version,
        reviewToken: detail.reviewToken,
        action: WorkspaceProposalAction.confirm,
        reviewed: detail.items.map(WorkspaceProposalItemReview.fromItem),
      );
      await owner.request(
        'POST',
        '/v1/owner/proposals/decisions',
        proposalChangeToJson(decision),
      );
      final saved = (await owner.information()).single;
      final field = saved.fields.single;
      expect(field.kind, FieldKind.file);
      expect(field.attachment!.attachmentVersion, 2);
      final record = WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        saved.id,
      );
      final original = fileOriginalFromJson(
        await owner.request('POST', '/v1/owner/files/read', {
          'record': recordRefToJson(record),
          'fieldKey': 'file',
          'version': 1,
        }),
      );
      expect(utf8.decode(original.bytes), 'FIRST_SYNTHETIC_FILE');
      await reopen();
      expect(
        (await run('import-status', {
          'operationId': 'file-proposal-once',
        }))['status'],
        'confirmed',
      );
      expect(
        fileHistoryFromJson(
          await owner.request('POST', '/v1/owner/files/history', {
            'record': recordRefToJson(record),
            'fieldKey': 'file',
          }),
        ).versions,
        hasLength(2),
      );
      final third = File('${root.path}/version-three.txt');
      await third.writeAsString('THIRD_SYNTHETIC_FILE');
      final invalid = await run('update-submit', {
        'operationId': 'missing-file-template-value',
        'update': {
          'itemId': saved.id,
          'baseVersion': saved.version,
          'templateId': 'file',
          'templateVersion': template['version'],
          'templateDigest': template['digest'],
          'values': <String, Object?>{},
        },
      });
      expect(invalid['status'], 'validation_failed');
      expect((invalid['fieldErrors'] as Map).containsKey('file'), isTrue);
      expect(jsonEncode(invalid), isNot(contains('FIRST_SYNTHETIC_FILE')));
      final update = await run('update-submit', {
        'operationId': 'file-update-once',
        'update': {
          'itemId': saved.id,
          'baseVersion': saved.version,
          'templateId': 'file',
          'templateVersion': template['version'],
          'templateDigest': template['digest'],
          'values': {'file': 'primary'},
          'attachments': [
            {
              'key': 'primary',
              'name': 'Original',
              'templateField': 'file',
              'fieldId': field.id,
              'currentVersion': 1,
              'versions': [
                {'filePath': third.path},
              ],
            },
          ],
        },
      });
      expect(update['status'], 'pending', reason: jsonEncode(update));
      final updateId = update['proposalId'] as String;
      final updateDetail = proposalDetailFromJson(
        await owner.request('GET', '/v1/owner/proposals/$updateId'),
      );
      final before = fileOriginalFromJson(
        await owner.request(
          'POST',
          '/v1/owner/proposals/$updateId/originals/pending',
          {
            'proposalVersion': updateDetail.summary.version,
            'itemId': saved.id,
            'attachmentKey': 'primary',
            'version': 0,
          },
        ),
      );
      expect(before.bytes, large);
      final after = fileOriginalFromJson(
        await owner.request(
          'POST',
          '/v1/owner/proposals/$updateId/originals/pending',
          {
            'proposalVersion': updateDetail.summary.version,
            'itemId': saved.id,
            'attachmentKey': 'primary',
            'version': 1,
          },
        ),
      );
      expect(utf8.decode(after.bytes), 'THIRD_SYNTHETIC_FILE');
      await owner.request(
        'POST',
        '/v1/owner/proposals/decisions',
        proposalChangeToJson(
          WorkspaceProposalChange(
            operationId: 'confirm-file-update',
            proposalId: updateId,
            version: updateDetail.summary.version,
            reviewToken: updateDetail.reviewToken,
            action: WorkspaceProposalAction.confirm,
            reviewed: updateDetail.items.map(
              WorkspaceProposalItemReview.fromItem,
            ),
          ),
        ),
      );
      final current = (await owner.information()).single;
      expect(current.fields.single.attachment!.attachmentVersion, 3);
      expect(
        fileHistoryFromJson(
          await owner.request('POST', '/v1/owner/files/history', {
            'record': recordRefToJson(record),
            'fieldKey': 'file',
          }),
        ).versions,
        hasLength(3),
      );
      await cli.endLifecycleSession(cli.endCapability!);
      await reopen();
      expect(
        (await run('import-submit', {
          'operationId': 'ended-file-proposal',
          'items': [item],
        }))['status'],
        'unauthorized',
      );
      expect(await owner.information(), hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
