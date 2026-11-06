import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import '../../info_core/test/fixtures/legacy_attachment_fixture.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-move-sql-');
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

  test(
    'encrypted mixed move rolls back entirely, survives reopen and backup without copying attachments',
    () async {
      final source = await service.owner.createDirectory('原目录');
      final child = await service.owner.createDirectory(
        '子目录',
        parentId: source.id,
      );
      final target = await service.owner.createDirectory('目标');
      final file = await createLegacyAttachment(service, repo);
      final nested = await service.owner.createInformation('子目录资料', '', [
        const FieldInput('正文', '', 'PRIVATE-NESTED'),
      ], directoryId: child.id);
      final credential = await service.owner.createStringCredential(
        name: '凭据',
        publicPurpose: '',
        secret: 'PRIVATE-TOKEN',
      );
      final outside = await service.owner.createInformation('不处理', '', [
        const FieldInput('正文', '', 'PRIVATE-OUTSIDE'),
      ]);
      final original = jsonEncode(informationToJson(file));
      final originalMaterial = jsonEncode(
        repo.credentialMaterials.single.toStorageJson(),
      );
      final attachmentId = file.fields.first.attachment!.attachmentId;
      final versions = await repo.informationAttachmentVersions(attachmentId);
      final selection = LibrarySelection(
        directoryIds: [source.id, child.id],
        informationIds: [nested.id, file.id],
        credentialIds: [credential.id],
      );
      final preview = await service.owner.previewLibraryMove(
        selection,
        target.id,
      );
      final oldFormat = sql(
        (db) => db.select('PRAGMA user_version').single.values.single,
      );
      sql(
        (db) => db.execute(
          "CREATE TRIGGER fail_move BEFORE INSERT ON library_move_operations BEGIN SELECT RAISE(ABORT,'synthetic interruption'); END",
        ),
      );
      await expectLater(
        service.owner.moveLibrarySelection(
          'move',
          selection,
          target.id,
          preview.token,
        ),
        throwsA(isA<StorageFailure>()),
      );
      expect(
        jsonEncode(
          informationToJson(
            service.owner.information.singleWhere((i) => i.id == file.id),
          ),
        ),
        original,
      );
      expect(
        service.owner.directories
            .singleWhere((d) => d.id == source.id)
            .parentId,
        isNull,
      );
      expect(
        service.owner.credential(credential.id).revision,
        credential.revision,
      );
      expect(await service.owner.libraryMoveReceipt('move'), isNull);
      expect(
        sql(
          (db) => db.select(
            'SELECT directory_id FROM information_items WHERE id=?',
            [file.id],
          ).single['directory_id'],
        ),
        file.directoryId,
      );
      expect(
        sql(
          (db) => db.select(
            'SELECT parent_id FROM information_directories WHERE id=?',
            [source.id],
          ).single['parent_id'],
        ),
        isNull,
      );
      sql((db) => db.execute('DROP TRIGGER fail_move'));
      final receipt = await service.owner.moveLibrarySelection(
        'move',
        selection,
        target.id,
        preview.token,
      );
      expect(
        sql((db) => db.select('PRAGMA user_version').single.values.single),
        oldFormat,
      );
      expect(receipt.directoryIds, [source.id]);
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
      );
      service = InformationService(repository: repo);
      expect(
        (await service.owner.moveLibrarySelection(
          'move',
          selection,
          target.id,
          preview.token,
        )).toJson(),
        receipt.toJson(),
      );
      expect(
        service.owner.directories
            .singleWhere((d) => d.id == source.id)
            .parentId,
        target.id,
      );
      expect(
        service.owner.directories.singleWhere((d) => d.id == child.id).parentId,
        source.id,
      );
      expect(
        service.owner.information.singleWhere((i) => i.id == nested.id).version,
        nested.version,
      );
      final moved = service.owner.information.singleWhere(
        (i) => i.id == file.id,
      );
      expect(moved.directoryId, target.id);
      expect(moved.fields.map((f) => f.id), file.fields.map((f) => f.id));
      expect(
        informationToJson(
          service.owner.information.singleWhere((i) => i.id == outside.id),
        ),
        informationToJson(outside),
      );
      expect(
        service.owner.credential(credential.id).version,
        credential.version,
      );
      expect(
        service.owner.credential(credential.id).useGeneration,
        credential.useGeneration,
      );
      expect(
        jsonEncode(repo.credentialMaterials.single.toStorageJson()),
        originalMaterial,
      );
      expect(
        (await repo.informationAttachmentVersions(
          attachmentId,
        )).map((v) => v.toPrivateJson()),
        versions.map((v) => v.toPrivateJson()),
      );
      final recovery = await enableTestBackups(repo.backups);
      final backup = '${root.path}/moved.aim';
      await repo.backups.exportTo(backup);
      final copy = await EncryptedInformationRepository.open(
        '${root.path}/copy',
        TestKeyStore(),
      );
      final copyService = InformationService(repository: copy);
      try {
        // Machine-local acknowledgements must not prevent receiving a backup;
        // restoring it invalidates the old acknowledgement instead of replaying.
        final transient = await copyService.owner.createDirectory('临时目录');
        final s = LibrarySelection(directoryIds: [transient.id]);
        final p = await copyService.owner.previewLibraryMove(s, null);
        await copyService.owner.moveLibrarySelection(
          'old-local',
          s,
          null,
          p.token,
        );
        await copyService.owner.deleteDirectory(
          transient.id,
          transient.version,
        );
        expect(await copy.backups.recipientEmpty(), isTrue);
        await copy.backups.restore(
          await copy.backups.inspect(backup, recovery),
        );
        expect(
          copyService.owner.directories
              .singleWhere((d) => d.id == source.id)
              .parentId,
          target.id,
        );
        final copied = copyService.owner.information.singleWhere(
          (i) => i.id == file.id,
        );
        expect(informationToJson(copied), informationToJson(moved));
        expect(
          jsonEncode(copy.credentialMaterials.single.toStorageJson()),
          originalMaterial,
        );
        expect(
          (await copy.informationAttachmentVersions(
            attachmentId,
          )).map((v) => v.toPrivateJson()),
          versions.map((v) => v.toPrivateJson()),
        );
        expect(await copyService.owner.libraryMoveReceipt('move'), isNull);
        await expectLater(
          copyService.owner.libraryMoveReceipt('old-local'),
          throwsA(
            isA<AccessFailure>().having(
              (e) => e.status,
              'status',
              'library_changed',
            ),
          ),
        );
        // Exercise the actual bytes as well as metadata after the full roundtrip.
        for (final v in versions) {
          expect(
            await copy.readInformationAttachmentChunk(
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
      } finally {
        await copyService.close();
        await copy.close();
      }
    },
  );

  test(
    'transaction checks authoritative directory state even if owner cache is stale',
    () async {
      final source = await service.owner.createDirectory('原目录');
      final target = await service.owner.createDirectory('目标');
      final selection = LibrarySelection(directoryIds: [source.id]);
      final p = await service.owner.previewLibraryMove(selection, target.id);
      sql(
        (db) => db.execute(
          'UPDATE information_directories SET name=?,version=version+1 WHERE id=?',
          ['另一个名称', target.id],
        ),
      );
      await expectLater(
        service.owner.moveLibrarySelection(
          'stale-sql',
          selection,
          target.id,
          p.token,
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'library_selection_changed',
          ),
        ),
      );
      expect(await service.owner.libraryMoveReceipt('stale-sql'), isNull);
      expect(
        sql(
          (db) => db.select(
            'SELECT parent_id FROM information_directories WHERE id=?',
            [source.id],
          ).single['parent_id'],
        ),
        isNull,
      );
      expect(
        service.owner.directories
            .singleWhere((d) => d.id == source.id)
            .parentId,
        isNull,
      );
    },
  );
}
