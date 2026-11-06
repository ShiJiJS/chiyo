import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import '../../info_core/test/fixtures/legacy_attachment_fixture.dart';
import '../../info_core/test/fixtures/credential_import_fixture.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  test(
    'one encrypted transaction retains directory batches, versions and files across failure, restart and backup',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'library-recycle-sql-',
      );
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
      );
      var service = InformationService(repository: repo);
      addTearDown(() async {
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

      final parent = await service.owner.createDirectory('服务');
      final child = await service.owner.createDirectory(
        '配置',
        parentId: parent.id,
      );
      final legacy = await createLegacyAttachment(service, repo);
      final item = await service.owner.organizeInformation(
        legacy.id,
        directoryId: child.id,
      );
      final outside = await service.owner.createInformation('外部说明', '', [
        const FieldInput('正文', '', 'PRIVATE-OUTSIDE'),
      ]);
      configureCredentialImports(service);
      final session = service.agent.openSession('合成目录回收');
      final id = await service.agent.submitImport(session, [
        ImportItemInput(
          '合成凭据',
          '',
          [],
          key: 'token',
          directoryId: parent.id,
          templateId: 'credential.token',
          templateVersion: '1',
          templateDigest: 'c' * 64,
          credential: CredentialImportInput.agentString('PRIVATE-TOKEN'),
          relations: {
            'related': [InformationRelationRef('information', outside.id)],
          },
        ),
      ]);
      final proposal = service.owner.importProposals.singleWhere(
        (p) => p.id == id,
      );
      await service.owner.confirmImport(id, proposal.version, proposal.items);
      final credential = service.owner.credentials.single;
      final versions = await repo.informationAttachmentVersions(
        item.fields.first.attachment!.attachmentId,
      );
      final selection = LibraryRecycleSelection(
        directoryIds: [parent.id, child.id],
        informationIds: [item.id],
        credentialIds: [credential.id],
      );
      final preview = await service.owner.previewLibraryRecycle(selection);
      final previousFormat = sql(
        (db) => db.select('PRAGMA user_version').single.values.single,
      );
      sql(
        (db) => db.execute(
          "CREATE TRIGGER fail_group BEFORE INSERT ON library_recycle_operations BEGIN SELECT RAISE(ABORT,'synthetic interruption'); END",
        ),
      );
      await expectLater(
        service.owner.recycleLibrarySelection(
          'group-delete',
          selection,
          preview.token,
        ),
        throwsA(isA<StorageFailure>()),
      );
      expect(repo.items, hasLength(2));
      expect(repo.directories, hasLength(2));
      expect(repo.libraryRecycleBatches, isEmpty);
      expect(service.owner.credentials.single.deletedAt, isNull);
      expect(
        sql(
          (db) => db
              .select('SELECT count(*) FROM library_recycle_batches')
              .single
              .values
              .single,
        ),
        0,
      );
      expect(
        sql((db) => db.select('PRAGMA user_version').single.values.single),
        previousFormat,
      );
      sql((db) => db.execute('DROP TRIGGER fail_group'));
      final deleted = await service.owner.recycleLibrarySelection(
        'group-delete',
        selection,
        preview.token,
      );
      expect(repo.items.single.id, outside.id);
      expect(repo.directories, isEmpty);
      expect(service.owner.credentials, isEmpty);
      expect(
        sql((db) => db.select('PRAGMA user_version').single.values.single),
        51,
      );
      expect(
        await service.owner.recycleLibrarySelection(
          'group-delete',
          selection,
          preview.token,
        ),
        isA<LibraryRecycleReceipt>(),
      );
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
      );
      service = InformationService(repository: repo);
      expect(
        (await service.owner.recycleLibrarySelection(
          'group-delete',
          selection,
          preview.token,
        )).toJson(),
        deleted.toJson(),
      );
      expect(service.owner.libraryRecycleBatches.single.id, deleted.batchId);
      final recovery = await enableTestBackups(repo.backups),
          backup = '${root.path}/deleted.aim';
      await repo.backups.exportTo(backup);
      final inspected = await repo.backups.inspect(backup, recovery);
      expect(inspected.formatVersion, 21);
      final copy = await EncryptedInformationRepository.open(
        '${root.path}/copy',
        TestKeyStore(),
      );
      final copiedService = InformationService(repository: copy);
      try {
        final groupedPreview = await copy.backups.inspectRestore(
          path: backup,
          recoveryKey: recovery,
          archiveId: 'grouped-backup',
          archiveVersion: 1,
        );
        expect(groupedPreview.counts['directoryBatches'], 1);
        groupedPreview.release();
        await copy.backups.restore(
          await copy.backups.inspect(backup, recovery),
        );
        expect(
          copy.libraryRecycleBatches.single.toJson(),
          repo.libraryRecycleBatches.single.toJson(),
        );
        expect(await copy.libraryRecycleReceipt('group-delete'), isNull);
        final copiedPreview = await copiedService.owner
            .previewLibraryRecycleRestore(deleted.batchId);
        expect(copiedPreview.conflicts, isEmpty);
        await copiedService.owner.restoreLibraryRecycleBatch(
          'copy-restore',
          deleted.batchId,
          copiedPreview.token,
        );
        expect(copy.items, hasLength(2));
        expect(copy.directories, hasLength(2));
        expect(copy.managedCredentials.single.enabled, false);
        for (var n = 0; n < versions.length; n++) {
          expect(
            await copy.readInformationAttachmentChunk(
              versions[n].reference,
              0,
              versions[n].byteLength,
            ),
            utf8.encode('原文$n'),
          );
        }
      } finally {
        await copiedService.close();
        await copy.close();
      }
      final restore = await service.owner.previewLibraryRecycleRestore(
        deleted.batchId,
      );
      sql(
        (db) => db.execute(
          "CREATE TRIGGER fail_group_restore BEFORE INSERT ON library_recycle_operations BEGIN SELECT RAISE(ABORT,'synthetic interruption'); END",
        ),
      );
      await expectLater(
        service.owner.restoreLibraryRecycleBatch(
          'group-restore',
          deleted.batchId,
          restore.token,
        ),
        throwsA(isA<StorageFailure>()),
      );
      expect(repo.items.single.id, outside.id);
      expect(repo.directories, isEmpty);
      expect(repo.managedCredentials.single.deletedAt, isNotNull);
      sql((db) => db.execute('DROP TRIGGER fail_group_restore'));
      final restored = await service.owner.restoreLibraryRecycleBatch(
        'group-restore',
        deleted.batchId,
        restore.token,
      );
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
      );
      service = InformationService(repository: repo);
      expect(
        (await service.owner.restoreLibraryRecycleBatch(
          'group-restore',
          deleted.batchId,
          restore.token,
        )).toJson(),
        restored.toJson(),
      );
      expect(repo.directories.map((d) => [d.id, d.name, d.parentId]).toList(), [
        [parent.id, parent.name, null],
        [child.id, child.name, parent.id],
      ]);
      expect(
        repo.items.singleWhere((i) => i.id == item.id).directoryId,
        child.id,
      );
      expect(
        repo.items.singleWhere((i) => i.id == item.id).fields.first.attachment,
        item.fields.first.attachment,
      );
      expect(repo.managedCredentials.single.enabled, false);
      expect(repo.managedCredentials.single.version, credential.version + 1);
      final afterBackup = '${root.path}/restored.aim';
      await repo.backups.exportTo(afterBackup);
      final afterCopy = await EncryptedInformationRepository.open(
        '${root.path}/after-copy',
        TestKeyStore(),
      );
      try {
        await afterCopy.backups.restore(
          await afterCopy.backups.inspect(afterBackup, recovery),
        );
        expect(
          afterCopy.libraryRecycleBatches.single.state,
          RecycleState.restored,
        );
        expect(afterCopy.items, hasLength(2));
        expect(afterCopy.managedCredentials.single.enabled, false);
      } finally {
        await afterCopy.close();
      }
      final raw = await File('${root.path}/data/library.db').readAsBytes();
      expect(latin1.decode(raw), isNot(contains('PRIVATE-TOKEN')));
      expect(latin1.decode(raw), isNot(contains('PRIVATE-OUTSIDE')));
    },
  );
  test(
    'SQL changes after review fail the atomic boundary and format gates reject mislabelled or future groups',
    () async {
      final root = await Directory.systemTemp.createTemp('group-format-sql-'),
          keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(root.path, keys);
      var service = InformationService(repository: repo);
      addTearDown(() async {
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      void sql(void Function(Database) action) {
        final db = sqlite3.open('${root.path}/library.db');
        try {
          final hex = keys.key!
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join();
          db.execute('PRAGMA key = "x\'$hex\'"');
          action(db);
        } finally {
          db.close();
        }
      }

      final directory = await service.owner.createDirectory('目录');
      final selection = LibraryRecycleSelection(directoryIds: [directory.id]);
      final old = await service.owner.previewLibraryRecycle(selection);
      sql((db) {
        db.execute(
          'INSERT INTO information_items(id,name,description,version,directory_id) VALUES(?,?,?,?,?)',
          ['external-synthetic', '后来新增', '', 1, directory.id],
        );
        db.execute(
          'INSERT INTO information_fields(id,item_id,name,description,value,version,kind) VALUES(?,?,?,?,?,?,?)',
          [
            'external-field',
            'external-synthetic',
            '正文',
            '',
            'PRIVATE',
            1,
            'structured',
          ],
        );
      });
      await expectLater(
        service.owner.recycleLibrarySelection(
          'external-delete',
          selection,
          old.token,
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'library_selection_changed',
          ),
        ),
      );
      expect(repo.libraryRecycleBatches, isEmpty);
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(root.path, keys);
      service = InformationService(repository: repo);
      final fresh = await service.owner.previewLibraryRecycle(selection);
      expect(fresh.records, hasLength(1));
      await service.owner.recycleLibrarySelection(
        'fresh-delete',
        selection,
        fresh.token,
      );
      await service.close();
      await repo.close();
      sql((db) {
        db.execute('UPDATE library_format SET version=49');
        db.execute('PRAGMA user_version=49');
      });
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
      sql((db) {
        db.execute('UPDATE library_format SET version=53');
        db.execute('PRAGMA user_version=53');
      });
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
      sql((db) {
        db.execute('UPDATE library_format SET version=51');
        db.execute('PRAGMA user_version=51');
      });
      repo = await EncryptedInformationRepository.open(root.path, keys);
      service = InformationService(repository: repo);
      expect(service.owner.libraryRecycleBatches.single.records, hasLength(1));
    },
  );

  test(
    'expired group backups never revive old directories, content or credential material',
    () async {
      final root = await Directory.systemTemp.createTemp('group-expiry-sql-');
      var now = DateTime.utc(2026, 1, 1);
      final repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        TestKeyStore(),
        clock: () => now,
      );
      final service = InformationService(repository: repo, clock: () => now);
      addTearDown(() async {
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      final directory = await service.owner.createDirectory('到期目录');
      final item = await service.owner.createInformation('到期资料', '', [
        const FieldInput('正文', '', 'PRIVATE-EXPIRED'),
      ], directoryId: directory.id);
      final c = await service.owner.createStringCredential(
        name: '到期凭据',
        publicPurpose: '合成',
        secret: 'PRIVATE-TOKEN',
      );
      final selection = LibraryRecycleSelection(
        directoryIds: [directory.id],
        credentialIds: [c.id],
      );
      final preview = await service.owner.previewLibraryRecycle(selection);
      final deleted = await service.owner.recycleLibrarySelection(
        'expire-delete',
        selection,
        preview.token,
      );
      final earlyKey = await enableTestBackups(repo.backups),
          earlyPath = '${root.path}/early.aim';
      await repo.backups.exportTo(earlyPath);
      now = now.add(const Duration(days: 31));
      expect(service.owner.libraryRecycleBatches, isEmpty);
      await expectLater(
        service.owner.previewLibraryRecycleRestore(deleted.batchId),
        throwsA(isA<AccessFailure>()),
      );
      final key = earlyKey, path = '${root.path}/expired.aim';
      await repo.backups.exportTo(path);
      final recipient = await EncryptedInformationRepository.open(
        '${root.path}/copy',
        TestKeyStore(),
        clock: () => now,
      );
      final copiedService = InformationService(
        repository: recipient,
        clock: () => now,
      );
      try {
        final earlyPreview = await recipient.backups.inspectRestore(
          path: earlyPath,
          recoveryKey: earlyKey,
          archiveId: 'early-backup',
          archiveVersion: 1,
        );
        expect(earlyPreview.counts['directoryBatches'] ?? 0, 0);
        earlyPreview.release();
        final inspected = await recipient.backups.inspect(path, key);
        expect(inspected.formatVersion, 21);
        expect(inspected.directoryRecycleBatchCount, 0);
        await recipient.backups.restore(inspected);
        expect(recipient.directories, isEmpty);
        expect(recipient.items, isEmpty);
        expect(recipient.credentialMaterials, isEmpty);
        expect(copiedService.owner.libraryRecycleBatches, isEmpty);
        expect(
          recipient.recycleEntries
              .singleWhere((e) => e.itemId == item.id)
              .snapshot,
          isNull,
        );
        await expectLater(
          copiedService.owner.previewLibraryRecycleRestore(deleted.batchId),
          throwsA(isA<AccessFailure>()),
        );
      } finally {
        await copiedService.close();
        await recipient.close();
      }
    },
  );
  test(
    'authenticated backups reject malformed or cross-linked directory batches before installing anything',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'group-malformed-backup-',
      );
      final repo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        TestKeyStore(),
      );
      final service = InformationService(repository: repo);
      final recipient = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        TestKeyStore(),
      );
      addTearDown(() async {
        await service.close();
        await repo.close();
        await recipient.close();
        await root.delete(recursive: true);
      });
      final dir = await service.owner.createDirectory('目录');
      await service.owner.createInformation('资料', '', [
        const FieldInput('正文', '', 'PRIVATE'),
      ], directoryId: dir.id);
      final selection = LibraryRecycleSelection(directoryIds: [dir.id]),
          preview = await service.owner.previewLibraryRecycle(
            LibraryRecycleSelection(directoryIds: [dir.id]),
          );
      await service.owner.recycleLibrarySelection(
        'malformed-source',
        selection,
        preview.token,
      );
      final key = await enableTestBackups(repo.backups),
          source = '${root.path}/valid.aim';
      await repo.backups.exportTo(source);
      final mutations = <void Function(Map<String, dynamic>)>[
        (doc) {
          final rows =
              (doc['tables'] as Map)['library_recycle_batches'] as List;
          final payload = jsonDecode(rows.single['payload'] as String) as Map;
          payload['unexpected'] = 'value';
          rows.single['payload'] = jsonEncode(payload);
        },
        (doc) {
          final rows =
              (doc['tables'] as Map)['library_recycle_batches'] as List;
          final payload = jsonDecode(rows.single['payload'] as String) as Map;
          final dirs = payload['directories'] as List;
          dirs.add(dirs.single);
          rows.single['payload'] = jsonEncode(payload);
        },
        (doc) {
          final rows =
              (doc['tables'] as Map)['library_recycle_batches'] as List;
          final payload = jsonDecode(rows.single['payload'] as String) as Map;
          final entries = payload['informationEntries'] as Map;
          entries[entries.keys.single] = 'missing-entry';
          rows.single['payload'] = jsonEncode(payload);
        },
        (doc) {
          final rows =
              (doc['tables'] as Map)['library_recycle_batches'] as List;
          final payload = jsonDecode(rows.single['payload'] as String) as Map;
          payload['id'] = 'second-group';
          rows.add({'id': 'second-group', 'payload': jsonEncode(payload)});
        },
      ];
      for (var i = 0; i < mutations.length; i++) {
        final path = '${root.path}/invalid-$i.aim';
        await File(source).copy(path);
        final db = sqlite3.open(path);
        try {
          final hex = base64Url
              .decode(key.substring('aim-recovery-v1:'.length))
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join();
          db.execute('PRAGMA key = "x\'$hex\'"');
          db.execute('PRAGMA cipher_compatibility = 4');
          final doc =
              jsonDecode(
                    db
                            .select('SELECT payload FROM backup_snapshot')
                            .single
                            .values
                            .single
                        as String,
                  )
                  as Map<String, dynamic>;
          mutations[i](doc);
          db.execute('UPDATE backup_snapshot SET payload=?', [jsonEncode(doc)]);
        } finally {
          db.close();
        }
        await expectLater(
          recipient.backups.inspect(path, key),
          throwsA(
            isA<StorageFailure>().having(
              (e) => e.code,
              'code',
              'invalid_backup',
            ),
          ),
        );
        expect(await recipient.backups.recipientEmpty(), true);
        expect(recipient.libraryRecycleBatches, isEmpty);
      }
      expect(
        (await recipient.backups.inspect(
          source,
          key,
        )).directoryRecycleBatchCount,
        1,
      );
    },
  );
  test(
    'large retained notes and credential files fit the same limits during state checks and reopen',
    () async {
      final root = await Directory.systemTemp.createTemp(
            'group-large-material-',
          ),
          keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(root.path, keys);
      var service = InformationService(repository: repo);
      addTearDown(() async {
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      final note = await service.owner.createInformation('大段合成说明', '', [
        for (var i = 0; i < 5; i++) FieldInput('段$i', '', 'x' * 64000),
      ]);
      await service.owner.deleteInformation(note.id, note.version);
      final credential = await service.owner.createFileCredential(
        name: '合成密钥文件',
        publicPurpose: '测试',
        fileName: 'synthetic.key',
        bytes: List<int>.generate(900000, (i) => i % 256),
      );
      final selection = LibraryRecycleSelection(credentialIds: [credential.id]);
      final preview = await service.owner.previewLibraryRecycle(selection);
      final deleted = await service.owner.recycleLibrarySelection(
        'large-delete',
        selection,
        preview.token,
      );
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(root.path, keys);
      service = InformationService(repository: repo);
      final restore = await service.owner.previewLibraryRecycleRestore(
        deleted.batchId,
      );
      await service.owner.restoreLibraryRecycleBatch(
        'large-restore',
        deleted.batchId,
        restore.token,
      );
      expect(
        repo.credentialMaterials
            .singleWhere(
              (m) =>
                  m.credentialId == credential.id &&
                  m.version == credential.version + 1,
            )
            .bytes,
        List<int>.generate(900000, (i) => i % 256),
      );
      expect(service.owner.credentials.single.enabled, false);
      expect(
        service.owner.recycleEntries.single.snapshot!.fields,
        hasLength(5),
      );
    },
  );
}
