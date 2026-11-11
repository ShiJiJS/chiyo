import 'dart:convert';
import 'dart:io';
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

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  late DateTime now;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('formal-file-storage-');
    keys = _Keys();
    now = DateTime.utc(2026, 10, 19);
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
  sqlite.Database inspect([String? directory, _Keys? ownKeys]) {
    final db = sqlite.sqlite3.open(
      '${directory ?? '${root.path}/source'}/library.db',
    );
    final hex = (ownKeys ?? keys).key!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  test(
    'file libraries reject a1001st template before committing unbackable rows',
    () async {
      await service.owner.createTemplate('File template', '', [
        const TemplateFieldInput('Document', '', kind: FieldKind.file),
      ]);
      final db = inspect();
      try {
        db.execute('BEGIN');
        for (var i = 1; i < 1000; i++) {
          db.execute(
            'INSERT INTO field_templates(id,name,description,version,fields_json) VALUES(?,?,?,?,?)',
            [
              'template-$i',
              'Template$i',
              '',
              1,
              jsonEncode([
                {
                  'id': 'definition-$i',
                  'name': 'Document',
                  'description': '',
                  'kind': 'file',
                },
              ]),
            ],
          );
        }
        db.execute('COMMIT');
        await expectLater(
          service.owner.createTemplate('Over limit', '', [
            const TemplateFieldInput('Document', '', kind: FieldKind.file),
          ]),
          throwsA(isA<StorageFailure>()),
        );
        expect(
          db.select('SELECT count(*) AS n FROM field_templates').single['n'],
          1000,
        );
        expect(repo.templates, hasLength(1));
        final key = await enableTestBackups(repo.backups);
        final path = '${root.path}/template-limit.aimbackup';
        await repo.backups.exportTo(path);
        expect((await repo.backups.inspect(path, key)).templateCount, 1000);
      } finally {
        db.close();
      }
    },
  );

  test(
    'file libraries reject history beyond the shared500000 nested fact ceiling',
    () async {
      await service.owner.createTemplate('File template', '', [
        const TemplateFieldInput('Document', '', kind: FieldKind.file),
      ]);
      GrantHistory history(String id, List<RecordedField> fields) =>
          GrantHistory(
            id: id,
            requestId: 'request-$id',
            sessionId: 'historical',
            chatLabel: 'Historical',
            approvedAt: now,
            expiresAt: now.add(const Duration(hours: 8)),
            fields: fields,
            events: [GrantEvent(GrantEventKind.approved, now)],
          );
      final fields = [
        for (var i = 0; i < 200; i++) RecordedField('i', 'f$i', 'I', 'F'),
      ];
      final db = inspect();
      try {
        db.execute('BEGIN');
        for (var i = 0; i < 2500; i++) {
          final record = history('grant-$i', fields);
          db.execute(
            'INSERT INTO grant_history(id,approved_at,payload) VALUES(?,?,?)',
            [
              record.id,
              now.millisecondsSinceEpoch,
              jsonEncode(record.toJson()),
            ],
          );
        }
        db.execute('COMMIT');
        final key = await enableTestBackups(repo.backups);
        final path = '${root.path}/nested-limit.aimbackup';
        await repo.backups.exportTo(path);
        expect((await repo.backups.inspect(path, key)).grantHistoryCount, 2500);
        final recipient = await EncryptedInformationRepository.open(
          '${root.path}/nested-recipient',
          _Keys(),
          clock: () => now,
        );
        addTearDown(recipient.close);
        await recipient.backups.restoreFrom(path, key);
        expect(recipient.grantHistory, hasLength(2500));
        expect(
          recipient.grantHistory.fold<int>(0, (n, g) => n + g.fields.length),
          500000,
        );
        expect(recipient.grantHistory.every((g) => !g.active), isTrue);
        await expectLater(
          repo.saveGrantHistory(history('over-limit', [fields.first])),
          throwsA(isA<StorageFailure>()),
        );
        expect(
          db.select('SELECT count(*) AS n FROM grant_history').single['n'],
          2500,
        );
        expect(repo.grantHistory, isEmpty);
      } finally {
        db.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'file libraries reserve future purge fact slots and never publish an oversized legacy retention result',
    () async {
      await service.owner.createTemplate('File template', '', [
        const TemplateFieldInput('Document', '', kind: FieldKind.file),
      ]);
      final item = await service.owner.createInformation('Current', '', [
        const FieldInput('Value', '', 'Synthetic'),
      ]);
      final db = inspect();
      try {
        db.execute('BEGIN');
        for (var i = 0; i < 199999; i++) {
          final fact = RecycleFact(
            'old-$i',
            'historical',
            const [],
            1,
            RecycleFactKind.purged,
            now,
          );
          db.execute('INSERT INTO recycle_facts(payload) VALUES(?)', [
            jsonEncode(fact.toJson()),
          ]);
        }
        db.execute('COMMIT');
        // The immediate deletion would fit200000 facts, but its later purge
        // needs one additional fact. Reject before changing the current item.
        await expectLater(
          service.owner.deleteInformation(item.id, item.version),
          throwsA(isA<StorageFailure>()),
        );
        expect(repo.items.single.id, item.id);
        expect(repo.recycleEntries, isEmpty);
        expect(
          db.select('SELECT count(*) AS n FROM recycle_facts').single['n'],
          199999,
        );

        // Represent an old library created before those reservations existed.
        final entry = RecycleEntry(
          id: 'legacy-entry',
          itemId: item.id,
          wholeItem: true,
          deletedAt: now,
          expiresAt: now.add(const Duration(days: 30)),
          version: 2,
          snapshot: item,
        );
        final fact = RecycleFact(
          entry.id,
          item.id,
          item.fields.map((f) => f.id),
          2,
          RecycleFactKind.deleted,
          now,
        );
        db.execute('BEGIN');
        db.execute('INSERT INTO recycle_entries(id,payload) VALUES(?,?)', [
          entry.id,
          jsonEncode(entry.toJson()),
        ]);
        db.execute('INSERT INTO recycle_facts(payload) VALUES(?)', [
          jsonEncode(fact.toJson()),
        ]);
        db.execute('DELETE FROM information_fields WHERE item_id=?', [item.id]);
        db.execute('DELETE FROM information_items WHERE id=?', [item.id]);
        db.execute('COMMIT');
        now = now.add(const Duration(days: 31));
        await enableTestBackups(repo.backups);
        final output = '${root.path}/must-not-publish.aimbackup';
        await expectLater(
          repo.backups.exportTo(output),
          throwsA(
            isA<StorageFailure>().having(
              (e) => e.code,
              'code',
              'backup_capacity_exceeded',
            ),
          ),
        );
        expect(await File(output).exists(), isFalse);
        expect(
          db.select('SELECT count(*) AS n FROM recycle_facts').single['n'],
          200000,
        );
      } finally {
        db.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  Future<InformationFileStage> stage(
    InformationFileDraft draft,
    List<int> bytes,
  ) async {
    final file = File('${root.path}/虚构 resume.pdf');
    await file.writeAsBytes(bytes);
    return service.owner.stageInformationFile(
      draft,
      file.path,
      mediaType: 'application/pdf',
    );
  }

  InformationDraftInput input(
    List<InformationDraftField> fields, [
    InformationItem? old,
  ]) => InformationDraftInput(
    name: '求职资料',
    description: '公开说明',
    fields: fields,
    itemId: old?.id,
    baseVersion: old?.version,
  );
  Future<InformationItem> create([List<int> bytes = const [0, 255, 42]]) async {
    final draft = await service.owner.beginInformationFileDraft();
    final s = await stage(draft, bytes);
    return service.owner.commitInformationDraft(
      draft,
      'create',
      input([
        const InformationDraftField.text('姓名', '', '虚构姓名'),
        InformationDraftField.stagedFile('简历', '', s.id),
      ]),
    );
  }

  Future<InformationItem> replace(InformationItem old, List<int> bytes) async {
    final draft = await service.owner.beginInformationFileDraft();
    final s = await stage(draft, bytes);
    return service.owner.commitInformationDraft(
      draft,
      'replace',
      input([
        InformationDraftField.text(
          '姓名',
          '',
          '新姓名',
          fieldId: old.fields.first.id,
        ),
        InformationDraftField.stagedFile(
          '简历',
          '',
          s.id,
          fieldId: old.fields.last.id,
        ),
      ], old),
    );
  }

  void mutateBackup(
    String path,
    String key,
    void Function(Map<String, dynamic>) change,
  ) {
    final db = sqlite.sqlite3.open(path);
    try {
      final hex = base64Url
          .decode(key.substring('aim-recovery-v1:'.length))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      final doc =
          jsonDecode(
                db
                        .select('SELECT payload FROM backup_snapshot')
                        .single['payload']
                    as String,
              )
              as Map<String, dynamic>;
      change(doc);
      db.execute('UPDATE backup_snapshot SET payload=?', [jsonEncode(doc)]);
    } finally {
      db.close();
    }
  }

  test(
    'formal transaction stores encrypted BLOBs and side refs without a body in item snapshots',
    () async {
      final original = [
        0,
        255,
        ...utf8.encode('SYNTHETIC-PRIVATE-FORMAL-12853'),
      ];
      final item = await create(original);
      final ref = item.fields.last.attachment!;
      expect(
        await repo.readInformationAttachmentChunk(ref, 0, original.length),
        original,
      );
      final db = inspect();
      try {
        final row = db
            .select('SELECT * FROM information_attachment_versions')
            .single;
        expect(row['body'], original);
        expect(row['version'], 1);
        expect(
          db
              .select(
                'SELECT value FROM information_fields WHERE kind=\'file\'',
              )
              .single['value'],
          '',
        );
        expect(
          db
              .select('SELECT * FROM information_file_fields')
              .single['attachment_id'],
          ref.attachmentId,
        );
        expect(
          db
              .select('SELECT count(*) AS n FROM information_file_stages')
              .single['n'],
          0,
        );
        expect(db.select('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        db.close();
      }
      expect(jsonEncode(informationToJson(item)), isNot(contains(root.path)));
      for (final file in Directory(
        '${root.path}/source',
      ).listSync().whereType<File>()) {
        if (!file.path.endsWith('library.db') &&
            !file.path.endsWith('-wal') &&
            !file.path.endsWith('-journal') &&
            !file.path.endsWith('-shm')) {
          continue;
        }
        expect(
          latin1.decode(await file.readAsBytes()),
          isNot(contains('SYNTHETIC-PRIVATE-FORMAL-12853')),
        );
      }
    },
  );
  test(
    'failure after promotion rolls back item, BLOBs, revisions, receipt and stage consumption; same operation retries',
    () async {
      final old = await create();
      final draft = await service.owner.beginInformationFileDraft();
      final s = await stage(draft, [8, 9]);
      final form = input([
        InformationDraftField.stagedFile(
          '简历',
          '',
          s.id,
          fieldId: old.fields.last.id,
        ),
      ], old);
      var db = inspect();
      db.execute(
        "CREATE TRIGGER reject_receipt BEFORE INSERT ON information_draft_commits BEGIN SELECT RAISE(FAIL,'synthetic commit failure'); END",
      );
      db.close();
      await expectLater(
        service.owner.commitInformationDraft(draft, 'retry', form),
        throwsA(isA<StorageFailure>()),
      );
      expect(repo.items.single.version, 1);
      expect(repo.informationRevisions, isEmpty);
      expect((await repo.informationFileStagingUsage()).files, 1);
      db = inspect();
      try {
        expect(
          db
              .select(
                'SELECT count(*) AS n FROM information_attachment_versions',
              )
              .single['n'],
          1,
        );
        expect(
          db
              .select('SELECT count(*) AS n FROM information_revisions')
              .single['n'],
          0,
        );
        expect(
          db.select('SELECT count(*) AS n FROM recycle_entries').single['n'],
          0,
        );
        db.execute('DROP TRIGGER reject_receipt');
      } finally {
        db.close();
      }
      final saved = await service.owner.commitInformationDraft(
        draft,
        'retry',
        form,
      );
      expect(saved.version, 2);
      expect(saved.fields.single.attachment!.attachmentVersion, 2);
      await service.owner.commitInformationDraft(draft, 'retry', form);
      expect(repo.informationRevisions.length, 1);
      expect(repo.recycleEntries.length, 1);
      expect((await repo.informationFileStagingUsage()).files, 0);
    },
  );
  test(
    'tampered staged original fails digest verification without consuming it',
    () async {
      final draft = await service.owner.beginInformationFileDraft();
      final s = await stage(draft, [1, 2, 3]);
      final db = inspect();
      db.execute("UPDATE information_file_stages SET body=x'030201'");
      db.close();
      await expectLater(
        service.owner.commitInformationDraft(
          draft,
          'op',
          input([InformationDraftField.stagedFile('简历', '', s.id)]),
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'attachment_integrity_failed',
          ),
        ),
      );
      expect(repo.items, isEmpty);
      expect((await repo.informationFileStagingUsage()).files, 1);
    },
  );
  test(
    'reopen loads typed refs and revisions, keeps original bytes, and scrubs form receipts',
    () async {
      final first = await create();
      final second = await replace(first, [8, 7]);
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        keys,
        clock: () => now,
      );
      service = InformationService(repository: repo, clock: () => now);
      expect(
        repo.items.single.fields.last.attachment,
        second.fields.last.attachment,
      );
      expect(
        repo.informationRevisions.single.item.fields.last.attachment,
        first.fields.last.attachment,
      );
      expect(
        await repo.readInformationAttachmentChunk(
          first.fields.last.attachment!,
          0,
          3,
        ),
        [0, 255, 42],
      );
      final db = inspect();
      try {
        expect(db.select('SELECT * FROM information_draft_commits'), isEmpty);
      } finally {
        db.close();
      }
      await service.owner.correctValue(
        FieldRef(first.id, first.fields.first.id),
        '再次改名',
      );
      expect(
        repo.items.single.fields.last.attachment,
        second.fields.last.attachment,
      );
    },
  );
  test(
    'full format23 round trip restores current and revision originals under recipient key',
    () async {
      final old = await create();
      final current = await replace(old, [5, 4, 3, 2]);
      final key = await enableTestBackups(repo.backups);
      final path = '${root.path}/full.aimbackup';
      await repo.backups.exportTo(path);
      final targetKeys = _Keys();
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        targetKeys,
        clock: () => now,
      );
      addTearDown(target.close);
      final preview = await target.backups.inspect(path, key);
      expect(preview.formatVersion, 23);
      expect(preview.attachmentCount, 2);
      expect(preview.attachmentBytes, 7);
      expect(preview.revisionCount, 1);
      expect(preview.informationCount, 1);
      await target.backups.restore(preview);
      expect(
        target.items.single.fields.last.attachment,
        current.fields.last.attachment,
      );
      expect(
        await target.readInformationAttachmentChunk(
          old.fields.last.attachment!,
          0,
          3,
        ),
        [0, 255, 42],
      );
      expect(
        await target.readInformationAttachmentChunk(
          current.fields.last.attachment!,
          0,
          4,
        ),
        [5, 4, 3, 2],
      );
      expect(targetKeys.key, isNot(keys.key));
      final db = inspect('${root.path}/target', targetKeys);
      try {
        expect(db.select('PRAGMA foreign_key_check'), isEmpty);
        expect(db.select('SELECT * FROM information_draft_commits'), isEmpty);
      } finally {
        db.close();
      }
    },
  );
  test(
    'zero byte original round trip is distinct from missing content',
    () async {
      final item = await create([]);
      final key = await enableTestBackups(repo.backups);
      final path = '${root.path}/empty.aimbackup';
      await repo.backups.exportTo(path);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
        clock: () => now,
      );
      addTearDown(target.close);
      final contents = await target.backups.restoreFrom(path, key);
      expect(contents.attachmentCount, 1);
      expect(contents.attachmentBytes, 0);
      expect(
        await target.readInformationAttachmentChunk(
          item.fields.last.attachment!,
          0,
          0,
        ),
        isEmpty,
      );
    },
  );
  test(
    'source replacement after preview rejects changed data and leaves recipient empty',
    () async {
      final item = await create();
      final key = await enableTestBackups(repo.backups);
      final path = '${root.path}/selected.aimbackup';
      await repo.backups.exportTo(path);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
        clock: () => now,
      );
      addTearDown(target.close);
      final preview = await target.backups.inspect(path, key);
      await replace(item, [3, 2]);
      final changed = '${root.path}/changed.aimbackup';
      await repo.backups.exportTo(changed);
      await File(changed).copy(path);
      await expectLater(
        target.backups.restore(preview),
        throwsA(
          isA<StorageFailure>().having((e) => e.code, 'code', 'backup_changed'),
        ),
      );
      expect(target.items, isEmpty);
      expect(await target.backups.recipientEmpty(), isTrue);
    },
  );
  test(
    'restore write failure rolls back installed BLOBs and retains ephemeral owner draft',
    () async {
      await create();
      final key = await enableTestBackups(repo.backups);
      final path = '${root.path}/full.aimbackup';
      await repo.backups.exportTo(path);
      final targetKeys = _Keys();
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        targetKeys,
        clock: () => now,
      );
      addTearDown(target.close);
      final targetService = InformationService(
        repository: target,
        clock: () => now,
      );
      addTearDown(targetService.close);
      final draft = await targetService.owner.beginInformationFileDraft();
      await targetService.owner.stageInformationFile(
        draft,
        '${root.path}/虚构 resume.pdf',
      );
      expect(await target.backups.recipientEmpty(), isTrue);
      var db = inspect('${root.path}/target', targetKeys);
      db.execute(
        "CREATE TRIGGER fail_restore BEFORE INSERT ON information_fields BEGIN SELECT RAISE(FAIL,'synthetic restore failure'); END",
      );
      db.close();
      final preview = await target.backups.inspect(path, key);
      await expectLater(
        target.backups.restore(preview),
        throwsA(isA<StorageFailure>()),
      );
      expect(target.items, isEmpty);
      expect((await target.informationFileStagingUsage()).files, 1);
      db = inspect('${root.path}/target', targetKeys);
      try {
        expect(
          db.select('SELECT * FROM information_attachment_versions'),
          isEmpty,
        );
        db.execute('DROP TRIGGER fail_restore');
      } finally {
        db.close();
      }
      await targetService.owner.restoreLibrary(
        () => target.backups.restore(preview),
      );
      expect(target.items.length, 1);
      expect((await target.informationFileStagingUsage()).files, 0);
    },
  );
  test(
    'authenticated domain corruption in current, revision or side refs fails before restore',
    () async {
      final first = await create();
      await replace(first, [7]);
      final key = await enableTestBackups(repo.backups);
      final valid = '${root.path}/valid.aimbackup';
      await repo.backups.exportTo(valid);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
        clock: () => now,
      );
      addTearDown(target.close);
      for (final branch in [
        'dangling',
        'missing',
        'duplicate',
        'wrong-kind',
        'history',
      ]) {
        final path = '${root.path}/$branch.aimbackup';
        await File(valid).copy(path);
        mutateBackup(path, key, (doc) {
          final tables = doc['tables'] as Map<String, dynamic>;
          final links = tables['information_file_fields'] as List;
          switch (branch) {
            case 'dangling':
              links.single['attachment_version'] = 99;
            case 'missing':
              links.clear();
            case 'duplicate':
              links.add(Map.of(links.single as Map));
            case 'wrong-kind':
              (tables['information_fields'] as List).first['kind'] = 'file';
            case 'history':
              final row =
                  (tables['information_revisions'] as List).single as Map;
              final item = jsonDecode(row['payload'] as String) as Map;
              (item['fields'] as List).last['content']['attachmentVersion'] =
                  99;
              row['payload'] = jsonEncode(item);
          }
        });
        await expectLater(
          target.backups.restoreFrom(path, key),
          throwsA(isA<StorageFailure>()),
          reason: branch,
        );
        expect(await target.backups.recipientEmpty(), isTrue, reason: branch);
      }
    },
  );
  test(
    'schema19 migration preserves text and rejects schema20 table collision atomically',
    () async {
      await repo.save(
        InformationItem('i', '旧资料', '', 1, const [
          InformationField('f', '字段', '', '原内容', 1),
        ]),
      );
      await service.close();
      await repo.close();
      var db = inspect();
      for (final t in [
        'information_deliveries',
        'information_file_fields',
        'information_attachment_versions',
        'information_draft_commits',
      ]) {
        db.execute('DROP TABLE $t');
      }
      db.execute('UPDATE library_format SET version=19');
      db.execute('PRAGMA user_version=10');
      db.close();
      repo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        keys,
        clock: () => now,
      );
      service = InformationService(repository: repo, clock: () => now);
      expect(repo.items.single.fields.single.value, '原内容');
      await service.close();
      await repo.close();
      db = inspect();
      db.execute('DROP TABLE information_deliveries');
      db.execute('UPDATE library_format SET version=19');
      db.execute('PRAGMA user_version=10');
      db.close();
      await expectLater(
        EncryptedInformationRepository.open('${root.path}/source', keys),
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
        expect(db.select('PRAGMA user_version').single.values.single, 10);
        expect(
          db.select('SELECT version FROM library_format').single['version'],
          19,
        );
      } finally {
        db.close();
      }
    },
  );
}
