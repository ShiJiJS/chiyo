import 'dart:io';
import 'dart:convert';

import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

import 'storage_test.dart' show TestKeyStore;

sqlite.Database inspect(String root, TestKeyStore keys) {
  final db = sqlite.sqlite3.open('$root/library.db');
  final hex = keys.key!.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  db.execute('PRAGMA key = "x\'$hex\'"');
  return db;
}

void main() {
  for (final background in [false, true]) {
    test(
      'real owner edits are captured durably, reads do not add events (background: $background)',
      () async {
        final root = await Directory.systemTemp.createTemp('sync-journal-');
        final keys = TestKeyStore();
        Future<EncryptedInformationRepository> open() => background
            ? EncryptedInformationRepository.openOnline(root.path, keys)
            : EncryptedInformationRepository.open(root.path, keys);
        var repo = await open();
        var service = InformationService(repository: repo);
        var journal = LibraryChangeJournal(LibraryReplication(repo));
        try {
          await journal.start();
          expect(await journal.after(0), isEmpty);
          final item = await service.owner.createInformation('合成增量资料', '', [
            const FieldInput('正文', '', 'SYNTHETIC_JOURNAL_PRIVATE'),
          ]);
          final first = await journal.after(0);
          expect(first, hasLength(1));
          expect(
            first.single.changes.where(
              (c) => c['table'] == 'information_items',
            ),
            hasLength(1),
          );
          expect(
            first.single.changes.where(
              (c) => c['table'] == 'information_fields',
            ),
            hasLength(1),
          );
          final operation = first.single.operationId;
          await service.owner.correctValue(
            FieldRef(item.id, item.fields.single.id),
            'SYNTHETIC_EDITED',
          );
          final edited = await journal.after(first.single.sequence);
          expect(edited, hasLength(1));
          expect(edited.single.operationId, isNot(operation));
          expect(
            edited.single.changes.any(
              (c) => c['table'] == 'information_revisions',
            ),
            true,
          );
          final observer = inspect(root.path, keys);
          try {
            final version = observer
                .select('PRAGMA data_version')
                .single
                .values
                .single;
            for (var i = 0; i < 8; i++) {
              expect(service.owner.information, hasLength(1));
              expect(await journal.after(edited.single.sequence), isEmpty);
            }
            expect(
              observer.select('PRAGMA data_version').single.values.single,
              version,
            );
          } finally {
            observer.close();
          }
          // Device preferences do not become synchronized content.
          await service.owner.setRequestLifetime(const Duration(hours: 4));
          expect(await journal.after(edited.single.sequence), isEmpty);
          await service.close();
          await repo.close();
          repo = await open();
          service = InformationService(repository: repo);
          journal = LibraryChangeJournal(LibraryReplication(repo));
          // Capture resumes before a caller explicitly reopens the sync controller.
          final before = await journal.after(0);
          expect(before.first.operationId, operation);
          final cursor = before.last.sequence;
          await service.owner.createDirectory('重启后的离线新增');
          final restarted = await journal.after(cursor);
          expect(restarted, hasLength(1));
          expect(
            restarted.single.changes.single['table'],
            'information_directories',
          );
          // Windows holds the empty lock file exclusively while the library is
          // open. Scan the database and journals that actually store content.
          for (final file in root.listSync().whereType<File>().where(
            (file) => !file.path.endsWith('.lock'),
          )) {
            expect(
              String.fromCharCodes(file.readAsBytesSync()),
              isNot(contains('SYNTHETIC_JOURNAL_PRIVATE')),
            );
          }
        } finally {
          await service.close();
          await repo.close();
          await root.delete(recursive: true);
        }
      },
    );
  }

  test(
    'a whole proposal is one commit and a failed journal write rolls back content',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sync-journal-atomic-',
      );
      final keys = TestKeyStore();
      final repo = await EncryptedInformationRepository.open(root.path, keys);
      final service = InformationService(repository: repo);
      final journal = LibraryChangeJournal(LibraryReplication(repo));
      final native = inspect(root.path, keys);
      try {
        await journal.start();
        final session = service.agent.openSession('合成录入');
        final id = await service.agent.submitImport(
          session,
          [
            ImportItemInput('第一条', '', [
              const FieldInput('正文', '', 'SYNTHETIC_FIRST'),
            ]),
            ImportItemInput('第二条', '', [
              const FieldInput('正文', '', 'SYNTHETIC_SECOND'),
            ]),
          ],
          agentName: 'Synthetic Agent',
          title: '两条合成资料',
        );
        final before = await journal.after(0);
        final cursor = before.isEmpty ? 0 : before.last.sequence;
        final proposal = service.owner.importProposals.single;
        native.execute(
          "CREATE TRIGGER fail_sync_log BEFORE INSERT ON library_sync_changes BEGIN SELECT RAISE(ABORT,'synthetic journal failure'); END",
        );
        await expectLater(
          service.owner.confirmImport(id, proposal.version, proposal.items),
          throwsA(isA<StorageFailure>()),
        );
        expect(service.owner.information, isEmpty);
        expect(native.select('SELECT id FROM information_items'), isEmpty);
        expect(await journal.after(cursor), isEmpty);
        native.execute('DROP TRIGGER fail_sync_log');
        await service.owner.confirmImport(id, proposal.version, proposal.items);
        final groups = await journal.after(cursor);
        expect(groups, hasLength(1));
        final rows = groups.single.changes.where(
          (c) => c['table'] == 'information_items',
        );
        expect(rows, hasLength(2));
        expect(service.owner.information, hasLength(2));
        expect(groups.single.toString(), isNot(contains('SYNTHETIC_FIRST')));
        await service.owner.confirmImport(id, proposal.version, proposal.items);
        expect(await journal.after(groups.single.sequence), isEmpty);
      } finally {
        native.close();
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'file capture stores immutable references, not bodies or uncommitted stages',
    () async {
      final root = await Directory.systemTemp.createTemp('sync-journal-file-');
      final keys = TestKeyStore();
      final repo = await EncryptedInformationRepository.open(root.path, keys);
      final service = InformationService(repository: repo);
      final journal = LibraryChangeJournal(LibraryReplication(repo));
      try {
        await journal.start();
        final source = File('${root.path}/source.txt');
        const body = 'SYNTHETIC_ATTACHMENT_BODY_NEVER_PREFETCHED';
        await source.writeAsString(body);
        final draft = await service.owner.beginInformationFileDraft();
        late InformationItem item;
        try {
          final staged = await service.owner.stageInformationFile(
            draft,
            source.path,
          );
          expect(await journal.after(0), isEmpty);
          item = await service.owner.commitInformationDraft(
            draft,
            'file-journal-commit',
            InformationDraftInput(
              name: '合成文件',
              description: '',
              fields: [InformationDraftField.stagedFile('文件', '', staged.id)],
            ),
          );
        } finally {
          await service.owner.releaseInformationFileDraft(draft);
        }
        final groups = await journal.after(0);
        expect(groups, hasLength(1));
        final attachment = groups.single.changes.singleWhere(
          (r) => r['table'] == 'information_attachment_versions',
        );
        expect((attachment['after'] as Map)['body_present'], 1);
        expect((attachment['after'] as Map).containsKey('body'), false);
        expect(jsonEncode(groups.single.changes), isNot(contains(body)));
        expect(
          utf8.decode(
            await repo.readInformationAttachmentChunk(
              item.fields.single.attachment!,
              0,
              body.length,
            ),
          ),
          body,
        );
      } finally {
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'journal schema cannot be hidden behind an older format marker',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sync-journal-format-',
      );
      final keys = TestKeyStore();
      final repo = await EncryptedInformationRepository.open(root.path, keys);
      await LibraryChangeJournal(LibraryReplication(repo)).start();
      await repo.close();
      final native = inspect(root.path, keys);
      try {
        native.execute('UPDATE library_format SET version=56');
        native.execute('PRAGMA user_version=56');
      } finally {
        native.close();
      }
      try {
        await expectLater(
          EncryptedInformationRepository.open(root.path, keys),
          throwsA(
            isA<StorageFailure>().having(
              (e) => e.code,
              'code',
              'unsupported_schema',
            ),
          ),
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'initial copy clears old capture scope and never journals imported rows as local edits',
    () async {
      final root = await Directory.systemTemp.createTemp('sync-journal-copy-');
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        TestKeyStore(),
      );
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        TestKeyStore(),
      );
      final origin = InformationService(repository: source);
      final recipient = InformationService(repository: target);
      final journal = LibraryChangeJournal(LibraryReplication(target));
      try {
        await journal.start();
        await origin.owner.createInformation('首次复制资料', '', [
          const FieldInput('正文', '', 'SYNTHETIC_INITIAL'),
        ]);
        final export = await origin.owner.exportLibrary(
          () => LibraryReplication(
            source,
          ).exportInitial('${root.path}/content.encrypted'),
        );
        await recipient.owner.restoreLibrary(
          () => LibraryReplication(target).installInitial(
            path: '${root.path}/content.encrypted',
            transferKey: export.transferKey,
            operationId: 'copy-after-journal',
            transfer: export.transfer,
          ),
        );
        await expectLater(
          journal.after(0),
          throwsA(
            isA<StorageFailure>().having(
              (e) => e.code,
              'code',
              'sync_base_changed',
            ),
          ),
        );
        await journal.start();
        expect(await journal.after(0), isEmpty);
        expect(target.items.single.name, '首次复制资料');
        await recipient.owner.createInformation('后续本地新增', '', [
          const FieldInput('正文', '', 'SYNTHETIC_LATER'),
        ]);
        expect(await journal.after(0), hasLength(1));
      } finally {
        await origin.close();
        await recipient.close();
        await source.close();
        await target.close();
        await root.delete(recursive: true);
      }
    },
  );
}
