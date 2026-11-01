import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_storage/macos_backup_publication.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  late Directory root, staging, outputs;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  var opened = false;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      '${root.path}/library',
      keys,
    );
    service = InformationService(repository: repo);
    opened = true;
  }

  Future<void> close() async {
    if (!opened) return;
    await service.close();
    await repo.close();
    opened = false;
  }

  Database raw() {
    final db = sqlite3.open('${root.path}/library/library.db');
    final key = keys.key!
        .map((n) => n.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$key\'"');
    return db;
  }

  void sql(String text, [List<Object?> params = const []]) {
    final db = raw();
    try {
      db.execute(text, params);
    } finally {
      db.close();
    }
  }

  Matcher failure(String code) =>
      throwsA(isA<StorageFailure>().having((e) => e.code, 'code', code));
  Future<MacBackupPublication> prepareKey(
    String id, {
    int? version,
    String? key,
  }) async {
    final path = '${staging.path}/$id';
    MacBackupPublicationFiles.writeRecoveryKey(
      path,
      utf8.encode('${key ?? await repo.backups.recoveryKey()}\n'),
    );
    final publication = MacBackupPublicationFiles.prepare(
      path,
      '${outputs.path}/$id.txt',
    );
    await repo.backups.prepareOutputOperation(
      operationId: id,
      commandDigest: 'a' * 64,
      expectedVersion: version ?? await repo.backups.operationVersion(),
      action: BackupOutputAction.saveKey,
      publication: publication,
    );
    return publication;
  }

  Future<void> rejectReceipt() async => sql(
    "CREATE TRIGGER reject_output_receipt BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.phase')='succeeded' BEGIN SELECT RAISE(ABORT,'injected'); END",
  );

  group('SQLCipher output journal with real macOS publication', () {
    setUp(() async {
      final temp = await Directory.systemTemp.createTemp(
        'backup-output-operations-',
      );
      root = Directory(temp.resolveSymbolicLinksSync());
      staging = await root.createTemp('staging-');
      outputs = await root.createTemp('outputs-');
      keys = TestKeyStore();
      await open();
      await repo.backups.enable();
    });
    tearDown(() async {
      await close();
      await root.delete(recursive: true);
    });

    test(
      'save key records success, repeats across reopen, then cleanup preserves output and receipt',
      () async {
        final publication = await prepareKey('save');
        expect(await repo.backups.recoveryKeySaved(), isFalse);
        expect(await repo.backups.operationVersion(), 3);
        final receipt = await repo.backups.publishOutputOperation('save');
        expect(receipt.version, 4);
        expect(receipt.expectedVersion, 2);
        expect(receipt.action, BackupOutputAction.saveKey);
        expect(receipt.fileName, 'save.txt');
        expect(receipt.counts, isEmpty);
        expect(jsonEncode(receipt.toJson()), isNot(contains(root.path)));
        expect(
          jsonEncode(receipt.toJson()),
          isNot(contains((await repo.backups.recoveryKey())!)),
        );
        expect(await repo.backups.recoveryKeySaved(), isTrue);
        expect(await repo.backups.pendingOutputCleanupCount(), 1);
        final modified = File(publication.destination).statSync().modified;
        await close();
        await open();
        expect(
          (await repo.backups.reconcileOutputOperation('save'))!.toJson(),
          receipt.toJson(),
        );
        expect(
          (await repo.backups.publishOutputOperation('save')).toJson(),
          receipt.toJson(),
        );
        expect(File(publication.destination).statSync().modified, modified);
        await repo.backups.cleanupOutputOperation('save');
        expect(await repo.backups.pendingOutputCleanupCount(), 0);
        expect(await repo.backups.operationVersion(), 5);
        expect(File(publication.source).existsSync(), isFalse);
        File(publication.destination).deleteSync();
        expect(
          (await repo.backups.reconcileOutputOperation('save'))!.toJson(),
          receipt.toJson(),
        );
        expect(
          (await repo.backups.publishOutputOperation('save')).toJson(),
          receipt.toJson(),
        );
        expect(File(publication.destination).existsSync(), isFalse);
      },
    );

    test(
      'lost success transaction rolls back saved flag; native identity reconciles after reopen',
      () async {
        final publication = await prepareKey('lost');
        await rejectReceipt();
        await expectLater(
          repo.backups.publishOutputOperation('lost'),
          failure('backup_outcome_unknown'),
        );
        expect(File(publication.destination).existsSync(), isTrue);
        expect(await repo.backups.recoveryKeySaved(), isFalse);
        expect(await repo.backups.operationVersion(), 3);
        expect(
          await repo.backups.outputOperationPhase('lost'),
          BackupOutputPhase.publishing,
        );
        await expectLater(
          repo.backups.cleanupOutputOperation('lost'),
          failure('backup_outcome_unknown'),
        );
        sql('DROP TRIGGER reject_output_receipt');
        await close();
        await open();
        final modified = File(publication.destination).statSync().modified;
        final receipt = await repo.backups.reconcileOutputOperation('lost');
        expect(receipt!.version, 4);
        expect(await repo.backups.recoveryKeySaved(), isTrue);
        expect(File(publication.destination).statSync().modified, modified);
        await repo.backups.cleanupOutputOperation('lost');
        expect(File(publication.destination).existsSync(), isTrue);
      },
    );

    test('publishing barrier must commit before any output appears', () async {
      final publication = await prepareKey('barrier');
      sql(
        "CREATE TRIGGER reject_publication_barrier BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.phase')='publishing' BEGIN SELECT RAISE(ABORT,'injected'); END",
      );
      await expectLater(
        repo.backups.publishOutputOperation('barrier'),
        failure('backup_outcome_unknown'),
      );
      expect(File(publication.destination).existsSync(), isFalse);
      expect(
        await repo.backups.outputOperationPhase('barrier'),
        BackupOutputPhase.prepared,
      );
      expect(await repo.backups.recoveryKeySaved(), isFalse);
      sql('DROP TRIGGER reject_publication_barrier');
      expect(await repo.backups.reconcileOutputOperation('barrier'), isNull);
      await repo.backups.cleanupOutputOperation('barrier');
      expect(File(publication.source).existsSync(), isFalse);
      expect(File(publication.destination).existsSync(), isFalse);
    });

    test(
      'existing identical output is definite nonpublication, not a saved key or successful receipt',
      () async {
        final publication = await prepareKey('collision');
        File(
          publication.destination,
        ).writeAsBytesSync(File(publication.source).readAsBytesSync());
        final before = File(publication.destination).statSync();
        await expectLater(
          repo.backups.publishOutputOperation('collision'),
          failure('backup_not_published'),
        );
        expect(
          await repo.backups.outputOperationPhase('collision'),
          BackupOutputPhase.notPublished,
        );
        expect(await repo.backups.recoveryKeySaved(), isFalse);
        expect(
          await repo.backups.reconcileOutputOperation('collision'),
          isNull,
        );
        await repo.backups.cleanupOutputOperation('collision');
        expect(
          File(publication.destination).statSync().modified,
          before.modified,
        );
        await expectLater(
          repo.backups.publishOutputOperation('collision'),
          failure('backup_not_published'),
        );
      },
    );

    test(
      'prepared intent after reopen is abandoned without any file publication',
      () async {
        final publication = await prepareKey('prepared');
        await close();
        await open();
        await repo.backups.prepareOutputOperation(
          operationId: 'prepared',
          commandDigest: 'a' * 64,
          expectedVersion: 2,
          action: BackupOutputAction.saveKey,
          publication: publication,
        );
        await expectLater(
          repo.backups.publishOutputOperation('prepared'),
          failure('backup_not_published'),
        );
        expect(File(publication.destination).existsSync(), isFalse);
        expect(await repo.backups.recoveryKeySaved(), isFalse);
        await repo.backups.cleanupOutputOperation('prepared');
        expect(File(publication.source).existsSync(), isFalse);
      },
    );

    test(
      'publishing intent with missing or replaced output stays unknown and never replays',
      () async {
        final publication = await prepareKey('uncertain');
        sql(
          "UPDATE backup_operations SET payload=json_set(payload,'\$.phase','publishing') WHERE operation_id='uncertain'",
        );
        await close();
        await open();
        await expectLater(
          repo.backups.reconcileOutputOperation('uncertain'),
          failure('backup_outcome_unknown'),
        );
        expect(File(publication.destination).existsSync(), isFalse);
        File(
          publication.destination,
        ).writeAsBytesSync(File(publication.source).readAsBytesSync());
        await expectLater(
          repo.backups.publishOutputOperation('uncertain'),
          failure('backup_outcome_unknown'),
        );
        await expectLater(
          repo.backups.cleanupOutputOperation('uncertain'),
          failure('backup_outcome_unknown'),
        );
        expect(await repo.backups.recoveryKeySaved(), isFalse);
        expect(await repo.backups.pendingOutputCleanupCount(), 1);
      },
    );

    test(
      'cleanup failure retains success and can retry without deleting unrelated file',
      () async {
        final publication = await prepareKey('cleanup');
        final receipt = await repo.backups.publishOutputOperation('cleanup');
        File('${publication.source}.publish').writeAsStringSync('unrelated');
        await expectLater(
          repo.backups.cleanupOutputOperation('cleanup'),
          failure('backup_cleanup_pending'),
        );
        expect(await repo.backups.pendingOutputCleanupCount(), 1);
        expect(
          (await repo.backups.reconcileOutputOperation('cleanup'))!.toJson(),
          receipt.toJson(),
        );
        expect(
          File('${publication.source}.publish').readAsStringSync(),
          'unrelated',
        );
        File(
          '${publication.source}.publish',
        ).deleteSync(); // Test-owned fixture only.
        await repo.backups.cleanupOutputOperation('cleanup');
        expect(await repo.backups.pendingOutputCleanupCount(), 0);
        expect(File(publication.destination).existsSync(), isTrue);
      },
    );

    test(
      'intent conflict, wrong recovery key and failed journal insert have no published effect',
      () async {
        final publication = await prepareKey('bound');
        await expectLater(
          repo.backups.prepareOutputOperation(
            operationId: 'bound',
            commandDigest: 'b' * 64,
            expectedVersion: 2,
            action: BackupOutputAction.saveKey,
            publication: publication,
          ),
          failure('operation_conflict'),
        );
        final version = await repo.backups.operationVersion();
        await expectLater(
          prepareKey(
            'wrong-key',
            key: 'aim-recovery-v1:${base64Url.encode(List.filled(32, 0))}',
          ),
          failure('invalid_recovery_key'),
        );
        expect(await repo.backups.backupOperationAction('wrong-key'), isNull);
        expect(await repo.backups.operationVersion(), version);
        sql(
          "CREATE TRIGGER reject_output_prepare BEFORE INSERT ON backup_operations BEGIN SELECT RAISE(ABORT,'injected'); END",
        );
        await expectLater(
          prepareKey('failed-prepare'),
          failure('backup_operation_failed'),
        );
        expect(
          await repo.backups.backupOperationAction('failed-prepare'),
          isNull,
        );
        expect(await repo.backups.operationVersion(), version);
        expect(
          File('${outputs.path}/failed-prepare.txt').existsSync(),
          isFalse,
        );
      },
    );

    test(
      'concurrent preparations cannot consume the same status version',
      () async {
        Future<Object?> attempt(String id) async {
          try {
            await prepareKey(id, version: 2);
            return null;
          } on StorageFailure catch (e) {
            return e.code;
          }
        }

        final results = await Future.wait([
          attempt('first'),
          attempt('second'),
        ]);
        expect(results.where((e) => e == null).length, 1);
        expect(
          results.where((e) => e != null).single,
          'backup_version_conflict',
        );
        expect(await repo.backups.operationVersion(), 3);
      },
    );

    test(
      'corrupt journal is never absence and cannot be used to publish or clean',
      () async {
        final publication = await prepareKey('bad');
        sql(
          "UPDATE backup_operations SET payload=json_set(payload,'\$.phase','imaginary') WHERE operation_id='bad'",
        );
        await expectLater(
          repo.backups.backupOperationAction('bad'),
          failure('invalid_backup_operation_receipt'),
        );
        await expectLater(
          repo.backups.reconcileOutputOperation('bad'),
          failure('invalid_backup_operation_receipt'),
        );
        await expectLater(
          repo.backups.publishOutputOperation('bad'),
          failure('invalid_backup_operation_receipt'),
        );
        await expectLater(
          repo.backups.cleanupOutputOperation('bad'),
          failure('invalid_backup_operation_receipt'),
        );
        expect(File(publication.source).existsSync(), isTrue);
        expect(File(publication.destination).existsSync(), isFalse);
      },
    );

    test(
      'restoring even an empty backup invalidates old output intents without deleting owner files',
      () async {
        final publication = await prepareKey('old');
        await repo.backups.publishOutputOperation('old');
        await repo.backups.cleanupOutputOperation('old');
        final modified = File(publication.destination).statSync().modified;
        final archive = '${root.path}/empty.aimbackup';
        await service.owner.exportLibrary(() => repo.backups.exportTo(archive));
        final preview = await repo.backups.inspect(
          archive,
          (await repo.backups.recoveryKey())!,
        );
        expect(await repo.backups.recipientEmpty(), isTrue);
        await service.owner.restoreLibrary(() => repo.backups.restore(preview));
        await expectLater(
          repo.backups.backupOperationAction('old'),
          failure('library_changed'),
        );
        await expectLater(
          repo.backups.reconcileOutputOperation('old'),
          failure('library_changed'),
        );
        await expectLater(
          repo.backups.publishOutputOperation('old'),
          failure('library_changed'),
        );
        expect(File(publication.destination).statSync().modified, modified);
      },
    );

    test(
      'a changed configured key cannot be marked saved by publication of the old key',
      () async {
        final publication = await prepareKey('key-change');
        sql('UPDATE backup_configuration SET recovery_key=?', [
          'aim-recovery-v1:${base64Url.encode(List.filled(32, 0))}',
        ]);
        await expectLater(
          repo.backups.publishOutputOperation('key-change'),
          failure('backup_outcome_unknown'),
        );
        expect(File(publication.destination).existsSync(), isTrue);
        expect(await repo.backups.recoveryKeySaved(), isFalse);
        await expectLater(
          repo.backups.reconcileOutputOperation('key-change'),
          failure('backup_outcome_unknown'),
        );
        expect(await repo.backups.recoveryKeySaved(), isFalse);
      },
    );

    test(
      'authenticated backup publishes full counts and excludes output journals when restored',
      () async {
        await prepareKey('key');
        await repo.backups.publishOutputOperation('key');
        await service.owner.createInformation('合成资料', '', [
          const FieldInput('字段', '', 'synthetic'),
        ]);
        final source = '${staging.path}/backup';
        await service.owner.exportLibrary(() => repo.backups.exportTo(source));
        final publication = MacBackupPublicationFiles.prepare(
          source,
          '${outputs.path}/备份.aimbackup',
        );
        final version = await repo.backups.operationVersion();
        await repo.backups.prepareOutputOperation(
          operationId: 'export',
          commandDigest: 'c' * 64,
          expectedVersion: version,
          action: BackupOutputAction.export,
          publication: publication,
        );
        final receipt = await repo.backups.publishOutputOperation('export');
        expect(receipt.counts['information'], 1);
        expect(receipt.counts['files'], 0);
        expect(
          receipt.counts.keys,
          containsAll([
            'credentials',
            'materials',
            'grants',
            'operations',
            'legacyTemplates',
          ]),
        );
        expect(jsonEncode(receipt.toJson()), isNot(contains(root.path)));
        final recovery = (await repo.backups.recoveryKey())!;
        await repo.backups.cleanupOutputOperation('export');
        await close();
        final restored = await EncryptedInformationRepository.open(
          '${root.path}/restored',
          TestKeyStore(),
        );
        final owner = InformationService(repository: restored);
        try {
          final preview = await restored.backups.inspect(
            publication.destination,
            recovery,
          );
          await owner.owner.restoreLibrary(
            () => restored.backups.restore(preview),
          );
          expect(owner.owner.information.single.name, '合成资料');
          expect(
            await restored.backups.backupOperationAction('export'),
            isNull,
          );
          expect(await restored.backups.pendingOutputCleanupCount(), 0);
        } finally {
          await owner.close();
          await restored.close();
        }
      },
    );
  }, skip: !Platform.isMacOS);
}
