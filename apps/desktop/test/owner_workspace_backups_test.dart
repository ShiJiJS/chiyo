@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/workspace/owner_workspace_host.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/backup_page.dart';
import 'support/desktop_platform_fixture.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/workspace/backup_controller.dart';
import 'package:info_desktop/workspace/owner_workspace_backup_files.dart';
import 'package:info_desktop/workspace/owner_workspace_backups.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

// Native panels are substituted; all SQLCipher, Owner barriers, encryption,
// publication, private-file validation and receipt recovery are production code.
class _Picker extends BackupFilePicker {
  _Picker(this.root);
  final Directory root;
  String? next;
  bool failRelease = false;
  int preparations = 0, releases = 0;
  @override
  Future<String?> recoveryKeyOutput() async => next;
  @override
  Future<String?> backupOutput() async => next;
  @override
  Future<String?> backupInput() async => next;
  @override
  Future<String?> recoveryKeyInput() async => next;
  @override
  Future<BackupStaging?> prepareStaging(String output) async {
    preparations++;
    final dir = await root.createTemp('stage-');
    return BackupStaging(dir.path, 'token-$preparations');
  }

  @override
  Future<void> releaseStaging(BackupStaging staging) async {
    await Directory(staging.directory).delete();
  }

  @override
  Future<void> releaseRecordedStaging(Map<String, Object?> directory) async {
    releases++;
    expect(Directory(directory['path'] as String).existsSync(), isFalse);
    if (failRelease) throw StateError('synthetic native release failure');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late _Picker picker;
  late OwnerWorkspaceBackupFiles files;
  late OwnerWorkspaceBackups source;
  int restored = 0;
  void bind() {
    files = OwnerWorkspaceBackupFiles(owner: service.owner, picker: picker);
    source = OwnerWorkspaceBackups(
      owner: service.owner,
      backups: repo.backups,
      files: files,
      picker: picker,
      onRestored: () => restored++,
    );
  }

  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      '${root.path}/library',
      keys,
    );
    service = core.InformationService(repository: repo);
    bind();
  }

  Future<void> close() async {
    source.dispose();
    await service.close();
    await repo.close();
  }

  void sql(String query, [List<Object?> args = const []]) {
    final db = sqlite3.open('${root.path}/library/library.db');
    final key = keys.value!
        .map((n) => n.toRadixString(16).padLeft(2, '0'))
        .join();
    try {
      db.execute('PRAGMA key = "x\'$key\'"');
      db.execute(query, args);
    } finally {
      db.close();
    }
  }

  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
  Future<WorkspaceBackupResource> pick(
    WorkspaceBackupPick kind,
    String path,
  ) async {
    picker.next = path;
    return (await files.pick(kind))!;
  }

  Future<WorkspaceBackupChange> command(
    String id,
    WorkspaceBackupAction action, {
    WorkspaceBackupResource? selection,
    String? previewToken,
  }) async => WorkspaceBackupChange(
    operationId: id,
    action: action,
    expectedVersion: (await source.status()).version,
    selection: selection,
    previewToken: previewToken,
  );
  Future<void> enable() async {
    await source.change(
      await command('enable', WorkspaceBackupAction.enableKey),
    );
  }

  Future<WorkspaceBackupReceipt> saveKey() async => source.change(
    await command(
      'save-key',
      WorkspaceBackupAction.saveKey,
      selection: await pick(
        WorkspaceBackupPick.keyOutput,
        '${root.path}/恢复 密钥.txt',
      ),
    ),
  );
  Future<WorkspaceBackupReceipt> export() async => source.change(
    await command(
      'export',
      WorkspaceBackupAction.export,
      selection: await pick(
        WorkspaceBackupPick.archiveOutput,
        '${root.path}/合成 备份.aimbackup',
      ),
    ),
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-backups-');
    keys = _Keys();
    picker = _Picker(root);
    restored = 0;
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });

  test(
    'actual key save and export survive reopen, recovery needs no source library',
    () async {
      await service.owner.createInformation('合成资料', '', [
        const core.FieldInput('正文', '', 'synthetic-value'),
      ]);
      final empty = await source.status();
      expect(empty.keyCreated, isFalse);
      expect(empty.recipientEmpty, isFalse);
      expect(empty.blockers, isNotEmpty);
      await enable();
      expect((await source.status()).keySaved, isFalse);
      await saveKey();
      expect((await source.status()).keySaved, isTrue);
      final receipt = await export();
      expect(receipt.counts![WorkspaceBackupCategory.information], 1);
      expect((await source.status()).cleanupCount, 0);
      expect((await source.status()).latestArchive!.name, '合成 备份.aimbackup');
      expect(picker.preparations, 2);
      await close();
      await open();
      expect(
        (await source.receipt('export'))!.commandDigest,
        receipt.commandDigest,
      );
      final recovery = await File('${root.path}/恢复 密钥.txt').readAsString();
      final archive = '${root.path}/合成 备份.aimbackup';
      await close();
      // Source database is gone while restoration uses only portable files.
      await Directory('${root.path}/library').delete(recursive: true);
      keys = _Keys();
      await open();
      final preview = await source.inspect(
        await pick(WorkspaceBackupPick.archiveInput, archive),
        await pick(WorkspaceBackupPick.keyInput, '${root.path}/恢复 密钥.txt'),
      );
      expect(preview.counts[WorkspaceBackupCategory.information], 1);
      expect(recovery.trim().isNotEmpty, isTrue); // never print secrets
      final scope = service.owner.captureLibraryScope();
      final oldSession = service.agent.openSession('old synthetic session');
      final change = await command(
        'restore',
        WorkspaceBackupAction.restore,
        selection: preview.archive,
        previewToken: preview.token,
      );
      final restoredReceipt = await source.change(change);
      expect(restoredReceipt.matches(change), isTrue);
      expect(restored, 1);
      expect(scope.isCurrent, isFalse);
      expect(
        () => service.agent.validateSession(oldSession),
        throwsA(isA<core.AccessFailure>()),
      );
      await expectLater(source.status(), fails('library_changed'));
      source.dispose();
      bind();
      expect(
        service.owner.information.single.fields.single.value,
        'synthetic-value',
      );
      final newSession = service.agent.openSession('new synthetic session');
      await File(archive).delete();
      expect((await source.change(change)).matches(change), isTrue);
      service.agent.validateSession(
        newSession,
      ); // idempotent restore did not clear it
      expect(restored, 1);
      await close();
      await open();
      expect(
        service.owner.information.single.fields.single.value,
        'synthetic-value',
      );
      expect((await source.receipt('restore'))!.matches(change), isTrue);
    },
  );

  test(
    'persisted intent resumes in fresh controller and never recreates a completed key',
    () async {
      final c = await command(
        'lost-key-response',
        WorkspaceBackupAction.enableKey,
      );
      await repo.backups.registerOwnerOperation(c.json);
      expect(
        (await repo.backups.ownerOperationIntent(c.operationId))!.digest,
        c.digest,
      );
      await repo.backups.enableWithReceipt(
        operationId: c.operationId,
        commandDigest: c.digest,
        expectedVersion: c.expectedVersion,
      );
      final original = await repo.backups.recoveryKey();
      await close();
      await open();
      final controller = BackupController(source, const Stream.empty());
      try {
        await controller.load();
        expect(controller.uncertain, isTrue);
        await controller.write(WorkspaceBackupAction.enableKey);
        expect(controller.result, isNull);
        await controller.reconcile();
        expect(controller.result!.matches(c), isTrue);
        expect(controller.frozen, isFalse);
        expect(await repo.backups.recoveryKey() == original, isTrue);
        expect((await source.status()).pending, isNull);
        expect(picker.preparations, 0);
      } finally {
        controller.dispose();
      }
    },
  );

  test(
    'interruption before execution confirms absence without replay or losing selection',
    () async {
      await enable();
      final c = await command(
        'never-published',
        WorkspaceBackupAction.saveKey,
        selection: await pick(
          WorkspaceBackupPick.keyOutput,
          '${root.path}/未保存.txt',
        ),
      );
      await repo.backups.registerOwnerOperation(c.json);
      await close();
      await open();
      final controller = BackupController(source, const Stream.empty());
      try {
        await controller.load();
        await controller.reconcile();
        expect(controller.failure!.code, 'not_submitted');
        expect(controller.frozen, isFalse);
        expect(File('${root.path}/未保存.txt').existsSync(), isFalse);
        await expectLater(source.change(c), fails('not_submitted'));
        expect(picker.preparations, 0);
      } finally {
        controller.dispose();
      }
    },
  );

  test(
    'failure after publication reconciles exact original inode without another write',
    () async {
      await enable();
      final c = await command(
        'save-key',
        WorkspaceBackupAction.saveKey,
        selection: await pick(
          WorkspaceBackupPick.keyOutput,
          '${root.path}/恢复 密钥.txt',
        ),
      );
      sql(
        "CREATE TRIGGER reject_success BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.phase')='succeeded' BEGIN SELECT RAISE(ABORT,'injected'); END",
      );
      await expectLater(source.change(c), fails('unknown_outcome'));
      expect(File('${root.path}/恢复 密钥.txt').existsSync(), isTrue);
      expect((await source.status()).pending!.command.digest, c.digest);
      expect((await source.status()).keySaved, isFalse);
      sql('DROP TRIGGER reject_success');
      await close();
      await open();
      final controller = BackupController(source, const Stream.empty());
      try {
        await controller.load();
        await controller.reconcile();
        expect(controller.result!.matches(c), isTrue);
        expect((await source.status()).keySaved, isTrue);
        expect(picker.preparations, 1);
        await source.change(
          await command('cleanup', WorkspaceBackupAction.cleanup),
        );
        expect((await source.status()).cleanupCount, 0);
        expect(File('${root.path}/恢复 密钥.txt').existsSync(), isTrue);
      } finally {
        controller.dispose();
      }
    },
  );

  test(
    'native cleanup failure keeps successful output, explicit retry clears only staging',
    () async {
      await enable();
      picker.failRelease = true;
      final receipt = await saveKey();
      expect(receipt.action, WorkspaceBackupAction.saveKey);
      expect((await source.status()).cleanupCount, greaterThan(0));
      final failed = await command(
        'failed-cleanup',
        WorkspaceBackupAction.cleanup,
      );
      await expectLater(source.change(failed), fails('cleanup_pending'));
      expect((await source.status()).pending, isNull);
      picker.failRelease = false;
      await source.change(
        await command('retry-cleanup', WorkspaceBackupAction.cleanup),
      );
      expect((await source.status()).cleanupCount, 0);
      expect(
        (await source.receipt('save-key'))!.commandDigest,
        receipt.commandDigest,
      );
      expect(File('${root.path}/恢复 密钥.txt').existsSync(), isTrue);
      // A past failed cleanup cannot be relabelled successful by a later retry.
      expect(await source.receipt('failed-cleanup'), isNull);
    },
  );

  test(
    'selection replacement and existing output cannot overwrite owner files',
    () async {
      await enable();
      final path = '${root.path}/existing.txt';
      await File(path).writeAsString('owner-file');
      final c = await command(
        'existing',
        WorkspaceBackupAction.saveKey,
        selection: await pick(WorkspaceBackupPick.keyOutput, path),
      );
      await expectLater(source.change(c), fails('not_submitted'));
      expect(await File(path).readAsString(), 'owner-file');
      expect((await source.status()).keySaved, isFalse);
      final stale = await pick(
        WorkspaceBackupPick.keyOutput,
        '${root.path}/old.txt',
      );
      await pick(WorkspaceBackupPick.keyOutput, '${root.path}/new.txt');
      await expectLater(
        source.change(
          await command(
            'stale',
            WorkspaceBackupAction.saveKey,
            selection: stale,
          ),
        ),
        fails('invalid_selection'),
      );
      expect(File('${root.path}/old.txt').existsSync(), isFalse);
      expect((await source.status()).pending, isNull);
    },
  );

  test(
    'failed acknowledgement survives restart and receipt query keeps a new session alive',
    () async {
      final c = await command('ack-lost', WorkspaceBackupAction.enableKey);
      sql(
        "CREATE TRIGGER reject_ack BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.action')='ownerIntent' BEGIN SELECT RAISE(ABORT,'injected'); END",
      );
      final receipt = await source.change(c);
      expect(receipt.matches(c), isTrue);
      expect((await source.status()).pending, isNotNull);
      sql('DROP TRIGGER reject_ack');
      await close();
      await open();
      final session = service.agent.openSession('new chat');
      expect((await source.receipt(c.operationId))!.matches(c), isTrue);
      service.agent.validateSession(session);
      expect((await source.status()).pending, isNull);
    },
  );

  Future<WorkspaceBackupPreview> prepareRestore() async {
    await service.owner.createInformation('合成恢复', '', [
      const core.FieldInput('正文', '', 'restored'),
    ]);
    await enable();
    await saveKey();
    await export();
    await close();
    await Directory('${root.path}/library').delete(recursive: true);
    keys = _Keys();
    await open();
    return source.inspect(
      await pick(
        WorkspaceBackupPick.archiveInput,
        '${root.path}/合成 备份.aimbackup',
      ),
      await pick(WorkspaceBackupPick.keyInput, '${root.path}/恢复 密钥.txt'),
    );
  }

  test(
    'restore acknowledgement failure is recoverable after replacement without clearing new sessions',
    () async {
      final preview = await prepareRestore();
      final c = await command(
        'restore-ack-lost',
        WorkspaceBackupAction.restore,
        selection: preview.archive,
        previewToken: preview.token,
      );
      sql(
        "CREATE TRIGGER reject_restore_ack BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.action')='ownerIntent' AND json_extract(NEW.payload,'\$.pending')=0 BEGIN SELECT RAISE(ABORT,'injected'); END",
      );
      expect((await source.change(c)).matches(c), isTrue);
      expect(restored, 1);
      sql('DROP TRIGGER reject_restore_ack');
      await close();
      await open();
      final controller = BackupController(source, const Stream.empty());
      try {
        final session = service.agent.openSession('after restored reopen');
        await controller.load();
        expect(controller.uncertain, isTrue);
        await File('${root.path}/合成 备份.aimbackup').delete();
        await controller.reconcile();
        expect(controller.result!.matches(c), isTrue);
        expect(controller.frozen, isFalse);
        service.agent.validateSession(session);
        expect(
          service.owner.information.single.fields.single.value,
          'restored',
        );
        expect((await source.status()).pending, isNull);
      } finally {
        controller.dispose();
      }
    },
  );

  test(
    'changed archive after preview cannot restore, and late nonempty target remains intact',
    () async {
      final preview = await prepareRestore();
      final archive = File('${root.path}/合成 备份.aimbackup');
      final original = await archive.readAsBytes();
      final changed = List<int>.of(original);
      changed[changed.length - 1] ^= 1;
      await archive.writeAsBytes(changed);
      await expectLater(
        source.change(
          await command(
            'changed-archive',
            WorkspaceBackupAction.restore,
            selection: preview.archive,
            previewToken: preview.token,
          ),
        ),
        fails('backup_changed'),
      );
      expect(service.owner.information, isEmpty);
      expect(restored, 0);
      await archive.writeAsBytes(original);
      final next = await source.inspect(preview.archive, preview.key);
      await service.owner.createInformation('目标新资料', '', [
        const core.FieldInput('正文', '', 'keep-me'),
      ]);
      await expectLater(
        source.change(
          await command(
            'nonempty',
            WorkspaceBackupAction.restore,
            selection: next.archive,
            previewToken: next.token,
          ),
        ),
        fails('recipient_not_empty'),
      );
      expect(service.owner.information.single.fields.single.value, 'keep-me');
      expect(restored, 0);
      expect((await source.status()).pending, isNull);
    },
  );

  testWidgets(
    'production Host controls resume, save, export and replace all restored projections',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.runAsync(() async {
        await service.owner.createInformation('恢复后的合成资料', '', [
          const core.FieldInput('正文', '', 'restored-widget-body'),
        ]);
        await enable();
        await saveKey();
        await export();
        await close();
        await Directory('${root.path}/library').delete(recursive: true);
        keys = _Keys();
        await open();
        final c = await command('cold-key', WorkspaceBackupAction.enableKey);
        await repo.backups.registerOwnerOperation(c.json);
        await repo.backups.enableWithReceipt(
          operationId: c.operationId,
          commandDigest: c.digest,
          expectedVersion: c.expectedVersion,
        );
      });
      final native = NativeDesktopFixture();
      final runtime = DesktopRuntime(
        service: service,
        platform: native,
        closeServer: () async {},
        closeRepository: () async {},
      );
      await t.runAsync(runtime.start);
      Future<void> settle() async {
        for (var i = 0; i < 15; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 100));
        }
        await t.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );
        expect(t.takeException(), isNull);
      }

      Future<void> tap(String key) async {
        final f = find.byKey(ValueKey(key));
        await t.ensureVisible(f);
        // Start native/SQLCipher futures in the real clock; widget pumps continue
        // dispatching Owner history callbacks and paint notifications.
        await t.runAsync(() => t.tap(f));
        await settle();
      }

      OwnerWorkspaceSource current() =>
          t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
              as OwnerWorkspaceSource;
      try {
        await t.pumpWidget(
          OwnerWorkspaceHost(
            runtime: runtime,
            backups: repo.backups,
            backupPicker: picker,
          ),
        );
        await settle();
        final old = current();
        expect(old.backups, isA<OwnerWorkspaceBackups>());
        expect(
          find.byKey(const ValueKey('backup-root-reconcile')),
          findsOneWidget,
        );
        expect(native.navigationStates.last, isFalse);
        await tap('backup-root-reconcile');
        expect(
          find.byKey(const ValueKey('backup-root-reconcile')),
          findsNothing,
        );
        expect(native.navigationStates.last, isTrue);
        await tap('workspace-nav-settings');
        await tap('settings-section-backups');
        final controller = t
            .widget<WorkspaceBackupPage>(find.byType(WorkspaceBackupPage))
            .controller;
        expect(controller.value!.keyCreated, isTrue);
        await tap('backup-open-export');
        picker.next = '${root.path}/新的恢复密钥.txt';
        await tap('backup-pick-keyOutput');
        await tap('backup-save-key');
        expect(controller.value!.keySaved, isTrue);
        picker.next = '${root.path}/空目标导出.aimbackup';
        await tap('backup-pick-archiveOutput');
        await tap('backup-export');
        expect(
          controller.result!.counts![WorkspaceBackupCategory.information],
          0,
        );
        expect(File(picker.next!).existsSync(), isTrue);
        await tap('backup-flow-close');
        await tap('backup-open-restore');
        picker.next = '${root.path}/合成 备份.aimbackup';
        await tap('backup-pick-archiveInput');
        picker.next = '${root.path}/恢复 密钥.txt';
        await tap('backup-pick-keyInput');
        await tap('backup-inspect');
        expect(
          controller.preview!.counts[WorkspaceBackupCategory.information],
          1,
        );
        final session = service.agent.openSession('old UI chat');
        await tap('backup-restore');
        expect(current(), isNot(same(old)));
        expect(old.isCurrentLibrary, isFalse);
        expect(current().isCurrentLibrary, isTrue);
        expect(find.byType(WorkspaceBackupPage), findsNothing);
        expect(find.text('restored-widget-body'), findsOneWidget);
        expect(
          () => service.agent.validateSession(session),
          throwsA(isA<core.AccessFailure>()),
        );
        expect(native.navigationStates.last, isTrue);
      } finally {
        await t.pumpWidget(const SizedBox());
        await settle();
        await t.runAsync(runtime.quit);
        runtime.dispose();
      }
    },
  );
}
