import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  late Directory folder;
  late TestKeyStore keys;
  late EncryptedInformationRepository repository;
  late InformationService service;
  late DateTime now;
  InformationDraftInput input({String value = 'synthetic-private-value'}) =>
      InformationDraftInput(
        name: '合成资料',
        description: '公开说明',
        fields: [InformationDraftField.text('地址', '', value)],
      );
  Future<void> reopen() async {
    await service.close();
    await repository.close();
    repository = await EncryptedInformationRepository.open(folder.path, keys);
    service = InformationService(repository: repository, clock: () => now);
  }

  Database inspect() {
    final db = sqlite3.open('${folder.path}/library.db');
    final hex = keys.key!
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  setUp(() async {
    now = DateTime.utc(2026, 10, 30);
    folder = await Directory.systemTemp.createTemp('record-operations-');
    keys = TestKeyStore();
    repository = await EncryptedInformationRepository.open(folder.path, keys);
    service = InformationService(repository: repository, clock: () => now);
  });
  tearDown(() async {
    await service.close();
    await repository.close();
    await folder.delete(recursive: true);
  });

  test(
    'save receipt survives reopening without retaining a second body',
    () async {
      final first = await service.owner.saveInformationRecord(
        'save-1',
        input(),
      );
      final item = repository.items.single;
      await service.owner.correctValue(
        FieldRef(item.id, item.fields.single.id),
        'new-current-value',
      );
      await reopen();
      final recovered = await service.owner.informationRecordReceipt('save-1');
      expect(recovered!.toJson(), first.toJson());
      final repeated = await service.owner.saveInformationRecord(
        'save-1',
        input(),
      );
      expect(repeated.toJson(), first.toJson());
      expect(repository.items.single.version, 2);
      expect(repository.items.single.fields.single.value, 'new-current-value');
      final db = inspect();
      try {
        expect(
          db
              .select('SELECT payload FROM information_record_operations')
              .single['payload'],
          jsonEncode(first.toJson()),
        );
        expect(
          jsonEncode(first.toJson()),
          isNot(contains('synthetic-private-value')),
        );
        expect(
          db
              .select('SELECT count(*) AS n FROM information_draft_commits')
              .single['n'],
          0,
        );
      } finally {
        db.close();
      }
      expect(
        await service.owner.informationRecordReceipt('never-submitted'),
        isNull,
      );
    },
  );

  test(
    'same operation with different input never overwrites or creates',
    () async {
      await service.owner.saveInformationRecord('save-1', input());
      await reopen();
      await expectLater(
        service.owner.saveInformationRecord(
          'save-1',
          input(value: 'different'),
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'operation_conflict',
          ),
        ),
      );
      expect(repository.items, hasLength(1));
      expect(repository.items.single.version, 1);
    },
  );

  InformationDraftInput commandInput({
    String typeId = 'document',
    String? digest,
  }) => InformationDraftInput(
    name: '合成文档',
    description: '',
    fields: const [
      InformationDraftField.text('正文', '', 'private-command-body'),
    ],
    layout: InformationDraftLayout(
      InformationLayout(typeId: 'document', snapshot: {}, fieldIds: {}),
      ['body'],
    ),
    command: InformationRecordCommand(
      typeId: typeId,
      digest: digest ?? 'a' * 64,
    ),
  );

  test(
    'original command metadata is atomic, content-free and excluded from backups',
    () async {
      final db = inspect();
      try {
        db.execute(
          "CREATE TRIGGER reject_command BEFORE INSERT ON information_record_operations BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
        );
        await expectLater(
          service.owner.saveInformationRecord('command', commandInput()),
          throwsA(isA<StorageFailure>()),
        );
        expect(repository.items, isEmpty);
        expect(await service.owner.informationRecordReceipt('command'), isNull);
        db.execute('DROP TRIGGER reject_command');
      } finally {
        db.close();
      }
      final receipt = await service.owner.saveInformationRecord(
        'command',
        commandInput(),
      );
      await reopen();
      final recovered = (await service.owner.informationRecordReceipt(
        'command',
      ))!;
      expect(recovered.command!.toJson(), receipt.command!.toJson());
      expect(
        jsonEncode(recovered.toJson()),
        isNot(contains('private-command-body')),
      );
      await expectLater(
        service.owner.saveInformationRecord(
          'command',
          commandInput(digest: 'b' * 64),
        ),
        throwsA(
          isA<AccessFailure>().having(
            (f) => f.status,
            'conflict',
            'operation_conflict',
          ),
        ),
      );
      final recovery = await enableTestBackups(repository.backups);
      final path = '${folder.path}/command.aimbackup';
      await repository.backups.exportTo(path);
      final target = await EncryptedInformationRepository.open(
        '${folder.path}/target',
        TestKeyStore(),
      );
      try {
        await target.backups.restoreFrom(path, recovery);
        expect(target.items.single.fields.single.value, 'private-command-body');
        expect(await target.informationRecordReceipt('command'), isNull);
      } finally {
        await target.close();
      }
    },
  );

  test(
    'command identity cannot claim another type or retain an arbitrary payload',
    () async {
      await expectLater(
        service.owner.saveInformationRecord(
          'wrong-type',
          commandInput(typeId: 'other'),
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(repository.items, isEmpty);
      expect(
        () => InformationRecordCommand.fromJson({
          'typeId': 'document',
          'digest': 'a' * 64,
          'body': 'not allowed',
        }),
        throwsFormatException,
      );
      expect(
        () => InformationRecordCommand(
          typeId: 'document',
          digest: 'not a digest',
        ),
        throwsFormatException,
      );
    },
  );

  for (final old in [26, 27]) {
    test(
      'format$old upgrades while preserving old receipts and portable format identity',
      () async {
        final receipt = await service.owner.saveInformationRecord(
          'old',
          input(),
        );
        await service.close();
        await repository.close();
        final db = inspect();
        try {
          db.execute('UPDATE library_format SET version=$old');
          db.execute('PRAGMA user_version=$old');
        } finally {
          db.close();
        }
        repository = await EncryptedInformationRepository.open(
          folder.path,
          keys,
        );
        service = InformationService(repository: repository, clock: () => now);
        expect(
          (await service.owner.informationRecordReceipt('old'))!.toJson(),
          receipt.toJson(),
        );
        final check = inspect();
        try {
          expect(
            check.select('PRAGMA user_version').single.values.single,
            old == 26 ? 32 : 33,
          );
          expect(
            check
                .select('SELECT version FROM library_format')
                .single
                .values
                .single,
            old == 26 ? 32 : 33,
          );
        } finally {
          check.close();
        }
        expect(
          (await service.owner.saveInformationRecord(
            'new',
            commandInput(),
          )).command!.typeId,
          'document',
        );
      },
    );
  }

  test('failed receipt write rolls back the item and can be retried', () async {
    final db = inspect();
    try {
      db.execute(
        "CREATE TRIGGER reject_receipt BEFORE INSERT ON information_record_operations BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
      );
      await expectLater(
        service.owner.saveInformationRecord('save-1', input()),
        throwsA(isA<StorageFailure>()),
      );
      expect(repository.items, isEmpty);
      expect(
        db.select('SELECT count(*) AS n FROM information_items').single['n'],
        0,
      );
      expect(await service.owner.informationRecordReceipt('save-1'), isNull);
      db.execute('DROP TRIGGER reject_receipt');
      await service.owner.saveInformationRecord('save-1', input());
      expect(repository.items, hasLength(1));
    } finally {
      db.close();
    }
  });

  test(
    'update preserves field identity, saves revision, rejects stale versions',
    () async {
      final first = await service.owner.saveInformationRecord(
        'create',
        input(),
      );
      final id = repository.items.single.fields.single.id;
      final edit = InformationDraftInput(
        itemId: first.itemId,
        baseVersion: 1,
        name: '修改后',
        description: '',
        fields: [InformationDraftField.text('地址', '', 'changed', fieldId: id)],
      );
      final saved = await service.owner.saveInformationRecord('edit', edit);
      expect(saved.version, 2);
      expect(saved.baseVersion, 1);
      expect(repository.items.single.fields.single.id, id);
      expect(repository.items.single.fields.single.version, 2);
      expect(repository.informationRevisions.single.item.version, 1);
      await expectLater(
        service.owner.saveInformationRecord('stale', edit),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'version_conflict',
          ),
        ),
      );
      expect(await service.owner.informationRecordReceipt('stale'), isNull);
      await reopen();
      expect(
        (await service.owner.saveInformationRecord('edit', edit)).toJson(),
        saved.toJson(),
      );
    },
  );

  test(
    'backup restores actual data but never imports operation acknowledgements',
    () async {
      await service.owner.saveInformationRecord('create', input());
      final recovery = await enableTestBackups(repository.backups);
      final backup = '${folder.path}/copy.aimbackup';
      await repository.backups.exportTo(backup);
      final target = await EncryptedInformationRepository.open(
        '${folder.path}/target',
        TestKeyStore(),
      );
      try {
        await target.backups.restoreFrom(backup, recovery);
        expect(
          target.items.single.fields.single.value,
          'synthetic-private-value',
        );
        expect(await target.informationRecordReceipt('create'), isNull);
      } finally {
        await target.close();
      }
    },
  );

  test(
    'deleted and purged data is not recreated by replaying a save',
    () async {
      final first = await service.owner.saveInformationRecord(
        'create',
        input(),
      );
      await service.owner.deleteInformation(first.itemId, first.version);
      now = now.add(const Duration(days: 400));
      await service.owner.purgeRecycle();
      await service.owner.purgeRevisions();
      await reopen();
      final result = await service.owner.saveInformationRecord(
        'create',
        input(),
      );
      expect(result.toJson(), first.toJson());
      expect(repository.items, isEmpty);
      expect(repository.informationRevisions, isEmpty);
      expect(
        repository.recycleEntries.every((entry) => entry.snapshot == null),
        isTrue,
      );
      expect(
        (await service.owner.informationRecordReceipt('create'))!.toJson(),
        first.toJson(),
      );
    },
  );

  test(
    'restore invalidates local receipts atomically and across reopening',
    () async {
      final receipt = await service.owner.saveInformationRecord(
        'old-save',
        input(),
      );
      final recovery = await enableTestBackups(repository.backups);
      final backup = '${folder.path}/restore.aimbackup';
      await repository.backups.exportTo(backup);
      final targetKeys = TestKeyStore();
      final targetPath = '${folder.path}/recipient';
      var target = await EncryptedInformationRepository.open(
        targetPath,
        targetKeys,
      );
      final db = sqlite3.open('$targetPath/library.db');
      final keyHex = targetKeys.key!
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$keyHex\'"');
      try {
        // An empty recipient retains only a historical, content-free local
        // operation. Backup files never carry or install these acknowledgements.
        db.execute(
          'INSERT INTO information_record_operations(operation_id,payload) VALUES(?,?)',
          [receipt.operationId, jsonEncode(receipt.toJson())],
        );
        expect(await target.backups.recipientEmpty(), isTrue);
        db.execute(
          "CREATE TRIGGER fail_restore BEFORE INSERT ON information_items BEGIN SELECT RAISE(ABORT,'synthetic restore failure'); END",
        );
        await expectLater(
          target.backups.restoreFrom(backup, recovery),
          throwsA(isA<StorageFailure>()),
        );
        expect(
          (await target.informationRecordReceipt('old-save'))!.toJson(),
          receipt.toJson(),
        );
        expect(target.items, isEmpty);
        db.execute('DROP TRIGGER fail_restore');
        await target.backups.restoreFrom(backup, recovery);
        await expectLater(
          target.informationRecordReceipt('old-save'),
          throwsA(
            isA<AccessFailure>().having(
              (e) => e.status,
              'status',
              'library_changed',
            ),
          ),
        );
        await target.close();
        target = await EncryptedInformationRepository.open(
          targetPath,
          targetKeys,
        );
        final restoredService = InformationService(repository: target);
        try {
          await expectLater(
            restoredService.owner.saveInformationRecord('old-save', input()),
            throwsA(
              isA<AccessFailure>().having(
                (e) => e.status,
                'status',
                'library_changed',
              ),
            ),
          );
          expect(target.items, hasLength(1));
        } finally {
          await restoredService.close();
        }
      } finally {
        db.close();
        await target.close();
      }
    },
  );

  test(
    'format22 migration preserves records and introduces durable receipts',
    () async {
      final item = await service.owner.createInformation('旧资料', '', [
        const FieldInput('地址', '', 'old'),
      ]);
      await service.close();
      await repository.close();
      final db = inspect();
      try {
        db.execute('DROP TABLE information_record_operations');
        db.execute('UPDATE library_format SET version=22');
        db.execute('PRAGMA user_version=22');
      } finally {
        db.close();
      }
      repository = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: repository, clock: () => now);
      expect(repository.items.single.id, item.id);
      expect(repository.items.single.fields.single.value, 'old');
      await service.owner.saveInformationRecord('new', input());
      await reopen();
      expect(repository.items, hasLength(2));
      expect(await service.owner.informationRecordReceipt('new'), isNotNull);
    },
  );
}
