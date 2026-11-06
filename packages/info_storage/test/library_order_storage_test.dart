import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import '../../info_core/test/fixtures/legacy_attachment_fixture.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void _rewriteBackup(
  String path,
  String recovery,
  void Function(Map<String, dynamic>) change,
) {
  final db = sqlite3.open(path);
  try {
    final hex = base64Url
        .decode(recovery.substring('aim-recovery-v1:'.length))
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    db.execute('PRAGMA cipher_compatibility = 4');
    final json =
        jsonDecode(
              db
                      .select('SELECT payload FROM backup_snapshot')
                      .single
                      .values
                      .single
                  as String,
            )
            as Map<String, dynamic>;
    change(json);
    db.execute('UPDATE backup_snapshot SET payload=?', [jsonEncode(json)]);
  } finally {
    db.close();
  }
}

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-order-sql-');
    keys = TestKeyStore();
    repo = await EncryptedInformationRepository.open('${root.path}/data', keys);
    service = InformationService(repository: repo);
  });
  tearDown(() async {
    await service.close();
    await repo.close();
    await root.delete(recursive: true);
  });
  T sql<T>(T Function(Database) action) {
    final db = sqlite3.open('${root.path}/data/library.db');
    try {
      final hex = keys.key!
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      return action(db);
    } finally {
      db.close();
    }
  }

  Future<void> reopen() async {
    await service.close();
    await repo.close();
    repo = await EncryptedInformationRepository.open('${root.path}/data', keys);
    service = InformationService(repository: repo);
  }

  Future<LibraryMoveReceipt> place(
    String id,
    LibrarySelection selection,
    String? parent,
    LibraryMovePosition position,
  ) async {
    final p = await service.owner.previewLibraryMove(
      selection,
      parent,
      position: position,
    );
    return service.owner.moveLibrarySelection(
      id,
      selection,
      parent,
      p.token,
      position: position,
    );
  }

  List<String> dirs(OwnerAccess owner, String? parent) => owner.directories
      .where((d) => d.parentId == parent)
      .map((d) => d.id)
      .toList();
  List<LibraryEntryRef> records(OwnerAccess owner, String? parent) {
    final selected = {
      for (final i in owner.information.where((i) => i.directoryId == parent))
        LibraryEntryRef('information', i.id),
      for (final c in owner.credentials.where((c) => c.directoryId == parent))
        LibraryEntryRef('credential', c.id),
    };
    return owner.libraryRecordsInOrder.where(selected.contains).toList();
  }

  test(
    'encrypted ordering rolls back with placement and survives restart, backup and whole-batch recovery',
    () async {
      final file = await createLegacyAttachment(service, repo);
      final a = await service.owner.createDirectory('A'),
          b = await service.owner.createDirectory('B'),
          c = await service.owner.createDirectory('C');
      final first = await service.owner.createInformation('第一条', '', [
        const FieldInput('正文', '', 'PRIVATE-FIRST'),
      ], directoryId: a.id);
      final last = await service.owner.createInformation('最后一条', '', [
        const FieldInput('正文', '', 'PRIVATE-LAST'),
      ], directoryId: a.id);
      final credential = await service.owner.createStringCredential(
        name: '合成凭据',
        publicPurpose: '',
        secret: 'PRIVATE-TOKEN',
      );
      final attachment = file.fields.first.attachment!,
          versions = await repo.informationAttachmentVersions(
            attachment.attachmentId,
          );
      final oldFormat = sql(
        (db) => db.select('PRAGMA user_version').single.values.single,
      );
      final selection = LibrarySelection(directoryIds: [c.id]);
      final pos = LibraryMovePosition(LibraryEntryRef('directory', a.id));
      final p = await service.owner.previewLibraryMove(
        selection,
        null,
        position: pos,
      );
      expect(repo.libraryOrder, isNull);
      sql(
        (db) => db.execute(
          "CREATE TRIGGER fail_order BEFORE INSERT ON library_move_operations BEGIN SELECT RAISE(ABORT,'synthetic interrupted ordering'); END",
        ),
      );
      await expectLater(
        service.owner.moveLibrarySelection(
          'order-dirs',
          selection,
          null,
          p.token,
          position: pos,
        ),
        throwsA(isA<StorageFailure>()),
      );
      expect(repo.libraryOrder, isNull);
      expect(dirs(service.owner, null), [a.id, b.id, c.id]);
      expect(
        sql(
          (db) => db
              .select('SELECT count(*) FROM library_order_state')
              .single
              .values
              .single,
        ),
        0,
      );
      expect(
        sql((db) => db.select('PRAGMA user_version').single.values.single),
        oldFormat,
      );
      sql((db) => db.execute('DROP TRIGGER fail_order'));
      final receipt = await service.owner.moveLibrarySelection(
        'order-dirs',
        selection,
        null,
        p.token,
        position: pos,
      );
      expect(
        sql((db) => db.select('PRAGMA user_version').single.values.single),
        51,
      );
      expect(dirs(service.owner, null), [c.id, a.id, b.id]);
      expect(service.owner.directories.map((d) => d.version), everyElement(1));
      await place(
        'mixed-before-last',
        LibrarySelection(
          informationIds: [file.id],
          credentialIds: [credential.id],
        ),
        a.id,
        LibraryMovePosition(LibraryEntryRef('information', last.id)),
      );
      final expectedRecords = [
        LibraryEntryRef('information', first.id),
        LibraryEntryRef('information', file.id),
        LibraryEntryRef('credential', credential.id),
        LibraryEntryRef('information', last.id),
      ];
      expect(records(service.owner, a.id), expectedRecords);
      final orderDigest = repo.libraryOrder!.digest;
      await reopen();
      expect(repo.libraryOrder!.digest, orderDigest);
      expect(dirs(service.owner, null), [c.id, a.id, b.id]);
      expect(records(service.owner, a.id), expectedRecords);
      expect(
        (await service.owner.moveLibrarySelection(
          'order-dirs',
          selection,
          null,
          p.token,
          position: pos,
        )).toJson(),
        receipt.toJson(),
      );
      expect(
        service.owner.credential(credential.id).version,
        credential.version,
      );
      expect(
        service.owner.credential(credential.id).useGeneration,
        credential.useGeneration,
      );
      final recycle = LibrarySelection(directoryIds: [a.id]);
      final reviewed = await service.owner.previewLibraryRecycle(recycle);
      final batch = await service.owner.recycleLibrarySelection(
        'recycle-A',
        recycle,
        reviewed.token,
      );
      expect(dirs(service.owner, null), [c.id, b.id]);
      final key = await enableTestBackups(repo.backups),
          path = '${root.path}/ordered-group.aim';
      await repo.backups.exportTo(path);
      final copied = await EncryptedInformationRepository.open(
        '${root.path}/copy',
        TestKeyStore(),
      );
      final copiedService = InformationService(repository: copied);
      try {
        final archive = await copied.backups.inspect(path, key);
        expect(archive.formatVersion, 21);
        await copied.backups.restore(archive);
        expect(copied.libraryOrder!.digest, repo.libraryOrder!.digest);
        expect(dirs(copiedService.owner, null), [c.id, b.id]);
        expect(copiedService.owner.information, isEmpty);
        expect(await copied.libraryMoveReceipt('order-dirs'), isNull);
        final recovery = await copiedService.owner.previewLibraryRecycleRestore(
          batch.batchId,
        );
        await copiedService.owner.restoreLibraryRecycleBatch(
          'restore-A',
          batch.batchId,
          recovery.token,
        );
        expect(dirs(copiedService.owner, null), [c.id, a.id, b.id]);
        expect(records(copiedService.owner, a.id), expectedRecords);
        expect(copiedService.owner.credential(credential.id).enabled, isFalse);
        for (final v in versions) {
          expect(
            await copied.readInformationAttachmentChunk(
              v.reference,
              0,
              v.byteLength,
            ),
            await repo.readInformationAttachmentChunk(
              v.reference,
              0,
              v.byteLength,
            ),
          );
        }
        expect(
          copiedService.agent.catalogDirectories().map((r) => r['order']),
          [0, 1, 2],
        );
      } finally {
        await copiedService.close();
        await copied.close();
      }
    },
  );

  test(
    'the SQL transaction checks ordering changes not visible in the owner cache',
    () async {
      final a = await service.owner.createDirectory('A'),
          b = await service.owner.createDirectory('B'),
          c = await service.owner.createDirectory('C');
      await place(
        'init',
        LibrarySelection(directoryIds: [c.id]),
        null,
        LibraryMovePosition(LibraryEntryRef('directory', a.id)),
      );
      final selection = LibrarySelection(directoryIds: [b.id]),
          position = LibraryMovePosition(LibraryEntryRef('directory', a.id));
      final p = await service.owner.previewLibraryMove(
        selection,
        null,
        position: position,
      );
      final old = repo.libraryOrder!;
      final externallyChanged = LibraryOrderSnapshot(
        revision: old.revision + 1,
        directories: [b.id, c.id, a.id],
        records: old.records,
      );
      sql(
        (db) => db.execute('UPDATE library_order_state SET payload=?', [
          jsonEncode(externallyChanged.toJson()),
        ]),
      );
      await expectLater(
        service.owner.moveLibrarySelection(
          'stale',
          selection,
          null,
          p.token,
          position: position,
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'library_selection_changed',
          ),
        ),
      );
      expect(await service.owner.libraryMoveReceipt('stale'), isNull);
      expect(repo.libraryOrder!.digest, old.digest);
      await reopen();
      expect(dirs(service.owner, null), [b.id, c.id, a.id]);
      expect(repo.libraryOrder!.digest, externallyChanged.digest);
    },
  );

  test(
    'new ordering format rejects low and unknown markers and malformed stored metadata',
    () async {
      final a = await service.owner.createDirectory('A'),
          b = await service.owner.createDirectory('B');
      await place(
        'init',
        LibrarySelection(directoryIds: [b.id]),
        null,
        LibraryMovePosition(LibraryEntryRef('directory', a.id)),
      );
      final saved = repo.libraryOrder!;
      await service.close();
      await repo.close();
      for (final format in [50, 52]) {
        sql((db) {
          db.execute('UPDATE library_format SET version=?', [format]);
          db.execute('PRAGMA user_version=$format');
        });
        await expectLater(
          EncryptedInformationRepository.open('${root.path}/data', keys),
          throwsA(
            isA<StorageFailure>().having(
              (e) => e.code,
              'code',
              'unsupported_schema',
            ),
          ),
        );
      }
      sql((db) {
        db.execute('UPDATE library_format SET version=51');
        db.execute('PRAGMA user_version=51');
        db.execute('UPDATE library_order_state SET payload=?', [
          jsonEncode({...saved.toJson(), 'format': 2}),
        ]);
      });
      await expectLater(
        EncryptedInformationRepository.open('${root.path}/data', keys),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'invalid_library_order',
          ),
        ),
      );
      sql(
        (db) => db.execute('UPDATE library_order_state SET payload=?', [
          jsonEncode(saved.toJson()),
        ]),
      );
      repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
      );
      service = InformationService(repository: repo);
      expect(dirs(service.owner, null), [b.id, a.id]);
    },
  );

  test(
    'authenticated backups validate order metadata, accept v20 and replace only old ordering in an empty recipient',
    () async {
      final a = await service.owner.createDirectory('A'),
          b = await service.owner.createDirectory('B');
      await place(
        'init',
        LibrarySelection(directoryIds: [b.id]),
        null,
        LibraryMovePosition(LibraryEntryRef('directory', a.id)),
      );
      final key = await enableTestBackups(repo.backups),
          path = '${root.path}/ordered.aim';
      await repo.backups.exportTo(path);
      final changes = <void Function(Map<String, dynamic>)>[
        (doc) {
          final tables = doc['tables'] as Map;
          final rows = tables['library_order_state'] as List;
          rows.single['id'] = 'unexpected';
        },
        (doc) {
          final rows = (doc['tables'] as Map)['library_order_state'] as List;
          final j = jsonDecode(rows.single['payload'] as String) as Map;
          j['format'] = 2;
          rows.single['payload'] = jsonEncode(j);
        },
        (doc) {
          final rows = (doc['tables'] as Map)['library_order_state'] as List;
          final j = jsonDecode(rows.single['payload'] as String) as Map;
          j['directories'] = ['same', 'same'];
          rows.single['payload'] = jsonEncode(j);
        },
        (doc) {
          final rows = (doc['tables'] as Map)['library_order_state'] as List;
          final j = jsonDecode(rows.single['payload'] as String) as Map;
          j['records'] = [
            ['directory', 'invalid-lane'],
          ];
          rows.single['payload'] = jsonEncode(j);
        },
        (doc) {
          final rows = (doc['tables'] as Map)['library_order_state'] as List;
          rows.add(Map.of(rows.single as Map));
        },
      ];
      for (var i = 0; i < changes.length; i++) {
        final bad = '${root.path}/bad-$i.aim';
        await File(path).copy(bad);
        _rewriteBackup(bad, key, changes[i]);
        await expectLater(
          repo.backups.inspect(bad, key),
          throwsA(
            isA<StorageFailure>().having(
              (e) => e.code,
              'code',
              'invalid_backup',
            ),
          ),
        );
      }
      final legacy = '${root.path}/v20.aim';
      await File(path).copy(legacy);
      _rewriteBackup(legacy, key, (doc) {
        doc['version'] = 20;
        (doc['tables'] as Map).remove('library_order_state');
      });
      expect((await repo.backups.inspect(legacy, key)).formatVersion, 20);
      final recipientKeys = TestKeyStore();
      final recipient = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        recipientKeys,
      );
      final recipientService = InformationService(repository: recipient);
      T recipientSql<T>(T Function(Database) fn) {
        final db = sqlite3.open('${root.path}/recipient/library.db');
        try {
          final hex = recipientKeys.key!
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join();
          db.execute('PRAGMA key = "x\'$hex\'"');
          return fn(db);
        } finally {
          db.close();
        }
      }

      try {
        final x = await recipientService.owner.createDirectory('旧临时一'),
            y = await recipientService.owner.createDirectory('旧临时二');
        final s = LibrarySelection(directoryIds: [y.id]),
            pos = LibraryMovePosition(LibraryEntryRef('directory', x.id));
        final p = await recipientService.owner.previewLibraryMove(
          s,
          null,
          position: pos,
        );
        await recipientService.owner.moveLibrarySelection(
          'old-local',
          s,
          null,
          p.token,
          position: pos,
        );
        await recipientService.owner.deleteDirectory(x.id, x.version);
        await recipientService.owner.deleteDirectory(y.id, y.version);
        final old = recipient.libraryOrder!.digest;
        expect(await recipient.backups.recipientEmpty(), isTrue);
        recipientSql(
          (db) => db.execute(
            "CREATE TRIGGER fail_restore BEFORE INSERT ON information_directories BEGIN SELECT RAISE(ABORT,'synthetic interrupted restore'); END",
          ),
        );
        await expectLater(
          recipient.backups.restore(
            await recipient.backups.inspect(legacy, key),
          ),
          throwsA(isA<StorageFailure>()),
        );
        expect(recipient.libraryOrder!.digest, old);
        expect(recipient.directories, isEmpty);
        expect(
          recipientSql(
            (db) => db
                .select('SELECT count(*) FROM library_order_state')
                .single
                .values
                .single,
          ),
          1,
        );
        recipientSql((db) => db.execute('DROP TRIGGER fail_restore'));
        await recipient.backups.restore(
          await recipient.backups.inspect(legacy, key),
        );
        expect(recipient.libraryOrder, isNull);
        expect(
          recipientSql(
            (db) => db
                .select('SELECT count(*) FROM library_order_state')
                .single
                .values
                .single,
          ),
          0,
        );
        expect(dirs(recipientService.owner, null), [a.id, b.id]);
        await expectLater(
          recipientService.owner.libraryMoveReceipt('old-local'),
          throwsA(
            isA<AccessFailure>().having(
              (e) => e.status,
              'status',
              'library_changed',
            ),
          ),
        );
      } finally {
        await recipientService.close();
        await recipient.close();
      }
    },
  );
}
