@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:io';
import 'dart:convert';
import 'package:info_workspace/file_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/library_batch_recycle_controller.dart';
import 'package:info_desktop/workspace/record_mutation.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import '../../server/test/support/device_credential_fixture.dart';
import '../../server/test/support/owner_reply_proxy.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  test(
    'normal remote batch controller preserves its original recycle/restore through reply loss and server restart',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        final proxy = await OwnerReplyProxy.start(
          tls: f.tls,
          trust: f.trust,
          target: () => f.owner.address,
          serverId: f.owner.serverId,
        );
        final client = await OwnerClient.connect(
          address: proxy.address,
          token: f.token,
          trust: f.trust,
        );
        final source = RemoteWorkspaceSource(client);
        LibraryBatchRecycleController? model;
        try {
          final folder = await f.runtime.run(
            () => f.runtime.service.owner.createDirectory(
              'Synthetic controller folder',
            ),
          );
          await f.runtime.run(
            () => f.runtime.service.owner.createInformation(
              'Synthetic row',
              '',
              [const core.FieldInput('Body', '', 'SYNTHETIC_ROW')],
              directoryId: folder.id,
            ),
          );
          String? batch;
          for (final restoring in [false, true]) {
            model = restoring
                ? LibraryBatchRecycleController(source, batchId: batch)
                : LibraryBatchRecycleController(
                    source,
                    selection: WorkspaceLibrarySelection(
                      directoryIds: [folder.id],
                    ),
                  );
            await model.load();
            expect(model.failure, isNull);
            expect(model.canSave, true);
            if (restoring) {
              final member = model.preview!.records.single;
              expect(member.recycleEntryId, isNotNull);
              final archive = await source.readRecycled(member.recycleEntryId!);
              expect(archive.detail.values.values, contains('SYNTHETIC_ROW'));
              expect(archive.directoryName, 'Synthetic controller folder');
            }
            final writes =
                proxy.requests['POST /v1/owner/history/batches/changes'] ?? 0;
            proxy.dropNextPath = '/v1/owner/history/batches/changes';
            await model.save();
            expect(model.uncertain, true);
            expect(model.frozen, true);
            proxy.failGetPrefix = '/v1/owner/history/batches/operations/';
            await model.reconcile();
            expect(model.uncertain, true);
            await model.save();
            expect(
              proxy.requests['POST /v1/owner/history/batches/changes'],
              writes + 1,
            );
            await f.reopen();
            proxy.failGetPrefix = null;
            await model.reconcile();
            expect(model.failure, isNull);
            expect(model.receipt, isNotNull);
            expect(model.receipt!.restoring, restoring);
            batch = model.receipt!.batchId;
            expect(
              proxy.requests['POST /v1/owner/history/batches/changes'],
              writes + 1,
            );
            expect(
              (await source.loadCatalog()).recycledCount,
              restoring ? 0 : 1,
            );
            expect(f.repo.items.length, restoring ? 1 : 0);
            model.dispose();
            model = null;
          }
          expect(f.repo.items.single.fields.single.value, 'SYNTHETIC_ROW');
        } finally {
          model?.dispose();
          await source.dispose();
          client.close();
          await proxy.close();
          await f.dispose();
        }
      }, _RealHttp());
    },
  );
  test(
    'normal record mutation reconciles only the original lifecycle receipt after a lost version restore reply',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        final proxy = await OwnerReplyProxy.start(
          tls: f.tls,
          trust: f.trust,
          target: () => f.owner.address,
          serverId: f.owner.serverId,
        );
        final client = await OwnerClient.connect(
          address: proxy.address,
          token: f.token,
          trust: f.trust,
        );
        final source = RemoteWorkspaceSource(client);
        final mutation = RecordMutation(source);
        try {
          final item = await f.runtime.run(
            () => f.runtime.service.owner.createInformation(
              'Synthetic restore',
              '',
              [const core.FieldInput('Body', '', 'SYNTHETIC_OLD')],
            ),
          );
          await f.runtime.run(
            () => f.runtime.service.owner.correctValue(
              core.FieldRef(item.id, item.fields.single.id),
              'SYNTHETIC_NEW',
            ),
          );
          final ref = WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            item.id,
          );
          final preview = await source.previewRevision(
            ref,
            1,
            expectedVersion: 2,
          );
          final intent = WorkspaceOperationIntent(
            kind: WorkspaceOperationKind.restoreRevision,
            ref: ref,
            expectedVersion: 2,
            revisionVersion: 1,
            expectedCatalogVersion: preview.catalogVersion,
          );
          proxy.dropNextPath = '/v1/owner/history/changes';
          expect(
            await mutation.submit(
              intent,
              (id) => source.changeRecord(
                WorkspaceRecordChange(
                  operationId: id,
                  ref: ref,
                  expectedVersion: 2,
                  action: WorkspaceRecordAction.restoreRevision,
                  revisionVersion: 1,
                  expectedCatalogVersion: preview.catalogVersion,
                ),
              ),
            ),
            isNull,
          );
          expect(mutation.uncertain, true);
          expect(f.repo.items.single.version, 3);
          proxy.failGetPrefix = '/v1/owner/history/operations/';
          await mutation.reconcile();
          expect(mutation.uncertain, true);
          await f.reopen();
          proxy.failGetPrefix = null;
          final receipt = await mutation.reconcile();
          expect(receipt!.version, 3);
          expect(mutation.failure, isNull);
          expect(proxy.requests['POST /v1/owner/history/changes'], 1);
          expect(f.repo.items.single.fields.single.value, 'SYNTHETIC_OLD');
          expect(f.repo.items.single.version, 3);
        } finally {
          mutation.dispose();
          await source.dispose();
          client.close();
          await proxy.close();
          await f.dispose();
        }
      }, _RealHttp());
    },
  );
  test(
    'remote grant file preview renders the approved original after replacement and restart',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        final client = await OwnerClient.connect(
          address: f.owner.address,
          token: f.token,
          trust: f.trust,
        );
        final source = RemoteWorkspaceSource(client);
        try {
          Future<WorkspaceFileCandidate> upload(
            String op,
            String value,
          ) async => fileCandidateFromJson(
            (await f.owner.request('POST', '/v1/owner/files/uploads', {
              'operationId': op,
              'originalName': 'synthetic.txt',
              'mediaType': 'text/plain',
              'bytes': base64Encode(utf8.encode(value)),
            }))['candidate'],
          );
          final first = await upload(
            'preview-original',
            'SYNTHETIC_APPROVED_ORIGINAL',
          );
          final ref = await source.importFile(
            WorkspaceFileImport(
              operationId: 'preview-save',
              selectionId: first.selectionId,
              name: 'Synthetic history file',
            ),
          );
          final item = f.repo.items.single;
          final chat = await f.agents.first.call('/session/lifecycle', {
            'chatLabel': 'Synthetic historical file',
          });
          final requested = await f.agents.first.call('/request', {
            'protocolVersion': 2,
            'sessionSecret': chat['sessionSecret'],
            'operationId': 'preview-request',
            'purpose': 'Synthetic original',
            'fields': [core.FieldRef(item.id, item.fields.single.id).toJson()],
          });
          expect(requested['status'], 'pending');
          final id = requested['requestId'] as String;
          final reviewed = await source.approvals.read(id);
          await source.approvals.change(
            WorkspaceApprovalChange(
              operationId: 'preview-approve',
              requestId: id,
              reviewToken: reviewed.reviewToken,
              action: WorkspaceApprovalAction.approve,
              selected: reviewed.scopes.map((s) => s.id),
              fileVersions: {
                for (final s in reviewed.scopes)
                  s.id: s.fileVersions.single.ref.version,
              },
            ),
          );
          final detail = await source.grantHistory.read('request:$id');
          final key = (await source.readDetail(ref)).fieldIds.keys.single;
          final second = await upload(
            'preview-replaced',
            'SYNTHETIC_CURRENT_DIFFERENT',
          );
          await source.changeFile(
            WorkspaceFileChange(
              operationId: 'preview-change',
              record: ref,
              fieldKey: key,
              expectedRecordVersion: 1,
              expectedFileVersion: 1,
              kind: WorkspaceFileChangeKind.replace,
              selectionId: second.selectionId,
            ),
          );
          await f.reopen();
          final preview = await source.grantHistory.filePreview(
            'request:$id',
            detail.scopes.single.id,
          );
          expect(preview.file.ref.version, 1);
          expect(preview.text, 'SYNTHETIC_APPROVED_ORIGINAL');
          expect(
            (await source.grantHistory.snapshot(
              'request:$id',
              ref,
            )).detail.version,
            1,
          );
          await expectLater(
            source.grantHistory.filePreview('request:$id', 'not-this-scope'),
            throwsA(isA<WorkspaceFailure>()),
          );
          await expectLater(
            source.grantHistory.filePreview(
              'request:$id',
              detail.scopes.single.id,
              page: 1,
            ),
            throwsA(
              isA<WorkspaceFailure>().having(
                (e) => e.code,
                'code',
                'invalid_request',
              ),
            ),
          );
        } finally {
          await source.dispose();
          client.close();
          await f.dispose();
        }
      }, _RealHttp());
    },
  );
  test(
    'recycled attachment preview is pinned, survives restart, restores bytes and rejects missing origins',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        final client = await OwnerClient.connect(
          address: f.owner.address,
          token: f.token,
          trust: f.trust,
        );
        final source = RemoteWorkspaceSource(client);
        var phase = 'create';
        try {
          Future<WorkspaceFileCandidate> upload(
            String id,
            String value,
          ) async => fileCandidateFromJson(
            (await f.owner.request('POST', '/v1/owner/files/uploads', {
              'operationId': id,
              'originalName': 'synthetic-recycle.txt',
              'mediaType': 'text/plain',
              'bytes': base64Encode(utf8.encode(value)),
            }))['candidate'],
          );
          final first = await upload('recycle-original', 'SYNTHETIC_VERSION_1');
          final record = await source.importFile(
            WorkspaceFileImport(
              operationId: 'recycle-create',
              selectionId: first.selectionId,
              name: 'Synthetic retained file',
            ),
          );
          final original = await source.readDetail(record);
          final key = original.fieldIds.keys.single;
          final second = await upload('recycle-next', 'SYNTHETIC_VERSION_2');
          await source.changeFile(
            WorkspaceFileChange(
              operationId: 'recycle-replace',
              record: record,
              fieldKey: key,
              expectedRecordVersion: original.version,
              expectedFileVersion: 1,
              kind: WorkspaceFileChangeKind.replace,
              selectionId: second.selectionId,
            ),
          );
          final current = await source.readDetail(record);
          phase = 'recycle';
          final deletion = await source.changeRecord(
            WorkspaceRecordChange(
              operationId: 'recycle-file',
              ref: record,
              expectedVersion: current.version,
              action: WorkspaceRecordAction.recycle,
            ),
          );
          final entry = (await source.queryRecycled()).items.singleWhere(
            (e) => e.id == deletion.entryId,
          );
          await f.reopen();
          phase = 'read recycled original';
          final preview = await source.readRecycledFilePreview(entry.id, key);
          expect(preview.file.filename, 'synthetic-recycle.txt');
          expect(preview.file.ref.version, 2);
          expect(preview.text, 'SYNTHETIC_VERSION_2');
          await expectLater(
            source.readRecycledFilePreview(entry.id, 'not-this-field'),
            throwsA(isA<WorkspaceFailure>()),
          );
          phase = 'restore';
          await source.changeRecord(
            WorkspaceRecordChange(
              operationId: 'restore-file',
              ref: record,
              expectedVersion: entry.version,
              entryId: entry.id,
              action: WorkspaceRecordAction.restoreRecycled,
              expectedCatalogVersion: (await source.loadCatalog()).version,
            ),
          );
          final restored = await source.readDetail(record);
          expect(
            (await source.readFilePreview(
              record,
              restored.fieldIds.keys.single,
            )).text,
            'SYNTHETIC_VERSION_2',
          );
          await expectLater(
            source.readRecycledFilePreview(entry.id, key),
            throwsA(isA<WorkspaceFailure>()),
          );
          phase = 'whole batch preview and restore';
          final selection = WorkspaceLibrarySelection(records: [record]);
          final scope = await source.previewLibraryRecycle(selection);
          final batch = await source.changeLibraryRecycle(
            WorkspaceLibraryRecycleCommand(
              operationId: 'batch-file-recycle',
              reviewToken: scope.token,
              selection: selection,
            ),
          );
          final options = WorkspaceLibraryRestoreOptions();
          final restoreScope = await source.previewLibraryRecycleRestore(
            batch.batchId,
            options,
          );
          final retained = restoreScope.records.single.recycleEntryId!;
          final archive = await source.readRecycled(retained);
          expect(archive.detail.record.ref, record);
          final batchKey = archive.detail.fieldIds.keys.single;
          expect(
            (await source.readRecycledFilePreview(retained, batchKey)).text,
            'SYNTHETIC_VERSION_2',
          );
          await source.changeLibraryRecycle(
            WorkspaceLibraryRecycleCommand(
              operationId: 'batch-file-restore',
              reviewToken: restoreScope.token,
              batchId: batch.batchId,
              options: options,
            ),
          );
          await expectLater(
            source.readRecycledFilePreview(retained, batchKey),
            throwsA(isA<WorkspaceFailure>()),
          );
          final again = await source.changeRecord(
            WorkspaceRecordChange(
              operationId: 'recycle-again',
              ref: record,
              expectedVersion: (await source.readDetail(record)).version,
              action: WorkspaceRecordAction.recycle,
            ),
          );
          final pending = (await source.queryRecycled()).items.singleWhere(
            (e) => e.id == again.entryId,
          );
          await source.changeRecord(
            WorkspaceRecordChange(
              operationId: 'purge-file',
              ref: record,
              expectedVersion: pending.version,
              entryId: pending.id,
              action: WorkspaceRecordAction.purge,
            ),
          );
          await expectLater(
            source.readRecycledFilePreview(pending.id, key),
            throwsA(isA<WorkspaceFailure>()),
          );
        } on WorkspaceFailure catch (error) {
          fail(
            'Recycled file step $phase failed: ${error.code}: ${error.message}',
          );
        } finally {
          await source.dispose();
          await f.close();
        }
      }, _RealHttp());
    },
  );
}
