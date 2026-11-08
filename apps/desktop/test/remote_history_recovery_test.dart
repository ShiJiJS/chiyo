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
}
