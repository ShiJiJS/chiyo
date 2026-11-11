import 'dart:convert';
import 'dart:io';

import 'package:info_core/info_core.dart';
import 'package:info_core/library_sync_changes.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

import 'storage_test.dart' show TestKeyStore;

sqlite.Database inspect(String root, TestKeyStore keys) {
  final db = sqlite.sqlite3.open('$root/library.db');
  db.execute(
    'PRAGMA key = "x\'${keys.key!.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}\'"',
  );
  return db;
}

void main() {
  test(
    'comparison catches up all local changes beyond one journal page',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sync-projection-backlog-',
      );
      final keys = TestKeyStore();
      final repo = await EncryptedInformationRepository.open(root.path, keys);
      final service = InformationService(repository: repo);
      final incremental = LibraryIncremental(LibraryReplication(repo));
      try {
        await service.owner.exportLibrary(incremental.start);
        for (var i = 0; i < 257; i++) {
          await service.owner.createDirectory('合成目录 $i');
        }
        final first = await service.owner.exportLibrary(
          () => incremental.after(0, limit: 256),
        );
        expect(first, hasLength(256));
        final native = inspect(root.path, keys);
        try {
          expect(
            native
                .select('SELECT raw_cursor FROM library_sync_projection')
                .single['raw_cursor'],
            native
                .select('SELECT max(sequence) AS n FROM library_sync_changes')
                .single['n'],
          );
        } finally {
          native.close();
        }
        final last = await service.owner.exportLibrary(
          () => incremental.after(first.last.cursor),
        );
        expect(last, hasLength(1));
      } finally {
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'retention preserves pending original bytes in encrypted staging until transfer',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sync-projection-pinned-',
      );
      var now = DateTime.utc(2026, 1, 1);
      final repo = await EncryptedInformationRepository.open(
        root.path,
        TestKeyStore(),
        clock: () => now,
      );
      final service = InformationService(repository: repo, clock: () => now);
      final incremental = LibraryIncremental(LibraryReplication(repo));
      try {
        await service.owner.exportLibrary(incremental.start);
        Future<InformationItem> file(
          List<int> bytes, [
          InformationItem? old,
        ]) async {
          final input = File('${root.path}/source.bin');
          await input.writeAsBytes(bytes);
          final draft = await service.owner.beginInformationFileDraft();
          try {
            final stage = await service.owner.stageInformationFile(
              draft,
              input.path,
            );
            return await service.owner.commitInformationDraft(
              draft,
              'version-${old?.version ?? 0}',
              InformationDraftInput(
                name: '合成长期传输',
                description: '',
                itemId: old?.id,
                baseVersion: old?.version,
                fields: [
                  InformationDraftField.stagedFile(
                    '原文',
                    '',
                    stage.id,
                    fieldId: old?.fields.single.id,
                  ),
                ],
              ),
            );
          } finally {
            await service.owner.releaseInformationFileDraft(draft);
          }
        }

        final first = await file([1, 2, 3, 4]);
        final original = (await repo.informationAttachmentVersions(
          first.fields.single.attachment!.attachmentId,
        )).single;
        await service.owner.exportLibrary(() => incremental.after(0));
        now = now.add(const Duration(days: 1));
        final second = await file([5, 6], first);
        // Existing policy retains every original of an owned series. Only a
        // deleted series with expired recovery snapshots can purge originals.
        await service.owner.deleteInformation(second.id, second.version);
        now = now.add(const Duration(days: 120));
        await service.owner.purgeRevisions();
        await service.owner.purgeInformationAttachments();
        await expectLater(
          repo.readInformationAttachmentChunk(original.reference, 0, 4),
          throwsA(isA<AccessFailure>()),
        );
        expect(
          await service.owner.exportLibrary(
            () => incremental.readAttachment(original, 0, 4),
          ),
          [1, 2, 3, 4],
        );
        await expectLater(
          service.owner.exportLibrary(
            () => incremental.readAttachment(original, 0, 5),
          ),
          throwsA(isA<StorageFailure>()),
        );
      } finally {
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'feed pages have a byte budget and do not split a large transaction',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sync-projection-budget-',
      );
      final repo = await EncryptedInformationRepository.open(
        root.path,
        TestKeyStore(),
      );
      final service = InformationService(repository: repo);
      final incremental = LibraryIncremental(LibraryReplication(repo));
      try {
        await service.owner.exportLibrary(incremental.start);
        for (final length in [300000, 180000, 180000]) {
          await service.owner.createInformation('合成分页资料', '', [
            FieldInput('正文', '', 'x' * length),
          ]);
        }
        final first = await service.owner.exportLibrary(
          () => incremental.after(0, byteBudget: 262144),
        );
        expect(first, hasLength(1));
        expect(
          jsonEncode(first.single.batch.toJson()).length,
          greaterThan(262144),
        );
        final second = await service.owner.exportLibrary(
          () => incremental.after(first.single.cursor, byteBudget: 262144),
        );
        expect(second, hasLength(1));
        final third = await service.owner.exportLibrary(
          () => incremental.after(second.single.cursor, byteBudget: 262144),
        );
        expect(third, hasLength(1));
        expect(
          await service.owner.exportLibrary(
            () => incremental.after(third.single.cursor),
          ),
          isEmpty,
        );
      } finally {
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'real edits project into stable complete-record batches and read-only polls stay read-only',
    () async {
      final root = await Directory.systemTemp.createTemp('sync-projection-');
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(root.path, keys);
      var service = InformationService(repository: repo);
      var incremental = LibraryIncremental(LibraryReplication(repo));
      try {
        final item = await service.owner.createInformation('初始资料', '', [
          const FieldInput('正文', '', 'SYNTHETIC_BASE'),
        ]);
        await service.owner.exportLibrary(incremental.start);
        expect(
          await service.owner.exportLibrary(() => incremental.after(0)),
          isEmpty,
        );
        await service.owner.correctValue(
          FieldRef(item.id, item.fields.single.id),
          'SYNTHETIC_CHANGED',
        );
        final first = await service.owner.exportLibrary(
          () => incremental.after(0),
        );
        expect(first, hasLength(1));
        final batch = first.single.batch;
        expect(batch.changes, hasLength(1));
        expect(
          batch.changes.single.key,
          LibrarySyncKey(LibrarySyncKind.information, item.id),
        );
        expect(batch.changes.single.baseVersion, isNotNull);
        final tables = batch.changes.single.content!['tables'] as Map;
        expect(tables['information_revisions'], isNotEmpty);
        expect(
          jsonEncode(tables['information_fields']),
          contains('SYNTHETIC_CHANGED'),
        );
        final observer = inspect(root.path, keys);
        try {
          final before = observer
              .select('PRAGMA data_version')
              .single
              .values
              .single;
          for (var i = 0; i < 5; i++) {
            expect(
              await service.owner.exportLibrary(
                () => incremental.after(first.single.cursor),
              ),
              isEmpty,
            );
          }
          expect(
            observer.select('PRAGMA data_version').single.values.single,
            before,
          );
        } finally {
          observer.close();
        }
        await service.close();
        await repo.close();
        repo = await EncryptedInformationRepository.open(root.path, keys);
        service = InformationService(repository: repo);
        incremental = LibraryIncremental(LibraryReplication(repo));
        await service.owner.exportLibrary(incremental.start);
        final reopened = await service.owner.exportLibrary(
          () => incremental.after(0),
        );
        expect(reopened.single.batch.digest, batch.digest);
        expect(reopened.single.batch.operationId, batch.operationId);
        await service.owner.correctValue(
          FieldRef(item.id, item.fields.single.id),
          'SYNTHETIC_LATER',
        );
        final next = await service.owner.exportLibrary(
          () => incremental.after(first.single.cursor),
        );
        expect(
          next.single.batch.changes.single.baseVersion,
          batch.changes.single.version,
        );
      } finally {
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'whole proposal projects once and a projection failure retries the same operation',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sync-projection-proposal-',
      );
      final keys = TestKeyStore();
      final repo = await EncryptedInformationRepository.open(root.path, keys);
      final service = InformationService(repository: repo);
      final incremental = LibraryIncremental(LibraryReplication(repo));
      final native = inspect(root.path, keys);
      try {
        await service.owner.exportLibrary(incremental.start);
        final session = service.agent.openSession('合成提案');
        final id = await service.agent.submitImport(session, [
          ImportItemInput('第一条', '', [
            const FieldInput('正文', '', 'SYNTHETIC_A'),
          ], suggestedDirectory: '合成/应用'),
          ImportItemInput('第二条', '', [
            const FieldInput('正文', '', 'SYNTHETIC_B'),
          ]),
        ], title: '两条合成资料');
        expect(
          await service.owner.exportLibrary(() => incremental.after(0)),
          isEmpty,
        );
        final proposal = service.owner.importProposals.single;
        await service.owner.confirmImport(id, proposal.version, proposal.items);
        native.execute(
          "CREATE TRIGGER fail_projection BEFORE INSERT ON library_sync_feed BEGIN SELECT RAISE(ABORT,'synthetic projection failure'); END",
        );
        await expectLater(
          service.owner.exportLibrary(() => incremental.after(0)),
          throwsA(isA<Exception>()),
        );
        expect(service.owner.information, hasLength(2));
        expect(native.select('SELECT cursor FROM library_sync_feed'), isEmpty);
        native.execute('DROP TRIGGER fail_projection');
        final result = await service.owner.exportLibrary(
          () => incremental.after(0),
        );
        expect(result, hasLength(1));
        expect(
          result.single.batch.changes.where(
            (c) => c.key.kind == LibrarySyncKind.information,
          ),
          hasLength(2),
        );
        expect(
          result.single.batch.changes.where(
            (c) => c.key.kind == LibrarySyncKind.directory,
          ),
          hasLength(2),
        );
        final rawOperation = native
            .select(
              'SELECT operation_id FROM library_sync_changes ORDER BY sequence DESC LIMIT 1',
            )
            .single['operation_id'];
        expect(result.single.batch.operationId, rawOperation);
        expect(
          await service.owner.exportLibrary(
            () => incremental.after(result.single.cursor),
          ),
          isEmpty,
        );
      } finally {
        native.close();
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'deleted directories keep a version tombstone, credentials stay protected metadata',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sync-projection-delete-',
      );
      final keys = TestKeyStore();
      final repo = await EncryptedInformationRepository.open(root.path, keys);
      final service = InformationService(repository: repo);
      final incremental = LibraryIncremental(LibraryReplication(repo));
      final native = inspect(root.path, keys);
      try {
        final folder = await service.owner.createDirectory('空目录');
        await service.owner.exportLibrary(incremental.start);
        await service.owner.deleteDirectory(folder.id, folder.version);
        final removed = await service.owner.exportLibrary(
          () => incremental.after(0),
        );
        final change = removed.single.batch.changes.single;
        expect(change.key.kind, LibrarySyncKind.directory);
        expect(change.deleted, true);
        final tombstone = native.select(
          'SELECT version,content FROM library_sync_units WHERE kind=? AND id=?',
          ['directory', folder.id],
        ).single;
        expect(tombstone['content'], isNull);
        expect(tombstone['version'], change.version);
        await service.owner.saveCredentialRecord(
          'synthetic-token',
          CredentialRecordInput(
            action: CredentialRecordAction.create,
            commandDigest: 'a' * 64,
            form: CredentialForm.string,
            name: '合成 Token',
            publicPurpose: '合成用途',
            privateNote: '',
            suggestedBinding: 'SYNTHETIC_TOKEN',
            material: utf8.encode('SYNTHETIC_PROTECTED_TOKEN'),
            discoverable: true,
          ),
        );
        final credential = await service.owner.exportLibrary(
          () => incremental.after(removed.single.cursor),
        );
        expect(
          credential.single.batch.changes.single.key.kind,
          LibrarySyncKind.credential,
        );
        expect(
          credential.single.batch.toString(),
          isNot(contains('SYNTHETIC_PROTECTED_TOKEN')),
        );
        expect(
          credential.single.batch.changes.single.toString(),
          isNot(contains('SYNTHETIC_PROTECTED_TOKEN')),
        );
      } finally {
        native.close();
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      }
    },
  );
}
