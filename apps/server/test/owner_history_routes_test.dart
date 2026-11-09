import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/history_transport.dart';
import 'package:info_workspace/file_transport.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/credential_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'package:info_workspace/workspace_information_codec.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'real owner history preserves exact file versions, lifecycle receipts and directory batches across encrypted restart',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final o = f.runtime.service.owner;
      final directory = await f.runtime.run(
        () => o.createDirectory('Synthetic folder'),
      );
      final definitions =
          (await f.owner.request('GET', '/v1/owner/catalog'))['templates']
              as List;
      final definition = workspaceObject(
        definitions.singleWhere((v) => v['id'] == 'generic'),
      );
      final create = WorkspaceCreate(
        operationId: 'note-create',
        typeId: 'generic',
        name: 'Synthetic note',
        directoryId: directory.id,
        expectedTemplateVersion: definition['templateVersion'] as String,
        expectedTemplateDigest: definition['packageDigest'] as String,
        values: {'body': 'SYNTHETIC_ORIGINAL'},
      );
      await f.owner.save(
        create.operationId,
        WorkspaceInformationCodec().create(create, definition),
      );
      final ordinary = (await f.owner.information()).single;
      final c = await f.runtime.run(
        () => o.createStringCredential(
          name: 'Synthetic credential',
          publicPurpose: '',
          secret: 'SYNTHETIC_PRIVATE_PASSWORD',
        ),
      );
      Future<Map<String, dynamic>> post(
        String path,
        Map<String, Object?> body,
      ) => f.owner.request('POST', path, body);
      Future<WorkspaceFileCandidate> upload(String op, String content) async =>
          fileCandidateFromJson(
            (await post('/v1/owner/files/uploads', {
              'operationId': op,
              'originalName': 'synthetic.md',
              'mediaType': 'text/markdown',
              'bytes': base64Encode(utf8.encode(content)),
            }))['candidate'],
          );
      final uploaded = await upload(
        'file-first',
        '# Original\nSYNTHETIC_FILE_ONE',
      );
      final saved = await post(
        '/v1/owner/files/import',
        fileImportToJson(
          WorkspaceFileImport(
            operationId: 'file-import',
            selectionId: uploaded.selectionId,
            name: 'Synthetic file',
            directoryId: directory.id,
          ),
        ),
      );
      final fileRef = recordRefFromJson(saved['record']);
      final codec = WorkspaceInformationCodec();
      final note = codec.decode(ordinary);
      await f.owner.save(
        'note-relation',
        codec.edit(
          WorkspaceEdit(
            operationId: 'note-relation',
            expectedVersion: ordinary.version,
            record: note.record,
            values: note.values,
            relations: {
              'related': [fileRef],
            },
          ),
          ordinary,
        ),
      );
      final noteComparison = revisionPreviewFromJson(
        await post('/v1/owner/history/preview', {
          'wireVersion': 1,
          'record': recordRefToJson(note.record.ref),
          'revision': 1,
          'expectedVersion': 2,
        }),
      );
      expect(noteComparison.current.relations['related'], [fileRef]);
      expect(noteComparison.archive.detail.relations['related'] ?? [], isEmpty);

      final file = (await f.owner.information()).singleWhere(
        (i) => i.id == fileRef.id,
      );
      final field = core.FieldRef(file.id, file.fields.single.id);
      final chat = await f.agents.first.call('/session/lifecycle', {
        'chatLabel': 'Synthetic file history',
      });
      final requested = await f.agents.first.call('/request', {
        'protocolVersion': 2,
        'sessionSecret': chat['sessionSecret'],
        'purpose': 'Synthetic file version',
        'operationId': 'file-request',
        'fields': [field.toJson()],
      });
      expect(requested['status'], 'pending');
      final request = requested['requestId'] as String;
      final review = approvalDetailFromJson(
        await f.owner.request('GET', '/v1/owner/approvals/details/$request'),
      );
      await post(
        '/v1/owner/approvals/decisions',
        approvalChangeToJson(
          WorkspaceApprovalChange(
            operationId: 'file-approval',
            requestId: request,
            reviewToken: review.reviewToken,
            action: WorkspaceApprovalAction.approve,
            selected: review.scopes.map((s) => s.id),
            fileVersions: {
              for (final s in review.scopes)
                s.id: s.fileVersions.single.ref.version,
            },
          ),
        ),
      );
      final historyId = 'request:$request';
      final grant = grantDetailFromJson(
        await f.owner.request(
          'GET',
          '/v1/owner/grant-history/entries/${Uri.encodeComponent(historyId)}',
        ),
      );
      expect(grant.scopes.single.fileVersion, 1);
      final query = grantResultsFromJson(
        await post(
          '/v1/owner/grant-history/query',
          grantQueryToJson(const WorkspaceGrantQuery()),
        ),
      );
      expect(query.items.any((v) => v.id == historyId), true);
      final second = await upload(
        'file-second',
        '# Updated\nSYNTHETIC_FILE_TWO',
      );
      final current = await f.owner.information();
      final detail = core.informationToJson(
        current.singleWhere((i) => i.id == fileRef.id),
      );
      final key = WorkspaceInformationCodec()
          .decode(current.singleWhere((i) => i.id == fileRef.id))
          .fieldIds
          .keys
          .single;
      expect(detail['version'], 1);
      await post(
        '/v1/owner/files/changes',
        fileChangeToJson(
          WorkspaceFileChange(
            operationId: 'file-replace',
            record: fileRef,
            fieldKey: key,
            expectedRecordVersion: 1,
            expectedFileVersion: 1,
            kind: WorkspaceFileChangeKind.replace,
            selectionId: second.selectionId,
          ),
        ),
      );
      final original = fileOriginalFromJson(
        await post('/v1/owner/grant-history/file', {
          'wireVersion': 1,
          'id': historyId,
          'scopeId': grant.scopes.single.id,
        }),
      );
      expect(utf8.decode(original.bytes), '# Original\nSYNTHETIC_FILE_ONE');
      final archive = historyArchiveFromJson(
        await post('/v1/owner/grant-history/snapshot', {
          'wireVersion': 1,
          'id': historyId,
          'record': recordRefToJson(fileRef),
        }),
      );
      expect(archive.detail.version, 1);
      await expectLater(
        post('/v1/owner/grant-history/file', {
          'wireVersion': 1,
          'id': historyId,
          'scopeId': 'unrelated',
        }),
        throwsA(isA<RemoteFailure>()),
      );
      final revisions = revisionsFromJson(
        await post('/v1/owner/history/revisions', {
          'wireVersion': 1,
          'record': recordRefToJson(fileRef),
        }),
      );
      expect(revisions.map((r) => r.version), contains(1));
      final preview = revisionPreviewFromJson(
        await post('/v1/owner/history/preview', {
          'wireVersion': 1,
          'record': recordRefToJson(fileRef),
          'revision': 1,
          'expectedVersion': 2,
        }),
      );
      final change = WorkspaceRecordChange(
        operationId: 'file-old-revision',
        ref: fileRef,
        expectedVersion: 2,
        action: WorkspaceRecordAction.restoreRevision,
        revisionVersion: 1,
        expectedCatalogVersion: preview.catalogVersion,
      );
      final changed = lifecycleReceiptFromJson(
        await post('/v1/owner/history/changes', recordChangeToJson(change)),
      );
      expect(changed.result.version, 3);
      final fileHistory = fileHistoryFromJson(
        await post('/v1/owner/files/history', {
          'record': recordRefToJson(fileRef),
          'fieldKey': key,
        }),
      );
      expect(fileHistory.current.ref.version, 1);
      expect(fileHistory.versions, hasLength(2));
      // Dedicated credential lifecycle remains the same private-material boundary.
      final credential = credentialDetailFromJson(
        await f.owner.request('GET', '/v1/owner/credentials/${c.id}'),
      );
      final deletion = WorkspaceCredentialChange(
        operationId: 'credential-recycle',
        ref: credential.record.ref,
        expectedRecordVersion: credential.recordVersion,
        expectedMaterialVersion: credential.materialVersion,
        action: WorkspaceCredentialAction.recycle,
      );
      final deleted = credentialReceiptFromJson(
        await post(
          '/v1/owner/credentials/changes',
          credentialLifecycleToJson(deletion),
        ),
      );
      expect(deleted.entryId, isNotNull);
      final recycled = recycledCredentialFromJson(
        await f.owner.request(
          'GET',
          '/v1/owner/credentials/recycled/${Uri.encodeComponent(deleted.entryId!)}',
        ),
      );
      expect(recycled.restored.enabled, false);
      expect(
        jsonEncode(recycledCredentialToJson(recycled)),
        isNot(contains('SYNTHETIC_PRIVATE_PASSWORD')),
      );
      await post(
        '/v1/owner/credentials/changes',
        credentialLifecycleToJson(
          WorkspaceCredentialChange(
            operationId: 'credential-restore',
            ref: credential.record.ref,
            expectedRecordVersion: deleted.recordVersion,
            expectedMaterialVersion: deleted.materialVersion,
            action: WorkspaceCredentialAction.restoreRecycled,
            entryId: deleted.entryId,
            expectedCatalogVersion: recycled.catalogVersion,
          ),
        ),
      );
      final selection = WorkspaceLibrarySelection(
        directoryIds: [directory.id],
        records: [credential.record.ref],
      );
      final batchPreview = batchPreviewFromJson(
        await post('/v1/owner/history/batches/preview', {
          'wireVersion': 1,
          'selection': selection.toJson(),
        }),
      );
      expect(batchPreview.informationCount, 2);
      expect(batchPreview.credentialCount, 1);
      final batchCommand = WorkspaceLibraryRecycleCommand(
        operationId: 'whole-batch',
        reviewToken: batchPreview.token,
        selection: selection,
      );
      final receipt = batchReceiptFromJson(
        await post(
          '/v1/owner/history/batches/changes',
          batchChangeToJson(batchCommand),
        ),
      );
      expect(receipt.matches(batchCommand), true);
      var rows = recycledResultsFromJson(
        await post('/v1/owner/history/recycled/query', {
          'wireVersion': 1,
          'keyword': '',
          'offset': 0,
          'limit': 25,
        }),
      );
      expect(rows.rows.single.batch!.id, receipt.batchId);
      await f.reopen();
      expect(
        batchReceiptFromJson(
          await f.owner.request(
            'GET',
            '/v1/owner/history/batches/operations/whole-batch',
          ),
        ).matches(batchCommand),
        true,
      );
      expect(
        (await post(
          '/v1/owner/history/batches/changes',
          batchChangeToJson(batchCommand),
        ))['batchId'],
        receipt.batchId,
      );
      final restoring = batchPreviewFromJson(
        await post('/v1/owner/history/batches/restore-preview', {
          'wireVersion': 1,
          'batchId': receipt.batchId,
          'options': WorkspaceLibraryRestoreOptions().toJson(),
        }),
      );
      expect(restoring.canSave, true);
      await post(
        '/v1/owner/history/batches/changes',
        batchChangeToJson(
          WorkspaceLibraryRecycleCommand(
            operationId: 'whole-restore',
            reviewToken: restoring.token,
            batchId: receipt.batchId,
          ),
        ),
      );
      final fresh = await OwnerClient.connect(
        address: f.owner.address,
        token: f.token,
        trust: f.trust,
      );
      try {
        final items = await fresh.information();
        expect(items.map((i) => i.id), containsAll([ordinary.id, fileRef.id]));
        expect(items.every((i) => i.directoryId == directory.id), true);
        final restoredNote = codec.decode(
          items.singleWhere((i) => i.id == ordinary.id),
        );
        expect(restoredNote.relations['related'], [fileRef]);

        final currentFile = fileOriginalFromJson(
          await fresh.request('POST', '/v1/owner/files/read', {
            'record': recordRefToJson(fileRef),
            'fieldKey': key,
            'version': 1,
          }),
        );
        expect(currentFile.bytes, original.bytes);
        expect(
          credentialDetailFromJson(
            await fresh.request('GET', '/v1/owner/credentials/${c.id}'),
          ).enabled,
          false,
        );
        final oldReceipt = lifecycleReceiptFromJson(
          await fresh.request(
            'GET',
            '/v1/owner/history/operations/file-old-revision',
          ),
        );
        expect(oldReceipt.intent.matches(changed.intent), true);
      } finally {
        fresh.close();
      }
      rows = recycledResultsFromJson(
        await post('/v1/owner/history/recycled/query', {
          'wireVersion': 1,
          'keyword': '',
          'offset': 0,
          'limit': 25,
        }),
      );
      expect(rows.rows, isEmpty);
      final updated = grantDetailFromJson(
        await f.owner.request(
          'GET',
          '/v1/owner/grant-history/entries/${Uri.encodeComponent(historyId)}',
        ),
      );
      expect(updated.scopes.every((s) => !s.active), true);
      // Device identities cannot bypass the Owner gate even by addressing it directly.
      final client = HttpClient(context: f.trust);
      try {
        for (final area in ['history/revisions', 'grant-history/query']) {
          final r = await client.postUrl(
            f.owner.address.resolve('/v1/owner/$area'),
          );
          r.headers.set(
            'authorization',
            'Bearer ${f.profiles.first.deviceToken}',
          );
          r.headers.contentType = ContentType.json;
          r.write('{}');
          final response = await r.close();
          await response.drain<void>();
          expect(response.statusCode, 401);
        }
      } finally {
        client.close(force: true);
      }
    },
  );
  test(
    'stale batches and actual SQL failures never partially recycle or restore',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final o = f.runtime.service.owner;
      final folder = await f.runtime.run(
        () => o.createDirectory('Synthetic atomic folder'),
      );
      final item = await f.runtime.run(
        () => o.createInformation('Synthetic one', '', [
          const core.FieldInput('Body', '', 'SYNTHETIC_ATOMIC'),
        ], directoryId: folder.id),
      );
      Future<Map<String, dynamic>> post(
        String path,
        Map<String, Object?> body,
      ) => f.owner.request('POST', path, body);
      final selection = WorkspaceLibrarySelection(directoryIds: [folder.id]);
      Future<WorkspaceLibraryRecyclePreview> preview() async =>
          batchPreviewFromJson(
            await post('/v1/owner/history/batches/preview', {
              'wireVersion': 1,
              'selection': selection.toJson(),
            }),
          );
      final first = await preview();
      await f.runtime.run(
        () => o.createInformation('Synthetic added after preview', '', [
          const core.FieldInput('Body', '', 'SYNTHETIC_LATER'),
        ], directoryId: folder.id),
      );
      final stale = WorkspaceLibraryRecycleCommand(
        operationId: 'stale-batch',
        reviewToken: first.token,
        selection: selection,
      );
      await expectLater(
        post('/v1/owner/history/batches/changes', batchChangeToJson(stale)),
        throwsA(isA<RemoteFailure>().having((e) => e.code, 'code', 'conflict')),
      );
      expect(f.repo.items, hasLength(2));
      expect(f.repo.directories, hasLength(1));
      final key = await File(
        '${f.root.path}/secrets/database.key',
      ).readAsBytes();
      final db = sqlite3.open('${f.root.path}/data/library.db');
      db.execute(
        'PRAGMA key = "x\'${key.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\'"',
      );
      try {
        final checked = await preview();
        final command = WorkspaceLibraryRecycleCommand(
          operationId: 'atomic-batch',
          reviewToken: checked.token,
          selection: selection,
        );
        db.execute(
          "CREATE TRIGGER synthetic_batch_failure BEFORE INSERT ON library_recycle_operations BEGIN SELECT RAISE(ABORT,'synthetic interruption'); END",
        );
        await expectLater(
          post('/v1/owner/history/batches/changes', batchChangeToJson(command)),
          throwsA(isA<RemoteFailure>()),
        );
        expect(f.repo.items, hasLength(2));
        expect(f.repo.directories, hasLength(1));
        expect(f.repo.libraryRecycleBatches, isEmpty);
        expect(
          db
              .select('SELECT COUNT(*) AS n FROM library_recycle_batches')
              .single['n'],
          0,
        );
        await expectLater(
          f.owner.request(
            'GET',
            '/v1/owner/history/batches/operations/atomic-batch',
          ),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'operation_not_found',
            ),
          ),
        );
        db.execute('DROP TRIGGER synthetic_batch_failure');
        final receipt = batchReceiptFromJson(
          await post(
            '/v1/owner/history/batches/changes',
            batchChangeToJson(command),
          ),
        );
        expect(f.repo.items, isEmpty);
        expect(f.repo.directories, isEmpty);
        final restorePreview = batchPreviewFromJson(
          await post('/v1/owner/history/batches/restore-preview', {
            'wireVersion': 1,
            'batchId': receipt.batchId,
            'options': WorkspaceLibraryRestoreOptions().toJson(),
          }),
        );
        final restore = WorkspaceLibraryRecycleCommand(
          operationId: 'atomic-restore',
          reviewToken: restorePreview.token,
          batchId: receipt.batchId,
        );
        db.execute(
          "CREATE TRIGGER synthetic_restore_failure BEFORE INSERT ON library_recycle_operations BEGIN SELECT RAISE(ABORT,'synthetic interruption'); END",
        );
        await expectLater(
          post('/v1/owner/history/batches/changes', batchChangeToJson(restore)),
          throwsA(isA<RemoteFailure>()),
        );
        expect(f.repo.items, isEmpty);
        expect(f.repo.directories, isEmpty);
        expect(f.repo.libraryRecycleBatches, hasLength(1));
        db.execute('DROP TRIGGER synthetic_restore_failure');
        await post(
          '/v1/owner/history/batches/changes',
          batchChangeToJson(restore),
        );
        expect(f.repo.items.map((i) => i.id), contains(item.id));
        expect(f.repo.items, hasLength(2));
        expect(f.repo.directories, hasLength(1));
      } finally {
        db.close();
      }
      await f.reopen();
      expect(f.repo.items, hasLength(2));
      expect(f.repo.directories, hasLength(1));
      expect(f.runtime.service.owner.libraryRecycleBatches, isEmpty);
    },
  );
}
