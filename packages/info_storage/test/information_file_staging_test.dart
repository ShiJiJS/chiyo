import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
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
  Future<void> create(List<int> value) async => key = List.of(value);
}

Matcher fails(String code) =>
    throwsA(isA<AccessFailure>().having((e) => e.status, 'status', code));

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repository;
  sqlite.Database inspect() {
    final db = sqlite.sqlite3.open('${root.path}/vault/library.db');
    final hex = keys.key!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  Future<InformationFileStage> stage(
    String id,
    Uint8List bytes, {
    String draft = 'draft',
  }) => repository.stageInformationBytes(
    draftId: draft,
    stageId: id,
    originalName: 'fictional resume.pdf',
    mediaType: 'application/pdf',
    bytes: bytes,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('encrypted-file-intake-');
    keys = _Keys();
    repository = await EncryptedInformationRepository.open(
      '${root.path}/vault',
      keys,
    );
  });
  tearDown(() async {
    await repository.close();
    await root.delete(recursive: true);
  });

  test(
    'SQLCipher owns exact BLOB bytes and metadata without loading them into items',
    () async {
      final original = Uint8List.fromList([
        0,
        255,
        42,
        ...utf8.encode('SYNTHETIC-BLOB-PRIVATE-482179'),
      ]);
      final supplied = Uint8List.fromList(original);
      final writing = stage('s1', supplied);
      supplied.fillRange(0, supplied.length, 17);
      final saved = await writing;
      final db = inspect();
      try {
        final row = db.select('SELECT * FROM information_file_stages').single;
        expect(row['body'], original);
        expect(row['byte_length'], original.length);
        final metadata = InformationFileStage.fromPrivateJson(
          jsonDecode(row['metadata'] as String) as Map<String, dynamic>,
        );
        expect(metadata.sameAs(saved), isTrue);
        expect(saved.sha256, sha256.convert(original).toString());
        expect(db.select('PRAGMA user_version').single.values.single, 28);
        expect(
          db.select('SELECT version FROM library_format').single.values.single,
          28,
        );
      } finally {
        db.close();
      }
      expect(repository.items, isEmpty);
      final usage = await repository.informationFileStagingUsage();
      expect(usage.bytes, original.length);
      final encryptedFiles = Directory('${root.path}/vault')
          .listSync()
          .whereType<File>()
          .where(
            (file) =>
                file.path.endsWith('library.db') ||
                file.path.endsWith('-wal') ||
                file.path.endsWith('-journal') ||
                file.path.endsWith('-shm'),
          )
          .toList();
      expect(encryptedFiles, isNotEmpty);
      for (final file in encryptedFiles) {
        final disk = latin1.decode(await file.readAsBytes());
        expect(disk, isNot(contains('SYNTHETIC-BLOB-PRIVATE-482179')));
        expect(disk, isNot(contains('fictional resume.pdf')));
      }
    },
  );

  test(
    'same stage retry and failed replacement keep bytes; releases are draft scoped',
    () async {
      final first = await stage('s1', Uint8List.fromList([1, 2, 3]));
      expect(
        (await stage('s1', Uint8List.fromList([1, 2, 3]))).sameAs(first),
        isTrue,
      );
      await expectLater(
        stage('s1', Uint8List.fromList([3, 2, 1])),
        fails('operation_conflict'),
      );
      await repository.releaseInformationStage('other', 's1');
      await repository.releaseInformationDraft('other');
      expect((await repository.informationFileStagingUsage()).files, 1);
      final db = inspect();
      try {
        expect(
          db
              .select('SELECT body FROM information_file_stages')
              .single
              .values
              .single,
          [1, 2, 3],
        );
      } finally {
        db.close();
      }
      await repository.releaseInformationStage('draft', 's1');
      await repository.releaseInformationStage('draft', 's1');
      expect((await repository.informationFileStagingUsage()).bytes, 0);
    },
  );

  test(
    'database insertion failure is atomic and can retry without losing prior stages',
    () async {
      await stage('existing', Uint8List.fromList([4]));
      var db = inspect();
      db.execute(
        "CREATE TRIGGER reject_stage BEFORE INSERT ON information_file_stages BEGIN SELECT RAISE(FAIL,'synthetic write failure'); END",
      );
      db.close();
      await expectLater(
        stage('new', Uint8List.fromList([5])),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'attachment_stage_failed',
          ),
        ),
      );
      expect((await repository.informationFileStagingUsage()).files, 1);
      db = inspect();
      db.execute('DROP TRIGGER reject_stage');
      db.close();
      await stage('new', Uint8List.fromList([5]));
      expect((await repository.informationFileStagingUsage()).bytes, 2);
    },
  );

  test(
    'failed draft cancellation cannot partially remove its staged files',
    () async {
      await stage('first', Uint8List.fromList([1]));
      await stage('second', Uint8List.fromList([2]));
      var db = inspect();
      db.execute(
        "CREATE TRIGGER reject_second_delete BEFORE DELETE ON information_file_stages WHEN OLD.id='second' BEGIN SELECT RAISE(FAIL,'synthetic cancellation failure'); END",
      );
      db.close();
      await expectLater(
        repository.releaseInformationDraft('draft'),
        throwsA(isA<StorageFailure>()),
      );
      expect((await repository.informationFileStagingUsage()).files, 2);
      db = inspect();
      db.execute('DROP TRIGGER reject_second_delete');
      db.close();
      await repository.releaseInformationDraft('draft');
      expect((await repository.informationFileStagingUsage()).files, 0);
    },
  );

  test(
    'transactional byte budget serializes simultaneous final-size reservations',
    () async {
      final bytes = Uint8List(informationFileByteLimit);
      for (var n = 0; n < 9; n++) {
        await stage('large$n', bytes);
      }
      final outcomes = await Future.wait([
        for (final id in ['last-a', 'last-b'])
          stage(id, bytes).then<Object>((v) => v, onError: (Object e) => e),
      ]);
      expect(outcomes.whereType<InformationFileStage>(), hasLength(1));
      expect(
        outcomes.whereType<AccessFailure>().single.status,
        'attachment_capacity_exceeded',
      );
      final usage = await repository.informationFileStagingUsage();
      expect(usage.bytes, informationFileStagingByteLimit);
      expect(usage.files, 10);
      await expectLater(
        stage('too-big', Uint8List(informationFileByteLimit + 1)),
        fails('attachment_too_large'),
      );
      await repository.releaseInformationStage('draft', 'large0');
      await stage('freed-space', bytes);
      expect(
        (await repository.informationFileStagingUsage()).bytes,
        informationFileStagingByteLimit,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'reopening a library clears orphan stages without deleting formal text',
    () async {
      await repository.save(
        InformationItem('i', '保留信息', '', 1, const [
          InformationField('f', '字段', '', '文本', 1),
        ]),
      );
      await stage('orphan', Uint8List.fromList([0, 255]));
      await repository.close();
      final db = inspect();
      try {
        expect(
          db
              .select('SELECT count(*) FROM information_file_stages')
              .single
              .values
              .single,
          1,
        );
      } finally {
        db.close();
      }
      repository = await EncryptedInformationRepository.open(
        '${root.path}/vault',
        keys,
      );
      expect((await repository.informationFileStagingUsage()).files, 0);
      expect(repository.items.single.fields.single.value, '文本');
    },
  );

  test(
    'schema18 structural fixture upgrades using format marker and conflicting table rolls back',
    () async {
      await repository.save(
        InformationItem('i', '原信息', '', 1, const [
          InformationField('f', '字段', '', '字节不变', 1),
        ]),
      );
      await repository.close();
      var db = inspect();
      db.execute('DROP TABLE information_deliveries');
      db.execute('DROP TABLE information_file_fields');
      db.execute('DROP TABLE information_attachment_versions');
      db.execute('DROP TABLE information_draft_commits');
      db.execute('DROP TABLE information_file_stages');
      db.execute('UPDATE library_format SET version=18');
      db.execute('PRAGMA user_version=10');
      db.close();
      // All remaining structures are schema18. This is a structural fixture,
      // not a claim that an old executable was run in this test.
      repository = await EncryptedInformationRepository.open(
        '${root.path}/vault',
        keys,
      );
      expect(repository.items.single.fields.single.value, '字节不变');
      await repository.close();
      db = inspect();
      db.execute('DROP TABLE information_deliveries');
      db.execute('DROP TABLE information_file_fields');
      db.execute('DROP TABLE information_attachment_versions');
      db.execute('DROP TABLE information_draft_commits');
      db.execute('DROP TABLE information_file_stages');
      db.execute('CREATE TABLE information_file_stages(unrelated TEXT)');
      db.execute('UPDATE library_format SET version=18');
      db.execute('PRAGMA user_version=10');
      db.close();
      await expectLater(
        EncryptedInformationRepository.open('${root.path}/vault', keys),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'unsupported_schema',
          ),
        ),
      );
      db = inspect();
      try {
        expect(
          db.select('SELECT version FROM library_format').single.values.single,
          18,
        );
        expect(db.select('PRAGMA user_version').single.values.single, 10);
        expect(
          db
              .select('SELECT value FROM information_fields')
              .single
              .values
              .single,
          '字节不变',
        );
      } finally {
        db.close();
      }
    },
  );

  test(
    'backup excludes stages and successful restore clears drafts atomically; wrong key preserves them',
    () async {
      await repository.save(
        InformationItem('i', '正式文本', '', 1, const [
          InformationField('f', '姓名', '', '虚构姓名', 1),
        ]),
      );
      await stage('not-formal', Uint8List.fromList([1, 2]));
      final key = await enableTestBackups(repository.backups);
      final path = '${root.path}/text.aimbackup';
      await repository.backups.exportTo(path);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
      );
      final owner = InformationService(repository: target);
      addTearDown(() async {
        await owner.close();
        await target.close();
      });
      final file = File('${root.path}/draft.txt');
      await file.writeAsString('fake temporary file');
      final draft = await owner.owner.beginInformationFileDraft();
      await owner.owner.stageInformationFile(draft, file.path);
      final wrongKey = key.substring(0, key.length - 4) + 'AAAA';
      await expectLater(
        owner.owner.restoreLibrary(
          () => target.backups.restoreFrom(path, wrongKey),
        ),
        throwsA(isA<StorageFailure>()),
      );
      expect((await target.informationFileStagingUsage()).files, 1);
      expect(target.items, isEmpty);
      final restored = await owner.owner.restoreLibrary(
        () => target.backups.restoreFrom(path, key),
      );
      expect(restored.formatVersion, 7);
      expect(target.items.single.name, '正式文本');
      expect((await target.informationFileStagingUsage()).files, 0);
      await expectLater(
        owner.owner.stageInformationFile(draft, file.path),
        fails('stage_unavailable'),
      );
      await owner.owner.releaseInformationFileDraft(draft);
      expect((await repository.informationFileStagingUsage()).files, 1);
      expect(await file.exists(), isTrue);
    },
  );
}
