import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';
import 'backup_setup.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async {
    key = List.of(value);
  }
}

Matcher fails(String value) =>
    throwsA(isA<AccessFailure>().having((e) => e.status, 'status', value));
void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  late DateTime now;
  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'encrypted-attachment-lifecycle-',
    );
    keys = _Keys();
    now = DateTime.utc(2026, 10, 1);
    repo = await EncryptedInformationRepository.open(
      '${root.path}/source',
      keys,
      clock: () => now,
    );
    service = InformationService(repository: repo, clock: () => now);
  });
  tearDown(() async {
    await service.close();
    await repo.close();
    await root.delete(recursive: true);
  });
  sqlite.Database inspect() {
    final db = sqlite.sqlite3.open('${root.path}/source/library.db');
    final hex = keys.key!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  Future<InformationItem> save(
    List<int> bytes, [
    InformationItem? before,
  ]) async {
    final source = File('${root.path}/fictional.pdf');
    await source.writeAsBytes(bytes);
    final draft = await service.owner.beginInformationFileDraft();
    final stage = await service.owner.stageInformationFile(draft, source.path);
    final saved = await service.owner.commitInformationDraft(
      draft,
      'save',
      InformationDraftInput(
        name: '求职资料',
        description: '',
        itemId: before?.id,
        baseVersion: before?.version,
        fields: [
          InformationDraftField.stagedFile(
            '简历',
            '',
            stage.id,
            fieldId: before?.fields.single.id,
          ),
        ],
      ),
    );
    await service.owner.releaseInformationFileDraft(draft);
    return saved;
  }

  test(
    'current and retained originals export exact bytes from a fixed read transaction',
    () async {
      final bytes = List.generate(1024 * 1024 + 17, (n) => n % 256);
      final first = await save(bytes);
      await save([7], first);
      final ref = first.fields.single.attachment!;
      final out = '${root.path}/另存.pdf';
      await service.owner.exportInformationFile(ref, out);
      expect(await File(out).readAsBytes(), bytes);
      await repo.withInformationAttachment(ref, (version, chunks) async {
        final writer = inspect();
        try {
          final mode = writer
              .select('PRAGMA journal_mode')
              .single
              .values
              .single;
          expect(mode, anyOf('wal', 'delete'));
          // Drift reserves the writer at BEGIN; standalone backup readers use
          // a different read-only transaction. Assert the actual failing phase.
          expect(
            () => writer.execute('BEGIN IMMEDIATE'),
            throwsA(
              isA<sqlite.SqliteException>().having(
                (e) => e.resultCode,
                'code',
                5,
              ),
            ),
          );
          expect(writer.autocommit, isTrue);
          print(
            'live attachment snapshot: journal=$mode, independent BEGIN IMMEDIATE=SQLITE_BUSY',
          );
        } finally {
          writer.close();
        }
        final read = <int>[];
        await for (final chunk in chunks) {
          expect(chunk.length, lessThanOrEqualTo(1024 * 1024));
          read.addAll(chunk);
        }
        expect(read, bytes);
        expect(version.reference, ref);
      });
    },
  );

  test(
    'encrypted owner usage includes retained versions and stages until real retention cleanup',
    () async {
      final first = await save([0, 255, 7]);
      final second = await save([1, 2, 3, 4], first);
      final draft = await service.owner.beginInformationFileDraft();
      await service.owner.stageInformationFile(
        draft,
        '${root.path}/fictional.pdf',
      );
      var usage = await service.owner.informationAttachmentUsage();
      expect(usage.availableVersions, 2);
      expect(usage.versionRecords, 2);
      expect(usage.storedBytes, 7);
      expect(usage.stagedFiles, 1);
      expect(usage.originalAndStagedBytes, 11);
      await service.owner.releaseInformationFileDraft(draft);
      await service.owner.deleteInformation(second.id, second.version);
      expect((await service.owner.informationAttachmentUsage()).storedBytes, 7);
      now = now.add(const Duration(days: 31));
      await service.owner.purgeInformationAttachments();
      usage = await service.owner.informationAttachmentUsage();
      expect(usage.availableVersions, 0);
      expect(usage.versionRecords, 2);
      expect(usage.originalAndStagedBytes, 0);
      expect(await File('${root.path}/fictional.pdf').readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
    },
  );
  test(
    'expired original cleanup failure rolls back revision pruning and can retry',
    () async {
      final first = await save([1, 2, 3]);
      final current = await save([7, 8], first);
      final ref = first.fields.single.attachment!;
      now = now.add(const Duration(days: 30));
      var db = inspect();
      db.execute(
        "CREATE TRIGGER fail_purge BEFORE UPDATE ON information_attachment_versions WHEN NEW.body IS NULL BEGIN SELECT RAISE(FAIL,'synthetic purge failed'); END",
      );
      db.close();
      await expectLater(
        service.owner.purgeInformationAttachments(),
        throwsA(isA<StorageFailure>()),
      );
      expect(repo.informationRevisions.length, 1);
      expect(repo.revisionPurgeFacts, isEmpty);
      expect(await repo.readInformationAttachmentChunk(ref, 0, 3), [1, 2, 3]);
      db = inspect();
      try {
        expect(
          db
              .select('SELECT count(*) AS n FROM information_revisions')
              .single['n'],
          1,
        );
        db.execute('DROP TRIGGER fail_purge');
      } finally {
        db.close();
      }
      await service.owner.purgeInformationAttachments();
      expect(repo.informationRevisions, isEmpty);
      await expectLater(
        repo.readInformationAttachmentChunk(ref, 0, 3),
        fails('attachment_missing'),
      );
      final versions = await repo.informationAttachmentVersions(
        ref.attachmentId,
      );
      expect(versions.first.purgedAt, now);
      expect(versions.last.retiredAt, isNull);
      expect(
        await repo.readInformationAttachmentChunk(
          current.fields.single.attachment!,
          0,
          2,
        ),
        [7, 8],
      );
      await service.close();
      await repo.close();
      now = now.subtract(const Duration(days: 2));
      repo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        keys,
        clock: () => now,
      );
      service = InformationService(repository: repo, clock: () => now);
      await expectLater(
        repo.readInformationAttachmentChunk(ref, 0, 3),
        fails('attachment_missing'),
      );
    },
  );
  test(
    'recycle and revision pins are removed before deleting original bytes',
    () async {
      final first = await save([1, 2, 3]);
      final ref = first.fields.single.attachment!;
      final entry = await service.owner.deleteInformation(
        first.id,
        first.version,
      );
      now = now.add(const Duration(days: 29));
      await service.owner.purgeInformationAttachments();
      expect(await repo.readInformationAttachmentChunk(ref, 0, 3), [1, 2, 3]);
      now = now.add(const Duration(days: 1));
      await service.owner.purgeInformationAttachments();
      final db = inspect();
      try {
        expect(
          db
              .select('SELECT body FROM information_attachment_versions')
              .single['body'],
          isNull,
        );
        expect(db.select('SELECT * FROM information_revisions'), isEmpty);
        expect(
          jsonDecode(
            db.select('SELECT payload FROM recycle_entries').single['payload']
                as String,
          )['state'],
          'purged',
        );
      } finally {
        db.close();
      }
      now = now.subtract(const Duration(days: 1));
      await expectLater(
        service.owner.restoreRecycled(entry.id),
        fails('recycle_unavailable'),
      );
      await expectLater(
        service.owner.exportInformationFile(ref, '${root.path}/gone.pdf'),
        fails('attachment_missing'),
      );
    },
  );
  test(
    'delayed restore prunes expired originals from the same backup without reviving them on rollback',
    () async {
      final first = await save([1, 2, 3]);
      final ref = first.fields.single.attachment!;
      await service.owner.deleteInformation(first.id, first.version);
      now = now.add(const Duration(days: 29));
      final key = await enableTestBackups(repo.backups);
      final path = '${root.path}/retained.aimbackup';
      await repo.backups.exportTo(path);
      var targetNow = now;
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
        clock: () => targetNow,
      );
      addTearDown(target.close);
      final preview = await target.backups.inspect(path, key);
      expect(preview.attachmentCount, 1);
      expect(preview.recycleCount, 1);
      targetNow = targetNow.add(const Duration(days: 2));
      final restored = await target.backups.restore(preview);
      expect(restored.attachmentCount, 0);
      expect(restored.recycleCount, 0);
      expect(restored.revisionCount, 0);
      expect(
        (await target.informationAttachmentVersions(
          ref.attachmentId,
        )).single.purgedAt,
        targetNow,
      );
      targetNow = targetNow.subtract(const Duration(days: 2));
      await expectLater(
        target.readInformationAttachmentChunk(ref, 0, 3),
        fails('attachment_missing'),
      );
      expect(
        await repo.readInformationAttachmentChunk(ref, 0, 3),
        [1, 2, 3],
        reason: 'read-only export and recipient retention do not alter source',
      );
    },
  );
  test(
    'backup of a purged original keeps unavailable metadata and no chunks',
    () async {
      final first = await save([1, 2, 3]);
      final ref = first.fields.single.attachment!;
      await service.owner.deleteInformation(first.id, first.version);
      now = now.add(const Duration(days: 30));
      await service.owner.purgeInformationAttachments();
      final key = await enableTestBackups(repo.backups);
      final path = '${root.path}/purged.aimbackup';
      await repo.backups.exportTo(path);
      final reader = await AttachmentBackupContainer.openValidated(path, key);
      try {
        expect(reader.versions.single.available, isFalse);
        await expectLater(
          reader.readAttachment(ref).toList(),
          throwsA(isA<StorageFailure>()),
        );
      } finally {
        reader.close();
      }
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
        clock: () => now,
      );
      addTearDown(target.close);
      await target.backups.restoreFrom(path, key);
      expect(
        (await target.informationAttachmentVersions(
          ref.attachmentId,
        )).single.byteLength,
        3,
      );
      await expectLater(
        target.readInformationAttachmentChunk(ref, 0, 3),
        fails('attachment_missing'),
      );
    },
  );
  test(
    'returning an old revision to current resets retirement and never purges current bytes',
    () async {
      final first = await save([1, 2, 3]);
      final next = await save([7, 8], first);
      now = now.add(const Duration(days: 20));
      await service.owner.restoreRevision(
        first.id,
        first.version,
        next.version,
      );
      now = now.add(const Duration(days: 365));
      await service.owner.purgeInformationAttachments();
      expect(
        await repo.readInformationAttachmentChunk(
          first.fields.single.attachment!,
          0,
          3,
        ),
        [1, 2, 3],
      );
      await expectLater(
        repo.readInformationAttachmentChunk(
          next.fields.single.attachment!,
          0,
          2,
        ),
        fails('attachment_missing'),
      );
      final key = await enableTestBackups(repo.backups);
      final path = '${root.path}/active.aimbackup';
      await repo.backups.exportTo(path);
      final preview = await repo.backups.inspect(path, key);
      expect(preview.attachmentCount, 1);
      expect(preview.attachmentBytes, 3);
    },
  );
  test(
    'stage reclaims expired retained BLOB budget before accepting a replacement',
    () async {
      final data = Uint8List(informationFileByteLimit);
      InformationItem? first;
      for (var n = 0; n < 10; n++) {
        final item = await save(data);
        first ??= item;
      }
      await service.owner.deleteInformation(first!.id, first.version);
      final draft = await service.owner.beginInformationFileDraft();
      await expectLater(
        service.owner.stageInformationFile(draft, '${root.path}/fictional.pdf'),
        fails('attachment_capacity_exceeded'),
      );
      now = now.add(const Duration(days: 30));
      final stage = await service.owner.stageInformationFile(
        draft,
        '${root.path}/fictional.pdf',
      );
      expect(stage.byteLength, informationFileByteLimit);
      final db = inspect();
      try {
        expect(
          db
              .select(
                'SELECT sum(byte_length) AS n FROM information_attachment_versions WHERE body IS NOT NULL',
              )
              .single['n'],
          9 * informationFileByteLimit,
        );
      } finally {
        db.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
