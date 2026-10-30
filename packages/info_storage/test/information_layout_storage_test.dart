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
  final now = DateTime.utc(2026, 10, 30);
  final slots = [
    'education/e1/title',
    'education/e1/period',
    'education/e1/detail',
  ];
  InformationLayout layout() => InformationLayout(
    typeId: 'profile',
    snapshot: {
      'definition': {
        'id': 'profile',
        'version': '1',
        'fields': [
          {'key': 'education', 'type': 'entries', 'label': '教育经历'},
        ],
      },
      'entries': {
        'education': ['e1'],
      },
      'ownerOnly': 'synthetic-layout-only',
    },
    fieldIds: {},
    relations: {
      'related': [InformationRelationRef('information', 'missing-target')],
    },
  );
  Future<InformationItem> create() async {
    await service.owner.saveInformationRecord(
      'create',
      InformationDraftInput(
        name: '合成档案',
        description: '',
        layout: InformationDraftLayout(layout(), slots),
        fields: const [
          InformationDraftField.text('经历名称', '', '合成大学'),
          InformationDraftField.text('经历时间', '', '2020–2024'),
          InformationDraftField.text('经历说明', '', 'synthetic-private-detail'),
        ],
      ),
    );
    return repo.items.single;
  }

  Future<void> reopen() async {
    await service.close();
    await repo.close();
    repo = await EncryptedInformationRepository.open(
      '${root.path}/source',
      keys,
    );
    service = InformationService(repository: repo, clock: () => now);
  }

  Database inspect() {
    final db = sqlite3.open('${root.path}/source/library.db');
    final hex = keys.key!
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('information-layout-');
    keys = TestKeyStore();
    repo = await EncryptedInformationRepository.open(
      '${root.path}/source',
      keys,
    );
    service = InformationService(repository: repo, clock: () => now);
  });
  tearDown(() async {
    await service.close();
    await repo.close();
    await root.delete(recursive: true);
  });

  test(
    'layout binds independent fields and remains owner-only after reopen',
    () async {
      final item = await create();
      expect(
        item.layout!.fieldIds.values.toSet(),
        item.fields.map((f) => f.id).toSet(),
      );
      expect(item.fields.every((f) => !slots.contains(f.id)), isTrue);
      expect(
        jsonEncode(item.layout!.toJson()),
        isNot(contains('synthetic-private-detail')),
      );
      await reopen();
      expect(repo.items.single.layout!.toJson(), item.layout!.toJson());
      final public = jsonEncode(service.agent.catalog());
      expect(public, isNot(contains('synthetic-layout-only')));
      expect(public, isNot(contains('missing-target')));
      expect(public, isNot(contains('synthetic-private-detail')));
      final session = service.agent.openSession('合成聊天');
      final selected = FieldRef(item.id, item.fields.first.id);
      final request = service.agent.request(session, '仅读取经历名称', [selected]);
      service.owner.approve(request.id, [selected]);
      final token = service.agent.claim(session, request.id).token;
      expect(await service.agent.read(token, selected), '合成大学');
      await expectLater(
        service.agent.read(token, FieldRef(item.id, item.fields.last.id)),
        throwsA(isA<AccessFailure>()),
      );
    },
  );

  test(
    'value edits and organization preserve layout; partial restore remaps only recovered identity',
    () async {
      final original = await create();
      await service.owner.correctValue(
        FieldRef(original.id, original.fields.first.id),
        '修正名称',
      );
      final corrected = repo.items.single;
      expect(corrected.layout!.toJson(), original.layout!.toJson());
      final organized = await service.owner.organizeInformation(
        original.id,
        expectedVersion: corrected.version,
      );
      expect(organized.layout!.toJson(), original.layout!.toJson());
      final entry = await service.owner.deleteInformation(
        original.id,
        organized.version,
        fieldId: original.fields.last.id,
      );
      final restored = await service.owner.restoreRecycled(entry.id);
      expect(restored.layout!.fieldIds[slots.first], original.fields.first.id);
      expect(
        restored.layout!.fieldIds[slots.last],
        isNot(original.fields.last.id),
      );
      expect(
        restored.fields
            .singleWhere((f) => f.id == restored.layout!.fieldIds[slots.last])
            .value,
        'synthetic-private-detail',
      );
      final history = service.owner.previewRevision(
        original.id,
        1,
        restored.version,
      );
      expect(
        history.restored.layout!.fieldIds[slots.last],
        restored.layout!.fieldIds[slots.last],
      );
      await reopen();
      expect(repo.items.single.layout!.toJson(), restored.layout!.toJson());
      expect(
        repo.informationRevisions.first.item.layout!.toJson(),
        original.layout!.toJson(),
      );
    },
  );

  test(
    'format12 exports and restores layout and historical snapshots without granting access',
    () async {
      final original = await create();
      await service.owner.correctValue(
        FieldRef(original.id, original.fields.first.id),
        '修正名称',
      );
      final recovery = await enableTestBackups(repo.backups);
      final file = '${root.path}/layout.aimbackup';
      await repo.backups.exportTo(file);
      final contents = await repo.backups.inspect(file, recovery);
      expect(contents.formatVersion, 12);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        TestKeyStore(),
      );
      try {
        await target.backups.restoreFrom(file, recovery);
        expect(target.items.single.layout!.toJson(), original.layout!.toJson());
        expect(
          target.informationRevisions.first.item.layout!.toJson(),
          original.layout!.toJson(),
        );
        expect(await target.informationRecordReceipt('create'), isNull);
        final targetService = InformationService(repository: target);
        try {
          expect(targetService.owner.requests, isEmpty);
        } finally {
          await targetService.close();
        }
      } finally {
        await target.close();
      }
    },
  );

  test(
    'layout only in recycle still selects format12 and can be restored',
    () async {
      final original = await create();
      final entry = await service.owner.deleteInformation(
        original.id,
        original.version,
      );
      final recovery = await enableTestBackups(repo.backups);
      final file = '${root.path}/deleted.aimbackup';
      await repo.backups.exportTo(file);
      expect((await repo.backups.inspect(file, recovery)).formatVersion, 12);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        TestKeyStore(),
      );
      try {
        await target.backups.restoreFrom(file, recovery);
        final targetService = InformationService(repository: target);
        try {
          final restored = await targetService.owner.restoreRecycled(entry.id);
          expect(restored.layout!.snapshot, original.layout!.snapshot);
          expect(
            restored.layout!.fieldIds.values.toSet(),
            restored.fields.map((f) => f.id).toSet(),
          );
          expect(
            restored.fields
                .map((f) => f.id)
                .toSet()
                .intersection(original.fields.map((f) => f.id).toSet()),
            isEmpty,
          );
        } finally {
          await targetService.close();
        }
      } finally {
        await target.close();
      }
    },
  );

  test(
    'layout transaction failure preserves data receipt and previous snapshot',
    () async {
      final original = await create();
      final db = inspect();
      try {
        db.execute(
          "CREATE TRIGGER refuse_layout BEFORE UPDATE OF layout_json ON information_items BEGIN SELECT RAISE(ABORT,'synthetic layout failure'); END",
        );
        await expectLater(
          service.owner.saveInformationRecord(
            'edit',
            InformationDraftInput(
              itemId: original.id,
              baseVersion: 1,
              name: '更改',
              description: '',
              layout: InformationDraftLayout(layout(), slots),
              fields: [
                for (final f in original.fields)
                  InformationDraftField.text(
                    f.name,
                    f.description,
                    'changed',
                    fieldId: f.id,
                  ),
              ],
            ),
          ),
          throwsA(isA<StorageFailure>()),
        );
        expect(repo.items.single.version, 1);
        expect(repo.informationRevisions, isEmpty);
        expect(await service.owner.informationRecordReceipt('edit'), isNull);
        db.execute('DROP TRIGGER refuse_layout');
      } finally {
        db.close();
      }
      await reopen();
      expect(repo.items.single.layout!.toJson(), original.layout!.toJson());
      expect(repo.items.single.fields.last.value, 'synthetic-private-detail');
    },
  );

  for (final old in [24, 25]) {
    test(
      'format$old upgrades empty layout column without rewriting ordinary fields',
      () async {
        final item = await service.owner.createInformation('旧资料', '', [
          const FieldInput('字段', '', '旧内容'),
        ]);
        await service.close();
        await repo.close();
        final db = inspect();
        try {
          db.execute('ALTER TABLE information_items DROP COLUMN layout_json');
          db.execute('UPDATE library_format SET version=$old');
          db.execute('PRAGMA user_version=$old');
        } finally {
          db.close();
        }
        repo = await EncryptedInformationRepository.open(
          '${root.path}/source',
          keys,
        );
        service = InformationService(repository: repo, clock: () => now);
        expect(repo.items.single.id, item.id);
        expect(repo.items.single.layout, isNull);
        final check = inspect();
        try {
          expect(
            check.select('PRAGMA user_version').single.values.single,
            old == 24 ? 32 : 33,
          );
        } finally {
          check.close();
        }
      },
    );
  }
}
