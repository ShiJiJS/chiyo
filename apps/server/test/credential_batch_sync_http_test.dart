import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/library_sync_changes.dart';
import 'package:info_remote/library_replication_client.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import '../../../packages/info_core/test_support/operation_history.dart';
import '../../../packages/info_core/test_support/native_fill.dart';
import 'support/device_credential_fixture.dart';
import 'support/owner_reply_proxy.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

void main() {
  for (final nativeKind in [
    null,
    'macos_ax_password',
    'windows_uia_password',
  ]) {
    final contentFormat = nativeKind == null ? 28 : 31;
    test(
      'real TLS copies program history, uploads ${nativeKind ?? 'fill'} history, and refuses unsupported peers before uploading',
      () async {
        final now = DateTime.utc(2026, 11, 14);
        final host = await DeviceCredentialFixture.create(
          replication: true,
          clock: () => now,
        );
        final root = await Directory.systemTemp.createTemp('http-batch-sync-');
        final repo = await EncryptedInformationRepository.open(
          root.path,
          _Keys(),
          clock: () => now,
        );
        final service = InformationService(repository: repo, clock: () => now);
        final local = LibraryIncremental(LibraryReplication(repo));
        final proxy = await OwnerReplyProxy.start(
          tls: host.tls,
          trust: host.trust,
          target: () => host.owner.address,
          serverId: host.owner.serverId,
        );
        final throughProxy = await OwnerClient.connect(
          address: proxy.address,
          token: host.token,
          trust: host.trust,
        );
        addTearDown(() async {
          throughProxy.close();
          await proxy.close();
          await service.close();
          await repo.close();
          await host.close();
          await root.delete(recursive: true);
        });
        final original = OperationHistoryFixture(
          host.runtime.service,
          host.repo,
          now,
        );
        await host.runtime.run(() => original.open(program: true, count: 1));
        final remote = await LibraryIncrementalClient.connect(throughProxy);
        final initial = await remote.prepareInitial('initial-program-history');
        expect(initial.contents.transfer.contentFormat, 29);
        final initialFile = File('${root.path}/initial.encrypted');
        final baseline = await remote.readBaseline(initial);
        await remote.transport.download(initial.contents, initialFile);
        await service.owner.restoreLibrary(
          () => local.installInitialWithBaseline(
            path: initialFile.path,
            transferKey: initial.contents.transferKey,
            operationId: 'initial-program-history',
            transfer: initial.contents.transfer,
            baseline: baseline,
            expectedSourceReplicaId: remote.identity.replicaId,
          ),
        );
        await remote.transport.release(initial.contents);
        await initialFile.delete();
        expect(repo.credentialBatches.single.archived, isTrue);
        expect(repo.credentialProgramOperations, hasLength(1));
        expect(repo.credentialProgramOperations.single.archived, isTrue);

        await host.runtime.run(() => original.append('later-program-use'));
        var cursor = baseline.cursor;
        for (final summary in await remote.changes(cursor)) {
          final exported = await remote.prepareDelta(summary);
          final file = File('${root.path}/download.encrypted');
          expect(exported.transfer.archive.contentFormat, 29);
          await remote.transport.download(exported.contents, file);
          final receipt = await service.owner.exportLibrary(
            () => local.installDelta(
              path: file.path,
              transferKey: exported.contents.transferKey,
              transfer: exported.transfer,
            ),
          );
          expect(receipt.conflict, isFalse);
          await remote.transport.release(exported.contents);
          await file.delete();
          cursor = summary.cursor;
        }
        expect(repo.credentialProgramOperations, hasLength(2));
        final own = OperationHistoryFixture(service, repo, now);
        await own.open(program: false, count: 1);
        if (nativeKind != null) {
          own.input = CredentialBatchInput.fromJson({
            ...own.input.toJson(),
            'items': [
              {
                ...own.input.items.single.toJson(),
                'destination': {
                  'via': 'native',
                  'target': nativeTargetFixture(controlKind: nativeKind),
                },
              },
            ],
          });
          own.request = await service.agent.requestCredentialBatch(
            own.session,
            'A' * 22,
            own.input,
            operationId: 'native-http-submit',
          );
          own.request = await service.owner.decideCredentialBatch(
            own.request.id,
            operationId: 'native-http-approve',
            revision: own.request.revision,
            approvedItems: ['b1'],
          );
          await own.append('native-http-first');
        }
        var testedOldPeer = false;
        var uploadedHistory = false;
        for (final entry in await service.owner.exportLibrary(
          () => local.after(0),
        )) {
          final file = File('${root.path}/upload.encrypted');
          final delta = await service.owner.exportLibrary(
            () => local.exportDelta(
              file.path,
              sourceReplicaId: entry.batch.sourceReplicaId,
              operationId: entry.batch.operationId,
            ),
          );
          if (entry.batch.changes.any(
            (c) =>
                c.key.kind == LibrarySyncKind.history &&
                c.key.id == 'credential-batch:${own.request.id}',
          )) {
            expect(delta.transfer.archive.contentFormat, contentFormat);
            if (!testedOldPeer) {
              proxy.advertisedContentFormats = [
                for (var i = 8; i < contentFormat; i++) i,
              ];
              final posts =
                  proxy.requests['POST /v1/owner/replication/delta-imports'] ??
                  0;
              await expectLater(
                remote.uploadDelta(
                  file: file,
                  transfer: delta.transfer,
                  transferKey: delta.transferKey,
                ),
                throwsA(
                  isA<RemoteFailure>().having(
                    (e) => e.code,
                    'code',
                    'unsupported_sync',
                  ),
                ),
              );
              expect(
                proxy.requests['POST /v1/owner/replication/delta-imports'] ?? 0,
                posts,
              );
              expect(
                host.repo.credentialBatches.any((r) => r.id == own.request.id),
                isFalse,
              );
              proxy.advertisedContentFormats = null;
              testedOldPeer = true;
            }
            uploadedHistory = true;
          }
          final receipt = await remote.uploadDelta(
            file: file,
            transfer: delta.transfer,
            transferKey: delta.transferKey,
          );
          expect(receipt.conflict, isFalse);
          await file.delete();
          // Known receipts do not depend on a still-present archive or on a peer
          // continuing to advertise the original writing capability.
          final gets = proxy.requests['GET /v1/server'] ?? 0;
          proxy.advertisedContentFormats = [26];
          final retry = await remote.uploadDelta(
            file: file,
            transfer: delta.transfer,
            transferKey: delta.transferKey,
          );
          expect(retry.toJson(), receipt.toJson());
          expect(proxy.requests['GET /v1/server'] ?? 0, gets);
          proxy.advertisedContentFormats = null;
        }
        expect(testedOldPeer && uploadedHistory, isTrue);
        expect(
          host.repo.credentialBatches
              .where((r) => r.id == own.request.id)
              .single
              .archived,
          isTrue,
        );
        expect(
          host.repo.credentialBatchOperations.where(
            (o) => o.requestId == own.request.id,
          ),
          hasLength(1),
        );
        expect(
          host.repo.credentialProgramOperations.where(
            (o) => o.requestId == original.request.id,
          ),
          hasLength(2),
        );
        expect(
          host.repo.credentialBatches
              .where((r) => r.id == original.request.id)
              .single
              .archived,
          isFalse,
        );
        expect(
          host.runtime.service.agent.credentialBatchStatus(
            original.session,
            original.request.deviceId,
            original.request.id,
          )['items'],
          everyElement(containsPair('grantState', 'available')),
        );
      },
    );
  }
}
