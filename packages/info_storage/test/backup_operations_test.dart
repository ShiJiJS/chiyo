import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = InformationService(repository: repo);
  }

  Future<void> close() async {
    await service.close();
    await repo.close();
  }

  Database inspect() {
    final db = sqlite3.open('${root.path}/library.db');
    final hex = keys.key!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('backup-operations-');
    keys = TestKeyStore();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  Matcher fails(String code) =>
      throwsA(isA<StorageFailure>().having((e) => e.code, 'code', code));
  Future<BackupKeyOperationReceipt> enable(
    String id,
    int version, {
    String? digest,
  }) => repo.backups.enableWithReceipt(
    operationId: id,
    commandDigest: digest ?? 'a' * 64,
    expectedVersion: version,
  );

  test(
    'lost response reconciles after reopen without regenerating or exposing recovery key',
    () async {
      final receipt = await enable('create-key', 1);
      final key = await repo.backups.recoveryKey();
      expect(receipt.version, 2);
      expect(jsonEncode(receipt.toJson()).contains(key!), isFalse);
      await close();
      await open();
      expect(
        (await repo.backups.recoveryKeyOperationReceipt(
          'create-key',
        ))!.toJson(),
        receipt.toJson(),
      );
      expect((await enable('create-key', 1)).toJson(), receipt.toJson());
      expect(await repo.backups.recoveryKey() == key, isTrue);
      expect(await repo.backups.operationVersion(), 2);
      await expectLater(
        enable('create-key', 1, digest: 'b' * 64),
        fails('operation_conflict'),
      );
      await expectLater(enable('create-key', 2), fails('operation_conflict'));
      await expectLater(
        enable('another-key', 1),
        fails('backup_version_conflict'),
      );
      expect(
        await repo.backups.recoveryKeyOperationReceipt('unsubmitted'),
        isNull,
      );
    },
  );

  test(
    'receipt storage failure rolls back key creation and version together',
    () async {
      final db = inspect();
      try {
        db.execute(
          "CREATE TRIGGER reject_backup_receipt BEFORE INSERT ON backup_operations BEGIN SELECT RAISE(ABORT,'injected'); END",
        );
      } finally {
        db.close();
      }
      await expectLater(
        enable('create-key', 1),
        fails('backup_operation_failed'),
      );
      expect(await repo.backups.recoveryKey(), isNull);
      expect(await repo.backups.operationVersion(), 1);
      expect(
        await repo.backups.recoveryKeyOperationReceipt('create-key'),
        isNull,
      );
      final retry = inspect();
      try {
        retry.execute('DROP TRIGGER reject_backup_receipt');
      } finally {
        retry.close();
      }
      expect((await enable('create-key', 1)).version, 2);
    },
  );

  test(
    'invalid operation intent cannot create a key or advance status',
    () async {
      for (final args in [
        ('', 'a' * 64, 1),
        ('invalid/id', 'a' * 64, 1),
        ('a' * 129, 'a' * 64, 1),
        ('create-key', 'a' * 63, 1),
        ('create-key', 'A' * 64, 1),
        ('create-key', 'a' * 64, 0),
      ]) {
        await expectLater(
          repo.backups.enableWithReceipt(
            operationId: args.$1,
            commandDigest: args.$2,
            expectedVersion: args.$3,
          ),
          fails('invalid_backup_operation'),
        );
      }
      await expectLater(
        repo.backups.recoveryKeyOperationReceipt('invalid/id'),
        fails('invalid_backup_operation'),
      );
      expect(await repo.backups.recoveryKey(), isNull);
      expect(await repo.backups.operationVersion(), 1);
      expect(
        await repo.backups.recoveryKeyOperationReceipt('create-key'),
        isNull,
      );
    },
  );

  test(
    'corrupt persisted receipt is unknown, never absence or permission to replay',
    () async {
      final receipt = await enable('create-key', 1);
      final key = await repo.backups.recoveryKey();
      for (final payload in <String>[
        'not-json',
        '[]',
        jsonEncode({...receipt.toJson(), 'operationId': 'different-operation'}),
        jsonEncode({...receipt.toJson(), 'action': 'export'}),
        jsonEncode({...receipt.toJson(), 'expectedVersion': 0}),
        jsonEncode({...receipt.toJson(), 'version': 9}),
        jsonEncode({...receipt.toJson(), 'commandDigest': 'malformed'}),
        jsonEncode({...receipt.toJson(), 'extra': 'unsupported'}),
      ]) {
        final db = inspect();
        try {
          db.execute(
            'UPDATE backup_operations SET payload=? WHERE operation_id=?',
            [payload, 'create-key'],
          );
        } finally {
          db.close();
        }
        await expectLater(
          repo.backups.recoveryKeyOperationReceipt('create-key'),
          fails('invalid_backup_operation_receipt'),
        );
        await expectLater(
          enable('create-key', 1),
          fails('invalid_backup_operation_receipt'),
        );
        expect(await repo.backups.operationVersion(), 2);
        expect(await repo.backups.recoveryKey() == key, isTrue);
      }
      await close();
      await open();
      await expectLater(
        repo.backups.recoveryKeyOperationReceipt('create-key'),
        fails('invalid_backup_operation_receipt'),
      );
      expect(await repo.backups.operationVersion(), 2);
    },
  );

  test(
    'legacy creation and independent save advance the same status version',
    () async {
      final key = await repo.backups.enable();
      expect(await repo.backups.operationVersion(), 2);
      await repo.backups.enable();
      expect(await repo.backups.operationVersion(), 2);
      await repo.backups.saveRecoveryKeyTo('${root.path}/recovery.txt');
      expect(await repo.backups.operationVersion(), 3);
      final receipt = await enable('ack-existing-key', 3);
      expect(receipt.version, 4);
      expect(await repo.backups.recoveryKey() == key, isTrue);
      expect(await repo.backups.recoveryKeySaved(), isTrue);
      await expectLater(
        repo.backups.saveRecoveryKeyTo('${root.path}/recovery.txt'),
        fails('output_exists'),
      );
      expect(await repo.backups.operationVersion(), 4);
    },
  );

  test(
    'concurrent different intents cannot both consume the same version',
    () async {
      Future<Object> attempt(String id) async {
        try {
          return await enable(id, 1);
        } on StorageFailure catch (e) {
          return e.code;
        }
      }

      final results = await Future.wait([attempt('first'), attempt('second')]);
      expect(results.whereType<BackupKeyOperationReceipt>().length, 1);
      expect(results.whereType<String>().single, 'backup_version_conflict');
      expect(await repo.backups.operationVersion(), 2);
    },
  );

  test(
    'backup excludes local receipts; successful restore invalidates recipient intents only',
    () async {
      await service.owner.createInformation('合成资料', '', [
        const FieldInput('字段', '', 'synthetic'),
      ]);
      await enable('source-key', 1);
      final recovery = (await repo.backups.recoveryKey())!;
      await repo.backups.saveRecoveryKeyTo('${root.path}/recovery.txt');
      final archive = '${root.path}/export.aimbackup';
      await service.owner.exportLibrary(() => repo.backups.exportTo(archive));
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        TestKeyStore(),
      );
      final targetService = InformationService(repository: target);
      try {
        await target.backups.enableWithReceipt(
          operationId: 'target-key',
          commandDigest: 'b' * 64,
          expectedVersion: 1,
        );
        final targetKey = await target.backups.recoveryKey();
        expect(await target.backups.recipientEmpty(), isTrue);
        final preview = await target.backups.inspect(archive, recovery);
        await targetService.owner.restoreLibrary(
          () => target.backups.restore(preview),
        );
        expect(targetService.owner.information.length, 1);
        expect(await target.backups.operationVersion(), 3);
        expect(await target.backups.recoveryKey() == targetKey, isTrue);
        expect(
          await target.backups.recoveryKeyOperationReceipt('source-key'),
          isNull,
        );
        await expectLater(
          target.backups.recoveryKeyOperationReceipt('target-key'),
          fails('library_changed'),
        );
        await expectLater(
          target.backups.enableWithReceipt(
            operationId: 'target-key',
            commandDigest: 'b' * 64,
            expectedVersion: 1,
          ),
          fails('library_changed'),
        );
        expect(
          await repo.backups.recoveryKeyOperationReceipt('source-key'),
          isNotNull,
        );
      } finally {
        await targetService.close();
        await target.close();
      }
    },
  );

  test('restore failure rolls back invalidation and local version', () async {
    await enable('target-key', 1);
    final source = await EncryptedInformationRepository.open(
      '${root.path}/source',
      TestKeyStore(),
    );
    final sourceService = InformationService(repository: source);
    try {
      await sourceService.owner.createInformation('合成资料', '', [
        const FieldInput('字段', '', 'synthetic'),
      ]);
      final key = await source.backups.enable();
      await source.backups.saveRecoveryKeyTo('${root.path}/source-key.txt');
      await sourceService.owner.exportLibrary(
        () => source.backups.exportTo('${root.path}/source.aimbackup'),
      );
      final preview = await repo.backups.inspect(
        '${root.path}/source.aimbackup',
        key,
      );
      final db = inspect();
      try {
        db.execute(
          "CREATE TRIGGER reject_restored_item BEFORE INSERT ON information_items BEGIN SELECT RAISE(ABORT,'injected'); END",
        );
      } finally {
        db.close();
      }
      await expectLater(
        service.owner.restoreLibrary(() => repo.backups.restore(preview)),
        throwsA(isA<StorageFailure>()),
      );
      expect(await repo.backups.operationVersion(), 2);
      expect(
        await repo.backups.recoveryKeyOperationReceipt('target-key'),
        isNotNull,
      );
      expect(service.owner.information, isEmpty);
    } finally {
      await sourceService.close();
      await source.close();
    }
  });

  for (final old in [36, 37]) {
    test(
      'schema$old migrates keeping prior key and portable boundary',
      () async {
        final key = await repo.backups.enable();
        await close();
        final db = inspect();
        try {
          db.execute('DROP TABLE backup_operations');
          db.execute('DROP TABLE backup_operation_state');
          db.execute('UPDATE library_format SET version=$old');
          db.execute('PRAGMA user_version=$old');
        } finally {
          db.close();
        }
        await open();
        expect(await repo.backups.recoveryKey() == key, isTrue);
        expect(await repo.backups.operationVersion(), 1);
        final checked = inspect();
        try {
          expect(
            checked.select('PRAGMA user_version').single.values.single,
            old == 36 ? 38 : 39,
          );
          expect(
            checked
                .select('SELECT version FROM library_format')
                .single
                .values
                .single,
            old == 36 ? 38 : 39,
          );
        } finally {
          checked.close();
        }
        expect((await enable('ack-migrated-key', 1)).version, 2);
      },
    );
  }
}
