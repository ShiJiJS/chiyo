import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  var now = DateTime.utc(2026, 10, 30);
  Future<int> catalog() async =>
      (await service.owner.informationClassificationSnapshot()).version;
  Database inspect() {
    final db = sqlite3.open('${root.path}/library.db');
    final hex = keys.key!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  Future<void> reopen() async {
    await service.close();
    await repo.close();
    repo = await EncryptedInformationRepository.open(
      root.path,
      keys,
      clock: () => now,
    );
    service = InformationService(repository: repo, clock: () => now);
  }

  Future<InformationItem> seed() => service.owner.createInformation(
    '合成资料',
    '',
    [const FieldInput('字段', '', 'private-original')],
  );
  setUp(() async {
    now = DateTime.utc(2026, 10, 30);
    root = await Directory.systemTemp.createTemp('lifecycle-operations-');
    keys = TestKeyStore();
    repo = await EncryptedInformationRepository.open(
      root.path,
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

  test(
    'delete and restore exact receipts survive later edits and reopen without duplicate restoration',
    () async {
      final item = await seed();
      final deletion = InformationLifecycleCommand(
        operationId: 'delete',
        itemId: item.id,
        action: InformationLifecycleAction.recycle,
        expectedVersion: 1,
      );
      final removed = await service.owner.changeInformationLifecycle(deletion);
      expect(repo.items, isEmpty);
      final restore = InformationLifecycleCommand(
        operationId: 'restore',
        itemId: item.id,
        action: InformationLifecycleAction.restoreRecycled,
        expectedVersion: removed.version,
        entryId: removed.entryId,
        expectedCatalogVersion: await catalog(),
      );
      final restored = await service.owner.changeInformationLifecycle(restore);
      final newField = repo.items.single.fields.single.id;
      expect(newField, isNot(item.fields.single.id));
      await service.owner.correctValue(
        FieldRef(item.id, newField),
        'private-updated',
      );
      await reopen();
      expect(
        (await service.owner.changeInformationLifecycle(deletion)).toJson(),
        removed.toJson(),
      );
      expect(
        (await service.owner.changeInformationLifecycle(restore)).toJson(),
        restored.toJson(),
      );
      expect(repo.items.single.fields.single.value, 'private-updated');
      expect(repo.items.single.fields.single.id, newField);
      expect(
        repo.recycleFacts.where((f) => f.kind == RecycleFactKind.restored),
        hasLength(1),
      );
      expect(jsonEncode(restored.toJson()), isNot(contains('private')));
      expect(
        InformationLifecycleReceipt.fromJson(restored.toJson()).toJson(),
        restored.toJson(),
      );
      await expectLater(
        service.owner.changeInformationLifecycle(
          InformationLifecycleCommand(
            operationId: 'delete',
            itemId: item.id,
            action: InformationLifecycleAction.recycle,
            expectedVersion: 4,
          ),
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'conflict',
            'operation_conflict',
          ),
        ),
      );
    },
  );

  test(
    'revision restoration has atomic original command and refuses stale classification',
    () async {
      final item = await seed();
      await service.owner.correctValue(
        FieldRef(item.id, item.fields.single.id),
        'private-new',
      );
      final stale = await catalog();
      await service.owner.createTag('新标签');
      await expectLater(
        service.owner.changeInformationLifecycle(
          InformationLifecycleCommand(
            operationId: 'stale',
            itemId: item.id,
            action: InformationLifecycleAction.restoreRevision,
            expectedVersion: 2,
            revisionVersion: 1,
            expectedCatalogVersion: stale,
          ),
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'stale',
            'organization_conflict',
          ),
        ),
      );
      final command = InformationLifecycleCommand(
        operationId: 'revision',
        itemId: item.id,
        action: InformationLifecycleAction.restoreRevision,
        expectedVersion: 2,
        revisionVersion: 1,
        expectedCatalogVersion: await catalog(),
      );
      final restored = await service.owner.changeInformationLifecycle(command);
      expect(repo.items.single.version, 3);
      expect(repo.items.single.fields.single.value, 'private-original');
      expect(repo.items.single.fields.single.id, item.fields.single.id);
      await service.owner.deleteInformation(item.id, 3);
      now = now.add(const Duration(days: 31));
      await service.owner.purgeRecycle();
      await service.owner.purgeRevisions();
      await reopen();
      expect(repo.items, isEmpty);
      expect(
        (await service.owner.changeInformationLifecycle(command)).toJson(),
        restored.toJson(),
      );
      expect(repo.items, isEmpty);
      expect(await service.owner.informationLifecycleReceipt('stale'), isNull);
    },
  );

  test(
    'partial restore verifies reviewed current version and keeps unrelated fields',
    () async {
      final item = await service.owner.createInformation('两字段', '', [
        const FieldInput('甲', '', 'one'),
        const FieldInput('乙', '', 'two'),
      ]);
      final entry = await service.owner.deleteInformation(
        item.id,
        1,
        fieldId: item.fields.first.id,
      );
      await service.owner.correctValue(
        FieldRef(item.id, item.fields.last.id),
        'updated-two',
      );
      final version = await catalog();
      InformationLifecycleCommand command(String op, int? current) =>
          InformationLifecycleCommand(
            operationId: op,
            itemId: item.id,
            action: InformationLifecycleAction.restoreRecycled,
            expectedVersion: entry.version,
            entryId: entry.id,
            expectedCatalogVersion: version,
            expectedCurrentVersion: current,
          );
      for (final expected in [null, 2]) {
        await expectLater(
          service.owner.changeInformationLifecycle(
            command('bad-$expected', expected),
          ),
          throwsA(isA<AccessFailure>()),
        );
      }
      final receipt = await service.owner.changeInformationLifecycle(
        command('restore', 3),
      );
      expect(receipt.version, 4);
      expect(repo.items.single.fields.map((f) => f.value), [
        'updated-two',
        'one',
      ]);
      expect(repo.items.single.fields.last.id, isNot(item.fields.first.id));
      expect(
        repo.recycleFacts.last.restoredFieldIds[item.fields.first.id],
        repo.items.single.fields.last.id,
      );
    },
  );

  test(
    'receipt failure rolls back item, revision, recycle facts and permits exact retry',
    () async {
      final item = await seed();
      final command = InformationLifecycleCommand(
        operationId: 'delete',
        itemId: item.id,
        action: InformationLifecycleAction.recycle,
        expectedVersion: 1,
      );
      final db = inspect();
      try {
        db.execute(
          "CREATE TRIGGER fail_receipt BEFORE INSERT ON information_lifecycle_operations BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
        );
        await expectLater(
          service.owner.changeInformationLifecycle(command),
          throwsA(isA<StorageFailure>()),
        );
        expect(repo.items.single.id, item.id);
        expect(repo.recycleEntries, isEmpty);
        expect(repo.recycleFacts, isEmpty);
        expect(repo.informationRevisions, isEmpty);
        expect(
          await service.owner.informationLifecycleReceipt('delete'),
          isNull,
        );
        db.execute('DROP TRIGGER fail_receipt');
      } finally {
        db.close();
      }
      await reopen();
      expect(repo.items.single.fields.single.value, 'private-original');
      await service.owner.changeInformationLifecycle(command);
      expect(repo.items, isEmpty);
      expect(repo.recycleEntries, hasLength(1));
      expect(repo.informationRevisions, hasLength(1));
    },
  );

  test(
    'expired entries cannot restore and transaction validation rolls back',
    () async {
      final item = await seed();
      final entry = await service.owner.deleteInformation(item.id, 1);
      now = now.add(const Duration(days: 31));
      await expectLater(
        service.owner.changeInformationLifecycle(
          InformationLifecycleCommand(
            operationId: 'expired',
            itemId: item.id,
            action: InformationLifecycleAction.restoreRecycled,
            expectedVersion: entry.version,
            entryId: entry.id,
            expectedCatalogVersion: await catalog(),
          ),
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        await service.owner.informationLifecycleReceipt('expired'),
        isNull,
      );
      final replacement = await seed();
      var calls = 0;
      await expectLater(
        repo.commitRecycleChange(
          itemId: replacement.id,
          entries: [],
          facts: [],
          validate: () {
            if (++calls == 2) throw const AccessFailure('library_changed');
          },
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(repo.items.single.id, replacement.id);
      await reopen();
      expect(repo.items.single.id, replacement.id);
    },
  );

  test(
    'backup excludes receipts and invalidates old results only on successful restore',
    () async {
      final item = await seed();
      await service.owner.correctValue(
        FieldRef(item.id, item.fields.single.id),
        'new',
      );
      await service.owner.changeInformationLifecycle(
        InformationLifecycleCommand(
          operationId: 'source-op',
          itemId: item.id,
          action: InformationLifecycleAction.restoreRevision,
          expectedVersion: 2,
          revisionVersion: 1,
          expectedCatalogVersion: await catalog(),
        ),
      );
      final recovery = await enableTestBackups(repo.backups);
      final path = '${root.path}/backup.aimbackup';
      await repo.backups.exportTo(path);
      final targetKeys = TestKeyStore();
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        targetKeys,
      );
      final db = sqlite3.open('${root.path}/target/library.db');
      db.execute(
        'PRAGMA key = "x\'${targetKeys.key!.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\'"',
      );
      final old = InformationLifecycleReceipt(
        command: InformationLifecycleCommand(
          operationId: 'old-op',
          itemId: 'previous-item',
          action: InformationLifecycleAction.recycle,
          expectedVersion: 1,
        ),
        version: 2,
        entryId: 'previous-entry',
      );
      try {
        // An otherwise empty target retains only a content-free prior operation.
        db.execute(
          'INSERT INTO information_lifecycle_operations(operation_id,payload) VALUES(?,?)',
          ['old-op', jsonEncode(old.toJson())],
        );
        expect(await target.backups.recipientEmpty(), isTrue);
        db.execute(
          "CREATE TRIGGER fail_restore BEFORE INSERT ON information_items BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
        );
        await expectLater(
          target.backups.restoreFrom(path, recovery),
          throwsA(isA<StorageFailure>()),
        );
        expect(
          (await target.informationLifecycleReceipt('old-op'))!.toJson(),
          old.toJson(),
        );
        db.execute('DROP TRIGGER fail_restore');
        await target.backups.restoreFrom(path, recovery);
        await expectLater(
          target.informationLifecycleReceipt('old-op'),
          throwsA(
            isA<AccessFailure>().having(
              (e) => e.status,
              'invalidated',
              'library_changed',
            ),
          ),
        );
        expect(await target.informationLifecycleReceipt('source-op'), isNull);
        expect(target.items.single.fields.single.value, 'private-original');
      } finally {
        db.close();
        await target.close();
      }
    },
  );

  test(
    'restoration drops missing relation identities while keeping live targets and original archives',
    () async {
      final removed = await seed();
      final retained = await seed();
      final refs = [
        InformationRelationRef('information', removed.id),
        InformationRelationRef('information', retained.id),
      ];
      final hosts = <InformationItem>[];
      for (final id in ['revision-host', 'recycle-host']) {
        final saved = await service.owner.saveInformationRecord(
          id,
          InformationDraftInput(
            name: id,
            description: '',
            layout: InformationDraftLayout(
              InformationLayout(
                typeId: 'generic',
                snapshot: {},
                fieldIds: {},
                relations: {'related': refs},
              ),
              ['body'],
            ),
            fields: [const InformationDraftField.text('正文', '', 'original')],
          ),
        );
        hosts.add(repo.items.singleWhere((i) => i.id == saved.itemId));
      }
      await service.owner.correctValue(
        FieldRef(hosts.first.id, hosts.first.fields.single.id),
        'changed',
      );
      final entry = await service.owner.deleteInformation(hosts.last.id, 1);
      await service.owner.deleteInformation(removed.id, 1);
      // The same public name must not stand in for the deleted target identity.
      final lookalike = await seed();
      expect(lookalike.name, removed.name);
      final preview = service.owner.previewRevision(hosts.first.id, 1, 2);
      expect(preview.revision.item.layout!.relations['related'], refs);
      expect(preview.restored.layout!.relations['related'], [refs.last]);
      await service.owner.changeInformationLifecycle(
        InformationLifecycleCommand(
          operationId: 'revision-restore',
          itemId: hosts.first.id,
          action: InformationLifecycleAction.restoreRevision,
          expectedVersion: 2,
          revisionVersion: 1,
          expectedCatalogVersion: await catalog(),
        ),
      );
      await service.owner.changeInformationLifecycle(
        InformationLifecycleCommand(
          operationId: 'recycle-restore',
          itemId: hosts.last.id,
          action: InformationLifecycleAction.restoreRecycled,
          expectedVersion: entry.version,
          entryId: entry.id,
          expectedCatalogVersion: await catalog(),
        ),
      );
      await reopen();
      for (final host in hosts) {
        expect(
          repo.items
              .singleWhere((i) => i.id == host.id)
              .layout!
              .relations['related'],
          [refs.last],
        );
        expect(
          repo.informationRevisions
              .firstWhere((r) => r.item.id == host.id && r.item.version == 1)
              .item
              .layout!
              .relations['related'],
          refs,
        );
      }
    },
  );

  for (final old in [30, 31]) {
    test(
      'format $old migration preserves records and accepts lifecycle receipts',
      () async {
        final item = await seed();
        await service.close();
        await repo.close();
        final db = inspect();
        try {
          db.execute('DROP TABLE information_lifecycle_operations');
          db.execute('UPDATE library_format SET version=$old');
          db.execute('PRAGMA user_version=$old');
        } finally {
          db.close();
        }
        repo = await EncryptedInformationRepository.open(root.path, keys);
        service = InformationService(repository: repo);
        expect(repo.items.single.id, item.id);
        final check = inspect();
        try {
          expect(
            check.select('PRAGMA user_version').single.values.single,
            old == 30 ? 36 : 37,
          );
        } finally {
          check.close();
        }
        await service.owner.changeInformationLifecycle(
          InformationLifecycleCommand(
            operationId: 'after-migration',
            itemId: item.id,
            action: InformationLifecycleAction.recycle,
            expectedVersion: 1,
          ),
        );
        await reopen();
        expect(
          await service.owner.informationLifecycleReceipt('after-migration'),
          isNotNull,
        );
      },
    );
  }
}
