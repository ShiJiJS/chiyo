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

  void sql(String statement, [List<Object?> values = const []]) {
    final db = sqlite3.open('${root.path}/library.db');
    final hex = keys.key!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    try {
      db.execute('PRAGMA key = "x\'$hex\'"');
      db.execute(statement, values);
    } finally {
      db.close();
    }
  }

  Map<String, Object?> command(String id, {String action = 'enableKey'}) => {
    'operationId': id,
    'action': action,
    'expectedVersion': 1,
    'selection': null,
    'previewToken': null,
  };
  Matcher fails(String code) =>
      throwsA(isA<StorageFailure>().having((e) => e.code, 'code', code));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('backup-owner-');
    keys = TestKeyStore();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });

  test(
    'durable owner intent has one pending command and duplicates cannot change meaning',
    () async {
      final c = command('first');
      expect(await repo.backups.registerOwnerOperation(c), isTrue);
      expect(await repo.backups.operationVersion(), 1);
      expect(await repo.backups.registerOwnerOperation(c), isFalse);
      await expectLater(
        repo.backups.registerOwnerOperation(command('second')),
        fails('backup_outcome_unknown'),
      );
      await expectLater(
        repo.backups.registerOwnerOperation(
          command('first', action: 'cleanup'),
        ),
        fails('operation_conflict'),
      );
      await close();
      await open();
      final pending = (await repo.backups.pendingOwnerOperations()).single;
      expect(pending.command, c);
      expect(await repo.backups.recoveryKey(), isNull);
      await expectLater(
        repo.backups.acknowledgeOwnerOperation('first', 'a' * 64),
        fails('operation_conflict'),
      );
      await repo.backups.acknowledgeOwnerOperation('first', pending.digest);
      expect(await repo.backups.pendingOwnerOperations(), isEmpty);
      expect(await repo.backups.registerOwnerOperation(c), isFalse);
      expect(
        await repo.backups.registerOwnerOperation(command('second')),
        isTrue,
      );
    },
  );

  test(
    'strict resource schema excludes paths, secrets, wrong purposes and stale versions',
    () async {
      for (final c in [
        {...command('bad'), 'path': '/private/key.txt'},
        {...command('bad'), 'previewToken': 'unused'},
        {
          ...command('bad'),
          'action': 'saveKey',
          'selection': {
            'id': 'opaque',
            'name': '/private/key.txt',
            'kind': 'keyOutput',
            'version': 1,
          },
        },
        {
          ...command('bad'),
          'action': 'saveKey',
          'selection': {
            'id': 'opaque',
            'name': 'key.txt',
            'kind': 'archiveInput',
            'version': 1,
          },
        },
      ]) {
        await expectLater(
          repo.backups.registerOwnerOperation(c),
          fails('invalid_backup_operation'),
        );
      }
      await expectLater(
        repo.backups.registerOwnerOperation({
          ...command('stale'),
          'expectedVersion': 2,
        }),
        fails('backup_version_conflict'),
      );
      expect(await repo.backups.pendingOwnerOperations(), isEmpty);
      expect(await repo.backups.operationVersion(), 1);
    },
  );

  test(
    'persisted intent cannot be moved to another operation slot or silently ignored',
    () async {
      await repo.backups.registerOwnerOperation(command('first'));
      final first = (await repo.backups.ownerOperationIntent('first'))!;
      await repo.backups.acknowledgeOwnerOperation('first', first.digest);
      await repo.backups.registerOwnerOperation(command('second'));
      sql(
        "UPDATE backup_operations SET payload=(SELECT payload FROM backup_operations WHERE json_extract(payload,'\$.command.operationId')='second') WHERE json_extract(payload,'\$.command.operationId')='first'",
      );
      await expectLater(
        repo.backups.ownerOperationIntent('first'),
        fails('invalid_backup_operation_receipt'),
      );
      await expectLater(
        repo.backups.pendingOwnerOperations(),
        fails('invalid_backup_operation_receipt'),
      );
    },
  );

  test(
    'cleanup receipt commits once, rolls back on failure and never revives a retired attempt',
    () async {
      await repo.backups.registerOwnerOperation(
        command('cleanup', action: 'cleanup'),
      );
      sql(
        "CREATE TRIGGER reject_cleanup BEFORE INSERT ON backup_operations WHEN json_extract(NEW.payload,'\$.action')='cleanup' BEGIN SELECT RAISE(ABORT,'injected'); END",
      );
      await expectLater(
        repo.backups.finishOwnerCleanup('cleanup'),
        throwsA(anything),
      );
      expect(await repo.backups.operationVersion(), 1);
      expect(await repo.backups.cleanupOperationReceipt('cleanup'), isNull);
      sql('DROP TRIGGER reject_cleanup');
      final receipt = await repo.backups.finishOwnerCleanup('cleanup');
      await repo.backups.acknowledgeOwnerOperation(
        'cleanup',
        receipt.commandDigest,
      );
      expect(
        (await repo.backups.finishOwnerCleanup('cleanup')).toJson(),
        receipt.toJson(),
      );
      final retired = {
        ...command('retired', action: 'cleanup'),
        'expectedVersion': receipt.version,
      };
      await repo.backups.registerOwnerOperation(retired);
      final intent = (await repo.backups.ownerOperationIntent('retired'))!;
      await repo.backups.acknowledgeOwnerOperation('retired', intent.digest);
      await expectLater(
        repo.backups.finishOwnerCleanup('retired'),
        fails('operation_conflict'),
      );
    },
  );

  test(
    'restore keeps only its own pending acknowledgement and portable files exclude owner intents',
    () async {
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        TestKeyStore(),
      );
      final sourceService = InformationService(repository: source);
      try {
        await sourceService.owner.createInformation('合成正文', '', [
          const FieldInput('正文', '', 'synthetic'),
        ]);
        await source.backups.registerOwnerOperation(command('source-owner'));
        final key = await source.backups.enable();
        await source.backups.saveRecoveryKeyTo('${root.path}/key.txt');
        final archive = '${root.path}/archive.aimbackup';
        await sourceService.owner.exportLibrary(
          () => source.backups.exportTo(archive),
        );
        final preview = await repo.backups.inspectRestore(
          path: archive,
          recoveryKey: key,
          archiveId: 'opaque-archive',
          archiveVersion: 1,
        );
        final c = {
          ...command('restore', action: 'restore'),
          'previewToken': 'opaque-token',
          'selection': {
            'id': 'opaque-archive',
            'name': 'archive.aimbackup',
            'kind': 'archiveInput',
            'version': 1,
          },
        };
        expect(
          await repo.backups.registerOwnerOperation(
            c,
            restoreCounts: preview.counts,
          ),
          isTrue,
        );
        expect(
          await repo.backups.registerOwnerOperation(
            c,
            restoreCounts: Map.fromEntries(
              preview.counts.entries.toList().reversed,
            ),
          ),
          isFalse,
        );
        final intent = (await repo.backups.ownerOperationIntent('restore'))!;
        await service.owner.restoreLibrary(
          () => repo.backups.restoreWithReceipt(
            operationId: 'restore',
            commandDigest: intent.digest,
            expectedVersion: 1,
            preview: preview,
          ),
        );
        expect(
          (await repo.backups.pendingOwnerOperations()).single.operationId,
          'restore',
        );
        expect(await repo.backups.ownerOperationIntent('source-owner'), isNull);
        await close();
        await open();
        final saved = (await repo.backups.pendingOwnerOperations()).single;
        expect(saved.restoreCounts, preview.counts);
        expect(jsonEncode(saved.command), isNot(contains(root.path)));
        await repo.backups.acknowledgeOwnerOperation(
          saved.operationId,
          saved.digest,
        );
        expect(await repo.backups.pendingOwnerOperations(), isEmpty);
      } finally {
        await sourceService.close();
        await source.close();
      }
    },
  );
}
