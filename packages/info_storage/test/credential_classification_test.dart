import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'backup_setup.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  const secret = 'SYNTHETIC-classified-credential-material';
  const note = 'SYNTHETIC-Owner-only-note';
  final now = DateTime.utc(2026, 11, 1);
  Matcher access(String code) =>
      throwsA(isA<AccessFailure>().having((e) => e.status, 'status', code));
  Matcher storage(String code) =>
      throwsA(isA<StorageFailure>().having((e) => e.code, 'code', code));
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      '${root.path}/source',
      keys,
      clock: () => now,
    );
    service = InformationService(repository: repo, clock: () => now);
  }

  Future<void> close() async {
    await service.close();
    await repo.close();
  }

  Future<void> reopen() async {
    await close();
    await open();
  }

  Database inspect() {
    final db = sqlite3.open('${root.path}/source/library.db');
    final hex = keys.key!
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  Future<CredentialRecordReceipt> save(
    String op, {
    ManagedCredential? old,
    String? directory,
    List<String>? tags,
    bool classify = true,
  }) => service.owner.saveCredentialRecord(
    op,
    CredentialRecordInput(
      action: old == null
          ? CredentialRecordAction.create
          : CredentialRecordAction.edit,
      commandDigest: 'a' * 64,
      credentialId: old?.id,
      expectedRevision: old?.revision,
      expectedMaterialVersion: old?.version,
      form: old == null ? CredentialForm.string : null,
      name: '合成分类凭据',
      publicPurpose: '合成公开用途',
      privateNote: note,
      suggestedBinding: 'SYNTHETIC_TOKEN',
      material: old == null ? utf8.encode(secret) : null,
      discoverable: true,
      updateClassification: classify,
      directoryId: directory,
      tagIds: classify ? tags ?? [] : null,
    ),
  );
  Future<InformationClassificationReceipt> removeTag(
    String op,
    InformationTagRemovalPreview preview,
  ) => service.owner.changeInformationClassification(
    InformationClassificationCommand(
      operationId: op,
      expectedVersion: preview.version,
      kind: InformationClassificationKind.tag,
      action: InformationClassificationAction.delete,
      targetId: preview.tagId,
      removalToken: preview.token,
    ),
  );
  Future<void> mutateBackup(
    String source,
    String target,
    String key,
    void Function(Map<String, dynamic>) change,
  ) async {
    await File(source).copy(target);
    final db = sqlite3.open(target);
    try {
      final hex = base64Url
          .decode(key.substring('aim-recovery-v1:'.length))
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      final document =
          jsonDecode(
                db
                        .select('SELECT payload FROM backup_snapshot')
                        .single['payload']
                    as String,
              )
              as Map<String, dynamic>;
      change(document);
      db.execute('UPDATE backup_snapshot SET payload=?', [
        jsonEncode(document),
      ]);
    } finally {
      db.close();
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('credential-classification-');
    keys = TestKeyStore();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });

  test(
    'classification persists across exact replay, metadata changes and reopen without rotating material',
    () async {
      final directory = await service.owner.createDirectory('合成目录');
      final tag = await service.owner.createTag('合成标签');
      final created = await save(
        'create',
        directory: directory.id,
        tags: [tag.id],
      );
      final first = service.owner.credentials.single;
      expect(first.directoryId, directory.id);
      expect(first.tagIds, [tag.id]);
      await save('edit', old: first, classify: false);
      await reopen();
      final current = service.owner.credentials.single;
      expect(current.directoryId, directory.id);
      expect(current.tagIds, [tag.id]);
      expect(current.version, 1);
      expect(current.useGeneration, 1);
      expect(repo.credentialMaterials.single.bytes, utf8.encode(secret));
      expect(
        (await service.owner.credentialRecordReceipt('create'))!.toJson(),
        created.toJson(),
      );
      final public = jsonEncode(service.agent.credentialCatalog().toJson());
      expect(public, contains(tag.name));
      expect(public, isNot(contains(directory.name)));
      expect(public, isNot(contains(secret)));
      expect(public, isNot(contains(note)));
      final clear = await save('clear', old: current);
      expect(clear.revision, 3);
      expect(service.owner.credentials.single.directoryId, isNull);
      expect(service.owner.credentials.single.tagIds, isEmpty);
      await reopen();
      expect(service.owner.credentials.single.tagIds, isEmpty);
      final db = inspect();
      try {
        expect(db.select('PRAGMA user_version').single.values.single, 40);
      } finally {
        db.close();
      }
    },
  );

  test(
    'first classification marker and data roll back with failed original receipt',
    () async {
      final d = await service.owner.createDirectory('合成目录');
      final t = await service.owner.createTag('合成标签');
      await save('old-unclassified', classify: false);
      final before = service.owner.credentials.single;
      final db = inspect();
      try {
        expect(db.select('PRAGMA user_version').single.values.single, 38);
        db.execute(
          "CREATE TRIGGER fail_classified_receipt BEFORE INSERT ON information_record_operations WHEN NEW.operation_id='failed' BEGIN SELECT RAISE(ABORT,'synthetic'); END",
        );
        await expectLater(
          save('failed', old: before, directory: d.id, tags: [t.id]),
          storage('credential_save_failed'),
        );
        expect(db.select('PRAGMA user_version').single.values.single, 38);
        expect(
          db.select('SELECT version FROM library_format').single['version'],
          38,
        );
        expect(service.owner.credentials.single.toJson(), before.toJson());
        expect(await service.owner.credentialRecordReceipt('failed'), isNull);
        db.execute('DROP TRIGGER fail_classified_receipt');
      } finally {
        db.close();
      }
      await save('success', old: before, directory: d.id, tags: [t.id]);
      await reopen();
      expect(service.owner.credentials.single.tagIds, [t.id]);
    },
  );

  test(
    'nonexistent, duplicate and excessive classification is rejected without partial save',
    () async {
      final tag = await service.owner.createTag('合成标签');
      await expectLater(
        save('missing-directory', directory: 'absent'),
        access('invalid_credential_classification'),
      );
      await expectLater(
        save('missing-tag', tags: ['absent']),
        access('invalid_credential_classification'),
      );
      await expectLater(
        save('duplicate', tags: [tag.id, tag.id]),
        access('invalid_credential_classification'),
      );
      await expectLater(
        save('too-many', tags: List.generate(101, (i) => '$i')),
        access('invalid_credential_classification'),
      );
      expect(repo.managedCredentials, isEmpty);
      expect(repo.credentialMaterials, isEmpty);
    },
  );

  test(
    'both directory removal paths reject a directory occupied only by credentials',
    () async {
      final d = await service.owner.createDirectory('凭据专用目录');
      await save('create', directory: d.id);
      await expectLater(
        service.owner.deleteDirectory(d.id, d.version),
        access('directory_not_empty'),
      );
      final version =
          (await service.owner.informationClassificationSnapshot()).version;
      await expectLater(
        service.owner.changeInformationClassification(
          InformationClassificationCommand(
            operationId: 'delete',
            expectedVersion: version,
            kind: InformationClassificationKind.directory,
            action: InformationClassificationAction.delete,
            targetId: d.id,
          ),
        ),
        access('directory_not_empty'),
      );
      await expectLater(
        repo.commitOrganizationRemoval(directoryId: d.id, validate: () {}),
        access('directory_not_empty'),
      );
      expect(service.owner.directories.single.id, d.id);
    },
  );

  test(
    'tag preview counts both kinds and stale credential revision prevents deletion',
    () async {
      final tag = await service.owner.createTag('混合标签');
      final info = await service.owner.createInformation('合成信息', '', [
        const FieldInput('正文', '', '合成正文'),
      ]);
      await service.owner.organizeInformation(info.id, tagIds: [tag.id]);
      await save('create', tags: [tag.id]);
      final before = service.owner.credentials.single;
      final preview = await service.owner.previewInformationTagRemoval(tag.id);
      expect(preview.affectedCount, 2);
      await save('note-edit', old: before, classify: false);
      await expectLater(
        removeTag('stale', preview),
        access('organization_conflict'),
      );
      await expectLater(
        service.owner.deleteTag(tag.id, tag.version),
        access('organization_conflict'),
      );
      final fresh = await service.owner.previewInformationTagRemoval(tag.id);
      final receipt = await removeTag('delete-tag', fresh);
      expect(service.owner.tags, isEmpty);
      expect(service.owner.information.single.tagIds, isEmpty);
      expect(service.owner.credentials.single.tagIds, isEmpty);
      expect(service.owner.credentials.single.revision, 3);
      expect(service.owner.credentials.single.useGeneration, 1);
      expect(repo.credentialMaterials.single.bytes, utf8.encode(secret));
      await reopen();
      expect(service.owner.credentials.single.tagIds, isEmpty);
      expect(
        (await service.owner.informationClassificationReceipt(
          'delete-tag',
        ))!.toJson(),
        receipt.toJson(),
      );
      expect((await removeTag('delete-tag', fresh)).toJson(), receipt.toJson());
    },
  );

  test(
    'tag removal receipt failure rolls back credential, information and tag together',
    () async {
      final tag = await service.owner.createTag('合成标签');
      await save('create', tags: [tag.id]);
      final before = service.owner.credentials.single.toJson();
      final preview = await service.owner.previewInformationTagRemoval(tag.id);
      final db = inspect();
      try {
        db.execute(
          "CREATE TRIGGER fail_tag_receipt BEFORE INSERT ON information_classification_operations WHEN NEW.operation_id='failed' BEGIN SELECT RAISE(ABORT,'synthetic'); END",
        );
        await expectLater(removeTag('failed', preview), storage('save_failed'));
        expect(service.owner.credentials.single.toJson(), before);
        expect(service.owner.tags.single.id, tag.id);
        expect(
          await service.owner.informationClassificationReceipt('failed'),
          isNull,
        );
        expect(
          (await service.owner.previewInformationTagRemoval(tag.id)).token,
          preview.token,
        );
        db.execute('DROP TRIGGER fail_tag_receipt');
      } finally {
        db.close();
      }
      await reopen();
      expect(service.owner.credentials.single.toJson(), before);
    },
  );

  test(
    'actual SQL credential change rejects stale tag removal even with an unchanged cache',
    () async {
      final tag = await service.owner.createTag('合成标签');
      await save('create', tags: [tag.id]);
      final preview = await service.owner.previewInformationTagRemoval(tag.id);
      final old = service.owner.credentials.single;
      final changed = old.copy(name: '外部合成修改', modifiedAt: now);
      final db = inspect();
      try {
        db.execute('UPDATE managed_credentials SET payload=? WHERE id=?', [
          jsonEncode(changed.toJson()),
          old.id,
        ]);
      } finally {
        db.close();
      }
      await expectLater(
        removeTag('stale-sql', preview),
        access('organization_conflict'),
      );
      await reopen();
      expect(service.owner.credentials.single.name, changed.name);
      expect(service.owner.tags.single.id, tag.id);
    },
  );

  test(
    'format14 encrypted backup restores classification and refuses version downgrade or malformed references',
    () async {
      final d = await service.owner.createDirectory('合成目录');
      final t = await service.owner.createTag('合成标签');
      await save('create', directory: d.id, tags: [t.id]);
      final key = await enableTestBackups(repo.backups);
      final archive = '${root.path}/classified.aimbackup';
      await repo.backups.exportTo(archive);
      final preview = await repo.backups.inspect(archive, key);
      expect(preview.formatVersion, 14);
      final targetKeys = TestKeyStore();
      var target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        targetKeys,
        clock: () => now,
      );
      try {
        await target.backups.restore(preview);
      } finally {
        await target.close();
      }
      target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        targetKeys,
        clock: () => now,
      );
      try {
        final restored = target.managedCredentials.single;
        expect(restored.directoryId, d.id);
        expect(restored.tagIds, [t.id]);
        expect(restored.privateNote, note);
        expect(target.credentialMaterials.single.bytes, utf8.encode(secret));
        expect(await target.credentialRecordReceipt('create'), isNull);
      } finally {
        await target.close();
      }
      final cases = <String, void Function(Map<String, dynamic>)>{
        'downgrade': (j) => j['version'] = 13,
        'orphan-directory': (j) => j['directoryId'] = 'absent',
        'orphan-tag': (j) => j['tagIds'] = ['absent'],
        'duplicate-tags': (j) => j['tagIds'] = [t.id, t.id],
        'missing-pair': (j) => j.remove('tagIds'),
        'unknown-key': (j) => j['secretCopy'] = secret,
      };
      for (final entry in cases.entries) {
        final targetPath = '${root.path}/${entry.key}.aimbackup';
        await mutateBackup(archive, targetPath, key, (document) {
          if (entry.key == 'downgrade') {
            entry.value(document);
            return;
          }
          final row =
              (document['tables']['managed_credentials'] as List).single;
          final json =
              jsonDecode(row['payload'] as String) as Map<String, dynamic>;
          entry.value(json);
          row['payload'] = jsonEncode(json);
        });
        await expectLater(
          repo.backups.inspect(targetPath, key),
          storage('invalid_backup'),
        );
      }
    },
  );

  test(
    'recycled credential backup permits removed categories and restoration prunes only missing identities',
    () async {
      final d = await service.owner.createDirectory('将移除目录');
      final t = await service.owner.createTag('将移除标签');
      final keep = await service.owner.createTag('保留标签');
      await save('create', directory: d.id, tags: [t.id, keep.id]);
      final c = service.owner.credentials.single;
      await service.owner.deleteCredential(c.id, c.revision);
      await service.owner.deleteDirectory(d.id, d.version);
      await removeTag(
        'delete-tag',
        await service.owner.previewInformationTagRemoval(t.id),
      );
      final key = await enableTestBackups(repo.backups);
      final archive = '${root.path}/recycled.aimbackup';
      await repo.backups.exportTo(archive);
      expect((await repo.backups.inspect(archive, key)).formatVersion, 14);
      final restored = await service.owner.restoreCredential(c.id);
      expect(restored.directoryId, isNull);
      expect(restored.tagIds, [keep.id]);
      expect(restored.enabled, isFalse);
      expect(restored.version, 2);
      await reopen();
      expect(service.owner.credentials.single.tagIds, [keep.id]);
    },
  );

  test(
    'legacy unclassified JSON stays compatible and malformed classification pairs fail closed',
    () async {
      await save('legacy', classify: false);
      final json = service.owner.credentials.single.toJson();
      expect(json.containsKey('directoryId'), isFalse);
      expect(json.containsKey('tagIds'), isFalse);
      expect(ManagedCredential.fromJson(json).tagIds, isEmpty);
      expect(
        () => ManagedCredential.fromJson({...json, 'directoryId': 'orphan'}),
        throwsFormatException,
      );
      expect(
        () => ManagedCredential.fromJson({
          ...json,
          'directoryId': null,
          'tagIds': null,
        }),
        throwsFormatException,
      );
      final db = inspect();
      try {
        expect(db.select('PRAGMA user_version').single.values.single, 38);
      } finally {
        db.close();
      }
    },
  );
}
