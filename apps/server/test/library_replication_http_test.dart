import 'dart:convert';
import 'dart:io';

import 'package:info_core/info_core.dart';
import 'package:info_core/library_replication.dart';
import 'package:info_remote/library_replication_client.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_server/owner_replication_routes.dart';
import 'package:test/test.dart';

import 'support/device_credential_fixture.dart';
import 'support/owner_reply_proxy.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> bytes) async => key = List.of(bytes);
}

void main() {
  test(
    'old services reject replication and encrypted staging has a bounded lifetime and count',
    () async {
      final old = await DeviceCredentialFixture.create();
      try {
        await expectLater(
          LibraryReplicationClient(old.owner).status(),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'unsupported_sync',
            ),
          ),
        );
      } finally {
        await old.dispose();
      }
      final host = await DeviceCredentialFixture.create(replication: true);
      try {
        final unauthorized = HttpClient(context: host.trust);
        try {
          final request = await unauthorized.getUrl(
            host.owner.address.resolve(LibraryReplicationClient.base),
          );
          request.headers.set(
            'authorization',
            'Bearer ${host.profiles.first.deviceToken}',
          );
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, 401);
        } finally {
          unauthorized.close(force: true);
        }
        final client = LibraryReplicationClient(host.owner);
        final first = await client.prepareExport('capacity-one');
        final second = await client.prepareExport('capacity-two');
        await expectLater(
          client.prepareExport('capacity-three'),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'sync_transfer_capacity',
            ),
          ),
        );
        await client.release(first);
        final third = await client.prepareExport('capacity-three');
        await client.release(second);
        await client.release(third);
        var elapsed = Duration.zero;
        final folder = await Directory(
          '${host.root.path}/clock-staging',
        ).create();
        final routes = OwnerReplicationRoutes(
          owner: host.runtime.service.owner,
          replication: LibraryReplication(host.repo),
          directory: folder,
          elapsed: () => elapsed,
        );
        try {
          final (_, prepared) = await host.runtime.run(
            () => routes.dispatch(
              'POST',
              ['v1', 'owner', 'replication', 'exports'],
              {'wireVersion': 1, 'operationId': 'expires'},
            ),
          );
          expect(await folder.list().length, 1);
          elapsed = const Duration(minutes: 31);
          final (code, _) = await host.runtime.run(
            () => routes.dispatch(
              'POST',
              [
                'v1',
                'owner',
                'replication',
                'transfers',
                prepared['resourceId'] as String,
                'read',
              ],
              {'wireVersion': 1, 'offset': 0, 'length': 4096},
            ),
          );
          expect(code, 410);
          expect(await folder.list().length, 0);
        } finally {
          await routes.dispose();
        }
      } finally {
        await host.dispose();
      }
    },
  );
  test(
    'real HTTPS export resumes encrypted chunks and installs a separately keyed local library',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final root = await Directory.systemTemp.createTemp('chiyo-local-pull-');
      final target = await EncryptedInformationRepository.open(
        '${root.path}/local',
        _Keys(),
      );
      final local = InformationService(repository: target);
      try {
        await host.runtime.run(() async {
          await host.runtime.service.owner.createInformation('HTTPS 合成资料', '', [
            const FieldInput('正文', '', 'SYNTHETIC_HTTPS_CONTENT'),
          ]);
          await host.runtime.service.owner.createStringCredential(
            name: 'HTTPS 合成密码',
            publicPurpose: '完整传输',
            secret: 'SYNTHETIC_HTTPS_PASSWORD',
          );
          final source = File('${root.path}/原件.bin');
          await source.writeAsBytes(
            List.generate(1024 * 1024 + 37, (n) => n % 251),
          );
          final owner = host.runtime.service.owner;
          final draft = await owner.beginInformationFileDraft();
          try {
            final stage = await owner.stageInformationFile(draft, source.path);
            await owner.commitInformationDraft(
              draft,
              'http-source-file',
              InformationDraftInput(
                name: 'HTTPS 合成文件',
                description: '',
                fields: [InformationDraftField.stagedFile('文件', '', stage.id)],
              ),
            );
          } finally {
            await owner.releaseInformationFileDraft(draft);
          }
        });
        final client = LibraryReplicationClient(host.owner);
        expect((await client.status()).empty, false);
        final prepared = await client.prepareExport('first-pull');
        expect(
          prepared.transfer.byteLength,
          greaterThan(LibraryReplicationClient.chunkBytes),
        );
        final same = await client.prepareExport('first-pull');
        expect(same.resourceId, prepared.resourceId);
        expect(same.transfer.toJson(), prepared.transfer.toJson());
        final output = File('${root.path}/download.encrypted');
        final first = await host.owner.request(
          'POST',
          '${LibraryReplicationClient.base}/transfers/${prepared.resourceId}/read',
          {
            'wireVersion': 1,
            'offset': 0,
            'length': LibraryReplicationClient.chunkBytes,
          },
        );
        await output.writeAsBytes(base64Decode(first['bytesBase64'] as String));
        var chunks = 0;
        await client.download(
          prepared,
          output,
          progress: (n, total) {
            chunks++;
            expect(n, lessThanOrEqualTo(total));
          },
        );
        expect(chunks, greaterThan(0));
        final replication = LibraryReplication(target);
        final receipt = await local.owner.restoreLibraryOnce(
          previous: () =>
              replication.receipt('local-install', prepared.transfer),
          restore: () => replication.installInitial(
            path: output.path,
            transferKey: prepared.transferKey,
            operationId: 'local-install',
            transfer: prepared.transfer,
          ),
        );
        expect(target.items, hasLength(2));
        expect(
          utf8.decode(target.credentialMaterials.single.bytes),
          'SYNTHETIC_HTTPS_PASSWORD',
        );
        expect(
          receipt.identity.libraryId,
          (await client.status()).identity.libraryId,
        );
        await client.release(prepared);
        expect(
          (await Directory(
            '${host.root.path}/replication-transfers',
          ).list().toList()),
          isEmpty,
        );
        expect(host.repo.items, hasLength(2));
      } finally {
        await local.close();
        await target.close();
        await host.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'real HTTPS upload resumes chunks and reconciles a lost commit response after server restart',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final root = await Directory.systemTemp.createTemp('chiyo-local-push-');
      final source = await EncryptedInformationRepository.open(
        '${root.path}/local',
        _Keys(),
      );
      final local = InformationService(repository: source);
      final proxy = await OwnerReplyProxy.start(
        tls: host.tls,
        trust: host.trust,
        target: () => host.owner.address,
        serverId: host.owner.serverId,
      );
      final connection = await OwnerClient.connect(
        address: proxy.address,
        token: host.token,
        trust: host.trust,
        expectedServerId: host.owner.serverId,
      );
      try {
        await local.owner.createInformation('本地上传资料', '', [
          const FieldInput('正文', '', 'SYNTHETIC_PUSH_CONTENT'),
        ]);
        await local.owner.createStringCredential(
          name: '本地上传密码',
          publicPurpose: '',
          secret: 'SYNTHETIC_PUSH_PASSWORD',
        );
        final file = File('${root.path}/upload.encrypted');
        final prepared = await local.owner.exportLibrary(
          () => LibraryReplication(source).exportInitial(file.path),
        );
        final client = LibraryReplicationClient(connection);
        final initial = await client.status();
        expect(initial.empty, true);
        final incoming = await connection
            .request('POST', '${LibraryReplicationClient.base}/imports', {
              'wireVersion': 1,
              'operationId': 'first-push',
              'transfer': prepared.transfer.toJson(),
            });
        final resource = incoming['resourceId'] as String;
        final firstLength = (prepared.transfer.byteLength ~/ 2).clamp(
          1,
          LibraryReplicationClient.chunkBytes,
        );
        final handle = await file.open();
        final first = await handle.read(firstLength);
        await handle.close();
        final part = {
          'wireVersion': 1,
          'offset': 0,
          'bytesBase64': base64Encode(first),
        };
        final write =
            '${LibraryReplicationClient.base}/transfers/$resource/write';
        await connection.request('POST', write, part);
        expect(
          (await connection.request('POST', write, part))['offset'],
          firstLength,
        );
        expect(host.repo.items, isEmpty);
        await expectLater(
          connection.request(
            'POST',
            '${LibraryReplicationClient.base}/transfers/$resource/commit',
            {'wireVersion': 1, 'transferKey': prepared.transferKey},
          ),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'sync_integrity_failed',
            ),
          ),
        );
        expect(host.repo.items, isEmpty);
        proxy.dropNextPath =
            '${LibraryReplicationClient.base}/transfers/$resource/commit';
        await expectLater(
          client.upload(
            file: file,
            transfer: prepared.transfer,
            transferKey: prepared.transferKey,
            operationId: 'first-push',
          ),
          throwsA(isA<RemoteFailure>()),
        );
        expect(host.repo.items, hasLength(1));
        expect(
          utf8.decode(host.repo.credentialMaterials.single.bytes),
          'SYNTHETIC_PUSH_PASSWORD',
        );
        final commits = proxy
            .requests['POST ${LibraryReplicationClient.base}/transfers/$resource/commit'];
        await host.reopen();
        final receipt = await client.upload(
          file: file,
          transfer: prepared.transfer,
          transferKey: '',
          operationId: 'first-push',
        );
        expect(receipt.operationId, 'first-push');
        expect(receipt.identity.replicaId, initial.identity.replicaId);
        expect(host.repo.items, hasLength(1));
        expect(
          proxy
              .requests['POST ${LibraryReplicationClient.base}/transfers/$resource/commit'],
          commits,
        );
        final conflicting = LibraryInitialTransfer(
          libraryId: prepared.transfer.libraryId,
          snapshotId: '0' * 64,
          archiveDigest: prepared.transfer.archiveDigest,
          byteLength: prepared.transfer.byteLength,
          contentFormat: prepared.transfer.contentFormat,
        );
        await expectLater(
          client.upload(
            file: file,
            transfer: conflicting,
            transferKey: '',
            operationId: 'first-push',
          ),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'sync_operation_conflict',
            ),
          ),
        );
        expect(
          source.items.single.fields.single.value,
          'SYNTHETIC_PUSH_CONTENT',
        );
        expect(await host.repo.backups.recoveryKey(), isNull);
      } finally {
        connection.close();
        await proxy.close();
        await local.close();
        await source.close();
        await host.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
