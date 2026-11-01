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
  late String archive, recovery;
  var now = DateTime.utc(2026, 11, 1);
  var opened = false;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      '${root.path}/target',
      keys,
      clock: () => now,
    );
    service = InformationService(repository: repo, clock: () => now);
    opened = true;
  }

  Future<void> close() async {
    if (!opened) return;
    await service.close();
    await repo.close();
    opened = false;
  }

  void sql(String statement, [List<Object?> params = const []]) {
    final db = sqlite3.open('${root.path}/target/library.db');
    final key = keys.key!
        .map((n) => n.toRadixString(16).padLeft(2, '0'))
        .join();
    try {
      db.execute('PRAGMA key = "x\'$key\'"');
      db.execute(statement, params);
    } finally {
      db.close();
    }
  }

  Matcher fails(String code) =>
      throwsA(isA<StorageFailure>().having((e) => e.code, 'code', code));
  Future<BackupRestorePreview> preview({String id = 'archive'}) =>
      repo.backups.inspectRestore(
        path: archive,
        recoveryKey: recovery,
        archiveId: id,
        archiveVersion: 1,
      );
  Future<BackupRestoreReceipt> restore(
    BackupRestorePreview p, {
    String id = 'restore',
    String? digest,
  }) => repo.backups.restoreWithReceipt(
    operationId: id,
    commandDigest: digest ?? 'a' * 64,
    expectedVersion: p.expectedVersion,
    preview: p,
  );
  Future<void> createArchive({
    bool empty = false,
    bool attachment = false,
  }) async {
    final source = await EncryptedInformationRepository.open(
      '${root.path}/source-${attachment
          ? "files"
          : empty
          ? "empty"
          : "full"}',
      TestKeyStore(),
      clock: () => now,
    );
    final owner = InformationService(repository: source, clock: () => now);
    try {
      if (!empty) {
        final item = await owner.owner.createInformation('合成资料', '', [
          const FieldInput('字段', '', 'synthetic-secret'),
        ]);
        final field = FieldRef(item.id, item.fields.single.id);
        final session = owner.agent.openSession('source chat');
        final request = owner.agent.request(session, 'read', [field]);
        owner.owner.approve(request.id, [field]);
        await owner.owner.history();
      }
      if (attachment) {
        final file = File('${root.path}/合成附件.txt');
        await file.writeAsBytes([1, 2, 3, 4]);
        final draft = await owner.owner.beginInformationFileDraft();
        final staged = await owner.owner.stageInformationFile(draft, file.path);
        await owner.owner.commitInformationDraft(
          draft,
          'file-save',
          InformationDraftInput(
            name: '附件资料',
            description: '',
            fields: [InformationDraftField.stagedFile('附件', '', staged.id)],
          ),
        );
        await owner.owner.releaseInformationFileDraft(draft);
      }
      recovery = await source.backups.enable();
      await source.backups.saveRecoveryKeyTo(
        '${root.path}/source-$empty-$attachment-key',
      );
      archive =
          '${root.path}/${attachment
              ? "附件"
              : empty
              ? "空"
              : "合成"} 备份.aimbackup';
      await owner.owner.exportLibrary(() => source.backups.exportTo(archive));
    } finally {
      await owner.close();
      await source.close();
    }
  }

  setUp(() async {
    now = DateTime.utc(2026, 11, 1);
    root = await Directory.systemTemp.createTemp('backup-restore-operations-');
    keys = TestKeyStore();
    await open();
    await createArchive();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });

  test(
    'restore receipt commits with data, survives reopen and reconciles without source or new session loss',
    () async {
      await repo.backups.enableWithReceipt(
        operationId: 'old-key',
        commandDigest: 'b' * 64,
        expectedVersion: 1,
      );
      final localKey = await repo.backups.recoveryKey();
      final p = await preview();
      expect(p.formatVersion, 7); // Legacy memory-only snapshots use this path.
      final scope = service.owner.captureLibraryScope();
      final oldSession = service.agent.openSession('old');
      final receipt = await service.owner.restoreLibraryOnce(
        previous: () => repo.backups.restoreOperationReceipt('restore'),
        restore: () => restore(p),
      );
      expect(scope.isCurrent, isFalse);
      expect(
        () => service.agent.validateSession(oldSession),
        throwsA(isA<AccessFailure>()),
      );
      expect(receipt.version, p.expectedVersion + 1);
      expect(receipt.counts, p.counts);
      expect(receipt.counts['information'], 1);
      expect(receipt.counts['grants'], 1);
      expect(service.owner.requests, isEmpty);
      expect(
        (await service.owner.history()).grants.every((g) => !g.active),
        isTrue,
      );
      expect(await repo.backups.recoveryKey(), localKey);
      expect(await repo.backups.backupOperationAction('restore'), 'restore');
      expect(await repo.backups.pendingOutputCleanupCount(), 0);
      await expectLater(
        repo.backups.recoveryKeyOperationReceipt('old-key'),
        fails('library_changed'),
      );
      final serialized = jsonEncode(receipt.toJson());
      for (final secret in [root.path, recovery, 'synthetic-secret']) {
        expect(serialized, isNot(contains(secret)));
      }
      await close();
      await open();
      await File(archive).delete();
      final currentScope = service.owner.captureLibraryScope();
      final session = service.agent.openSession('after restore');
      final replay = await service.owner.restoreLibraryOnce(
        previous: () => repo.backups.restoreOperationReceipt('restore'),
        restore: () async => throw StateError('must not execute'),
      );
      expect(replay.toJson(), receipt.toJson());
      expect(currentScope.isCurrent, isTrue);
      service.agent.validateSession(session);
      expect((await restore(p)).toJson(), receipt.toJson());
      expect(await repo.backups.operationVersion(), receipt.version);
      expect(
        service.owner.information.single.fields.single.value,
        'synthetic-secret',
      );
      await expectLater(
        restore(p, digest: 'c' * 64),
        fails('operation_conflict'),
      );
    },
  );

  test(
    'receipt insertion failure rolls back installed rows, caches, old receipts and version',
    () async {
      await repo.backups.enableWithReceipt(
        operationId: 'old',
        commandDigest: 'b' * 64,
        expectedVersion: 1,
      );
      final p = await preview();
      final scope = service.owner.captureLibraryScope();
      final session = service.agent.openSession('before failed restore');
      sql(
        "CREATE TRIGGER reject_restore BEFORE INSERT ON backup_operations WHEN json_extract(NEW.payload,'\$.action')='restore' BEGIN SELECT RAISE(ABORT,'injected'); END",
      );
      await expectLater(
        service.owner.restoreLibraryOnce(
          previous: () => repo.backups.restoreOperationReceipt('restore'),
          restore: () => restore(p),
        ),
        fails('backup_restore_failed'),
      );
      expect(await repo.backups.recipientEmpty(), isTrue);
      expect(service.owner.information, isEmpty);
      expect(await repo.backups.operationVersion(), p.expectedVersion);
      expect(await repo.backups.recoveryKeyOperationReceipt('old'), isNotNull);
      expect(await repo.backups.restoreOperationReceipt('restore'), isNull);
      expect(scope.isCurrent, isTrue);
      service.agent.validateSession(session);
      sql('DROP TRIGGER reject_restore');
      final receipt = await service.owner.restoreLibraryOnce(
        previous: () => repo.backups.restoreOperationReceipt('restore'),
        restore: () => restore(p),
      );
      expect(receipt.counts['information'], 1);
      expect(scope.isCurrent, isFalse);
    },
  );

  test(
    'changed encrypted archive, bad key and nonempty target never install',
    () async {
      final p = await preview();
      final file = File(archive);
      final original = await file.readAsBytes();
      final changed = original.toList();
      changed[4096] ^= 1;
      await file.writeAsBytes(changed, flush: true);
      await expectLater(restore(p), fails('backup_changed'));
      expect(await repo.backups.recipientEmpty(), isTrue);
      await file.writeAsBytes(original, flush: true);
      await expectLater(
        repo.backups.inspectRestore(
          path: archive,
          recoveryKey: 'wrong',
          archiveId: 'a',
          archiveVersion: 1,
        ),
        fails('invalid_recovery_key'),
      );
      await service.owner.createInformation('keep', '', [
        const FieldInput('keep', '', 'keep'),
      ]);
      await expectLater(restore(p), fails('recipient_not_empty'));
      await expectLater(preview(), fails('recipient_not_empty'));
      expect(service.owner.information.single.name, 'keep');
      expect(await repo.backups.restoreOperationReceipt('restore'), isNull);
      expect(await repo.backups.operationVersion(), p.expectedVersion);
    },
  );

  test(
    'preview expires on release, recipient reopen, version change and retention changes',
    () async {
      final released = await preview();
      released.release();
      await expectLater(restore(released), fails('backup_preview_expired'));
      final old = await preview();
      await close();
      await open();
      await expectLater(restore(old), fails('backup_preview_expired'));
      final stale = await preview();
      await repo.backups.enable();
      await expectLater(restore(stale), fails('backup_version_conflict'));
      final retained = await preview();
      now = now.add(const Duration(days: 91));
      await expectLater(restore(retained), fails('backup_preview_expired'));
      expect(await repo.backups.recipientEmpty(), isTrue);
      expect(await repo.backups.restoreOperationReceipt('restore'), isNull);
    },
  );

  test(
    'another recipient cannot use preview; same operation cannot change selected resource',
    () async {
      final p = await preview();
      final other = await EncryptedInformationRepository.open(
        '${root.path}/other',
        TestKeyStore(),
        clock: () => now,
      );
      try {
        await expectLater(
          other.backups.restoreWithReceipt(
            operationId: 'restore',
            commandDigest: 'a' * 64,
            expectedVersion: p.expectedVersion,
            preview: p,
          ),
          fails('backup_preview_expired'),
        );
      } finally {
        await other.close();
      }
      final different = await preview(id: 'other-resource');
      await service.owner.restoreLibrary(() => restore(p));
      await expectLater(restore(different), fails('operation_conflict'));
    },
  );

  test(
    'subsequent empty restore invalidates prior receipt and journals never travel in backups',
    () async {
      await createArchive(empty: true);
      final first = await preview();
      await service.owner.restoreLibrary(() => restore(first));
      final second = await preview(id: 'second');
      await service.owner.restoreLibrary(
        () => restore(second, id: 'second-restore'),
      );
      await expectLater(
        repo.backups.restoreOperationReceipt('restore'),
        fails('library_changed'),
      );
      expect(
        await repo.backups.restoreOperationReceipt('second-restore'),
        isNotNull,
      );
      final key = await repo.backups.enable();
      await repo.backups.saveRecoveryKeyTo('${root.path}/target-key');
      final exported = '${root.path}/restored-export.aimbackup';
      await service.owner.exportLibrary(() => repo.backups.exportTo(exported));
      final other = await EncryptedInformationRepository.open(
        '${root.path}/other',
        TestKeyStore(),
        clock: () => now,
      );
      try {
        await other.backups.restoreFrom(exported, key);
        expect(
          await other.backups.restoreOperationReceipt('second-restore'),
          isNull,
        );
      } finally {
        await other.close();
      }
    },
  );

  test(
    'corrupt receipts and action collisions are errors, never absence or replay',
    () async {
      final p = await preview();
      await repo.backups.enableWithReceipt(
        operationId: 'collision',
        commandDigest: 'b' * 64,
        expectedVersion: 1,
      );
      await expectLater(
        restore(p, id: 'collision'),
        fails('operation_conflict'),
      );
      final fresh = await preview();
      await service.owner.restoreLibrary(() => restore(fresh));
      await expectLater(
        repo.backups.reconcileOutputOperation('restore'),
        fails('operation_conflict'),
      );
      sql(
        "UPDATE backup_operations SET payload=json_set(payload,'\$.version',99) WHERE operation_id='restore'",
      );
      await expectLater(
        repo.backups.restoreOperationReceipt('restore'),
        fails('invalid_backup_operation_receipt'),
      );
      await expectLater(
        repo.backups.backupOperationAction('restore'),
        fails('invalid_backup_operation_receipt'),
      );
      await expectLater(
        restore(fresh),
        fails('invalid_backup_operation_receipt'),
      );
      expect(service.owner.information, hasLength(1));
    },
  );

  test(
    'attachment installation and old draft invalidation share the restore receipt transaction',
    () async {
      await createArchive(attachment: true);
      final p = await preview();
      expect(p.formatVersion, greaterThanOrEqualTo(8));
      expect(p.counts['files'], 1);
      expect(p.counts['fileBytes'], 4);
      final draft = await service.owner.beginInformationFileDraft();
      await service.owner.stageInformationFile(draft, '${root.path}/合成附件.txt');
      sql(
        "CREATE TRIGGER reject_restore BEFORE INSERT ON backup_operations WHEN json_extract(NEW.payload,'\$.action')='restore' BEGIN SELECT RAISE(ABORT,'injected'); END",
      );
      await expectLater(
        service.owner.restoreLibrary(() => restore(p)),
        fails('backup_restore_failed'),
      );
      expect(await repo.backups.recipientEmpty(), isTrue);
      expect((await repo.informationFileStagingUsage()).files, 1);
      sql('DROP TRIGGER reject_restore');
      final receipt = await service.owner.restoreLibrary(() => restore(p));
      expect(receipt.counts, p.counts);
      expect((await repo.informationFileStagingUsage()).files, 0);
      final file = service.owner.information
          .singleWhere((i) => i.name == '附件资料')
          .fields
          .single
          .attachment!;
      expect(await repo.readInformationAttachmentChunk(file, 0, 4), [
        1,
        2,
        3,
        4,
      ]);
      await close();
      await open();
      expect(await repo.readInformationAttachmentChunk(file, 0, 4), [
        1,
        2,
        3,
        4,
      ]);
      expect(
        (await repo.backups.restoreOperationReceipt('restore'))!.counts,
        p.counts,
      );
    },
  );

  test(
    'two empty restores cannot consume the same recipient version',
    () async {
      await createArchive(empty: true);
      final a = await preview(id: 'a'), b = await preview(id: 'b');
      Future<Object> attempt(BackupRestorePreview p, String id) async {
        try {
          return await restore(p, id: id);
        } on StorageFailure catch (e) {
          return e.code;
        }
      }

      final results = await Future.wait([attempt(a, 'a'), attempt(b, 'b')]);
      expect(results.whereType<BackupRestoreReceipt>(), hasLength(1));
      expect(results.whereType<String>().single, 'backup_version_conflict');
      expect(await repo.backups.operationVersion(), a.expectedVersion + 1);
    },
  );
}
