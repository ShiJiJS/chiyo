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
  Future<int> version() async =>
      (await service.owner.informationClassificationSnapshot()).version;
  Future<InformationClassificationReceipt> change(
    String op,
    InformationClassificationKind kind,
    InformationClassificationAction action, {
    String? id,
    String name = '',
    String? parent,
    int? expected,
    String? token,
  }) async => service.owner.changeInformationClassification(
    InformationClassificationCommand(
      operationId: op,
      expectedVersion: expected ?? await version(),
      kind: kind,
      action: action,
      targetId: id,
      name: name,
      parentId: parent,
      removalToken: token,
    ),
  );
  const directory = InformationClassificationKind.directory,
      tag = InformationClassificationKind.tag;
  const create = InformationClassificationAction.create,
      update = InformationClassificationAction.update,
      delete = InformationClassificationAction.delete;
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
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = InformationService(repository: repo);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('classification-operations-');
    keys = TestKeyStore();
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = InformationService(repository: repo);
  });
  tearDown(() async {
    await service.close();
    await repo.close();
    await root.delete(recursive: true);
  });

  test(
    'create move rename delete and exact original receipts survive reopen',
    () async {
      final firstVersion = await version();
      final original = await change('parent', directory, create, name: '原目录');
      final child = await change(
        'child',
        directory,
        create,
        name: '子目录',
        parent: original.targetId,
      );
      await expectLater(
        change('nonempty', directory, delete, id: original.targetId),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'not empty',
            'directory_not_empty',
          ),
        ),
      );
      await change('move', directory, update, id: child.targetId, name: '已移出');
      await change(
        'rename',
        directory,
        update,
        id: original.targetId,
        name: '新目录',
      );
      await change('delete', directory, delete, id: original.targetId);
      await reopen();
      expect(repo.directories.single.id, child.targetId);
      expect(repo.directories.single.parentId, isNull);
      final receipt = (await service.owner.informationClassificationReceipt(
        'parent',
      ))!;
      expect(receipt.toJson(), original.toJson());
      expect(receipt.directory!.name, '原目录');
      final same = await change(
        'parent',
        directory,
        create,
        name: '原目录',
        expected: firstVersion,
      );
      expect(same.toJson(), receipt.toJson());
      expect(repo.directories, hasLength(1));
      await expectLater(
        change('parent', directory, create, name: '不同', expected: firstVersion),
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
    'legacy writes advance the catalog version and stale cycles and duplicates reject',
    () async {
      final stale = await version();
      final legacy = await service.owner.createDirectory('原入口');
      expect(await version(), greaterThan(stale));
      await expectLater(
        change('stale', directory, create, name: '过时', expected: stale),
        throwsA(isA<AccessFailure>()),
      );
      final child = await change(
        'child',
        directory,
        create,
        name: '子目录',
        parent: legacy.id,
      );
      await expectLater(
        change(
          'cycle',
          directory,
          update,
          id: legacy.id,
          name: '原入口',
          parent: child.targetId,
        ),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        change('duplicate', directory, create, name: '原入口'),
        throwsA(isA<AccessFailure>()),
      );
      expect(repo.directories, hasLength(2));
      expect(
        await service.owner.informationClassificationReceipt('cycle'),
        isNull,
      );
    },
  );

  test(
    'tag removal rechecks reviewed records and retains body identity and history',
    () async {
      final receipt = await change('tag', tag, create, name: '标签');
      final item = await service.owner.createInformation(
        '合成资料',
        '',
        [const FieldInput('字段', '', 'private-body')],
        tagIds: [receipt.targetId],
      );
      final oldPreview = await service.owner.previewInformationTagRemoval(
        receipt.targetId,
      );
      await service.owner.correctValue(
        FieldRef(item.id, item.fields.single.id),
        'updated-private-body',
      );
      await expectLater(
        change(
          'old-review',
          tag,
          delete,
          id: receipt.targetId,
          token: oldPreview.token,
        ),
        throwsA(isA<AccessFailure>()),
      );
      final preview = await service.owner.previewInformationTagRemoval(
        receipt.targetId,
      );
      expect(preview.affectedCount, 1);
      final before = repo.items.single;
      final removed = await change(
        'remove-tag',
        tag,
        delete,
        id: receipt.targetId,
        token: preview.token,
      );
      expect(removed.tag, isNull);
      expect(repo.tags, isEmpty);
      expect(repo.items.single.tagIds, isEmpty);
      expect(repo.items.single.fields.single.id, before.fields.single.id);
      expect(repo.items.single.fields.single.value, before.fields.single.value);
      expect(repo.informationRevisions.last.item.tagIds, [receipt.targetId]);
      expect(jsonEncode(removed.toJson()), isNot(contains('private-body')));
      await reopen();
      expect(repo.items.single.tagIds, isEmpty);
      expect(
        (await service.owner.informationClassificationReceipt(
          'remove-tag',
        ))!.toJson(),
        removed.toJson(),
      );
    },
  );

  test(
    'receipt failure rolls back classification version relationships and revisions',
    () async {
      final tagReceipt = await change('tag', tag, create, name: '保留标签');
      final item = await service.owner.createInformation(
        '资料',
        '',
        [const FieldInput('字段', '', 'private')],
        tagIds: [tagReceipt.targetId],
      );
      final preview = await service.owner.previewInformationTagRemoval(
        tagReceipt.targetId,
      );
      final db = inspect();
      try {
        db.execute(
          "CREATE TRIGGER reject_classification BEFORE INSERT ON information_classification_operations BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
        );
        await expectLater(
          change(
            'delete',
            tag,
            delete,
            id: tagReceipt.targetId,
            token: preview.token,
          ),
          throwsA(isA<StorageFailure>()),
        );
        expect(await version(), preview.version);
        expect(repo.tags.single.id, tagReceipt.targetId);
        expect(repo.items.single.version, item.version);
        expect(repo.informationRevisions, isEmpty);
        expect(
          await service.owner.informationClassificationReceipt('delete'),
          isNull,
        );
        db.execute('DROP TRIGGER reject_classification');
      } finally {
        db.close();
      }
      await reopen();
      expect(repo.items.single.tagIds, [tagReceipt.targetId]);
      await change(
        'delete',
        tag,
        delete,
        id: tagReceipt.targetId,
        token: preview.token,
      );
      expect(repo.tags, isEmpty);
    },
  );

  test(
    'backup excludes local receipts and restore invalidates them only after success',
    () async {
      await change('source-tag', tag, create, name: '来源标签');
      await service.owner.createInformation('来源', '', [
        const FieldInput('字段', '', 'body'),
      ]);
      final recovery = await enableTestBackups(repo.backups);
      final path = '${root.path}/source.aimbackup';
      await repo.backups.exportTo(path);
      final targetKeys = TestKeyStore();
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        targetKeys,
      );
      final targetService = InformationService(repository: target);
      try {
        final created = await targetService.owner
            .changeInformationClassification(
              const InformationClassificationCommand(
                operationId: 'old-create',
                expectedVersion: 1,
                kind: directory,
                action: create,
                name: '旧分类',
              ),
            );
        await targetService.owner.changeInformationClassification(
          InformationClassificationCommand(
            operationId: 'old-delete',
            expectedVersion: created.version,
            kind: directory,
            action: delete,
            targetId: created.targetId,
          ),
        );
        expect(await target.backups.recipientEmpty(), isTrue);
        final before = await target.informationClassificationVersion();
        final db = sqlite3.open('${root.path}/target/library.db');
        final hex = targetKeys.key!
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        db.execute('PRAGMA key = "x\'$hex\'"');
        try {
          db.execute(
            "CREATE TRIGGER fail_restore BEFORE INSERT ON information_items BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
          );
          await expectLater(
            target.backups.restoreFrom(path, recovery),
            throwsA(isA<StorageFailure>()),
          );
          expect(await target.informationClassificationVersion(), before);
          expect(
            (await target.informationClassificationReceipt(
              'old-create',
            ))!.toJson(),
            created.toJson(),
          );
          db.execute('DROP TRIGGER fail_restore');
        } finally {
          db.close();
        }
        await target.backups.restoreFrom(path, recovery);
        expect(
          await target.informationClassificationVersion(),
          greaterThan(before),
        );
        await expectLater(
          target.informationClassificationReceipt('old-create'),
          throwsA(
            isA<AccessFailure>().having(
              (e) => e.status,
              'invalidated',
              'library_changed',
            ),
          ),
        );
        expect(target.items.single.name, '来源');
        expect(target.tags.single.name, '来源标签');
        expect(
          await target.informationClassificationReceipt('source-tag'),
          isNull,
        );
      } finally {
        await targetService.close();
        await target.close();
      }
    },
  );

  for (final old in [28, 29]) {
    test(
      'format$old migrates existing classifications without changing identities',
      () async {
        final item = await service.owner.createDirectory('旧目录');
        await service.close();
        await repo.close();
        final db = inspect();
        try {
          for (final table in ['information_directories', 'information_tags']) {
            for (final op in ['insert', 'update', 'delete']) {
              db.execute('DROP TRIGGER ${table}_${op}_classification');
            }
          }
          db.execute('DROP TABLE information_classification_operations');
          db.execute('DROP TABLE information_classification_state');
          db.execute('UPDATE library_format SET version=$old');
          db.execute('PRAGMA user_version=$old');
        } finally {
          db.close();
        }
        repo = await EncryptedInformationRepository.open(root.path, keys);
        service = InformationService(repository: repo);
        expect(repo.directories.single.id, item.id);
        final check = inspect();
        try {
          expect(
            check.select('PRAGMA user_version').single.values.single,
            old == 28 ? 34 : 35,
          );
        } finally {
          check.close();
        }
        await change('rename', directory, update, id: item.id, name: '已改名');
        await reopen();
        expect(repo.directories.single.name, '已改名');
        expect(
          await service.owner.informationClassificationReceipt('rename'),
          isNotNull,
        );
      },
    );
  }
}
