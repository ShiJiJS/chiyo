@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:info_desktop/workspace/library_file.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:sqlite3/sqlite3.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> k) async {
    key = List.of(k);
  }
}

class _Picker extends BackupFilePicker {
  String? output;
  bool failRelease = false,
      failBookmark = false,
      requiresAccess = false,
      denyAccess = false;
  int panels = 0, opens = 0, closes = 0;
  Completer<void>? panelStarted, panelDone;
  @override
  Future<String?> backupOutput() async => null;
  @override
  Future<String?> backupInput() async => null;
  @override
  Future<String?> recoveryKeyOutput() async => null;
  @override
  Future<String?> ownerFileOutput(String name) async {
    panels++;
    panelStarted?.complete();
    await panelDone?.future;
    return output;
  }

  @override
  Future<BackupStaging?> prepareStaging(String path) async {
    final d = await Directory(File(path).parent.path).createTemp('own-stage-');
    return BackupStaging(
      d.path,
      'synthetic',
      stagingBookmark: requiresAccess ? 'synthetic-stage' : null,
    );
  }

  @override
  Future<String> outputBookmark(BackupStaging staging) async {
    if (failBookmark) throw const StorageFailure('backup_access_required');
    return 'synthetic-output';
  }

  @override
  Future<String> acquireAccess(
    Map<String, String> args, {
    required bool needsOutput,
  }) async {
    if (denyAccess) throw const StorageFailure('backup_access_required');
    opens++;
    return 'synthetic-lease';
  }

  @override
  Future<void> releaseAccess(String token) async {
    closes++;
  }

  @override
  Future<void> releaseRecordedStaging(Map<String, Object?> dir) async {
    if (failRelease) throw StateError('synthetic release');
  }

  @override
  Future<void> releaseStaging(BackupStaging s) async {
    if (failRelease) throw StateError('synthetic release');
  }

  @override
  Future<String?> reselectOutput(String path) async {
    denyAccess = false;
    return 'synthetic-output';
  }
}

class _Source extends OwnerWorkspaceSource {
  _Source({
    required super.owner,
    required super.fileOutputs,
    required super.outputPicker,
  }) : super(refreshInterval: Duration.zero);
  bool wrongReceipt = false;
  @override
  Future<WorkspaceFileOperationReceipt?> fileOperationReceipt(String id) async {
    final r = await super.fileOperationReceipt(id);
    return !wrongReceipt || r == null
        ? r
        : WorkspaceFileOperationReceipt(
            r.record,
            r.file,
            actionCompleted: r.actionCompleted,
            commandDigest: 'f' * 64,
          );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Keys keys;
  late _Picker picker;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceSource source;
  late WorkspaceRecordRef record;
  late String key;
  var isOpen = false;
  final content = utf8.encode('合成附件另存原文');
  void sql(String query) {
    final db = sqlite3.open('${root.path}/library/library.db');
    try {
      final hex = keys.key!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      db.execute(query);
    } finally {
      db.close();
    }
  }

  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      '${root.path}/library',
      keys,
    );
    service = core.InformationService(repository: repo);
    isOpen = true;
    source = _Source(
      owner: service.owner,
      fileOutputs: repo.fileOutputs,
      outputPicker: picker,
    );
  }

  Future<void> close() async {
    if (!isOpen) return;
    await source.dispose();
    await service.close();
    await repo.close();
    isOpen = false;
  }

  Future<void> seed() async {
    final input = File('${root.path}/合成原文件.txt');
    await input.writeAsBytes(content);
    final draft = await service.owner.beginInformationFileDraft();
    try {
      final stage = await service.owner.stageInformationFile(
        draft,
        input.path,
        mediaType: 'text/plain',
      );
      final item = await service.owner.commitInformationDraft(
        draft,
        'seed',
        core.InformationDraftInput(
          name: '合成资料',
          description: '',
          fields: [core.InformationDraftField.stagedFile('文件', '', stage.id)],
        ),
      );
      record = WorkspaceRecordRef(WorkspaceRecordKind.information, item.id);
      key = (await source.readDetail(record)).fieldIds.keys.single;
    } finally {
      await service.owner.releaseInformationFileDraft(draft);
    }
  }

  Future<T> real<T>(WidgetTester t, Future<T> Function() action) async {
    var complete = false;
    Object? result, error;
    StackTrace? trace;
    await t.runAsync(() async {
      unawaited(
        Future<T>.sync(action).then(
          (value) {
            result = value;
            complete = true;
          },
          onError: (Object e, StackTrace s) {
            error = e;
            trace = s;
            complete = true;
          },
        ),
      );
    });
    final elapsed = Stopwatch()..start();
    while (!complete && elapsed.elapsed < const Duration(seconds: 20)) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    if (!complete) throw TimeoutException('Owner file I/O did not settle');
    if (error != null) Error.throwWithStackTrace(error!, trace!);
    return result as T;
  }

  Future<void> settle(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 200; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      if (done()) {
        await t.pump();
        return;
      }
    }
    fail('Owner file UI did not settle');
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-file-output-');
    root = Directory(root.resolveSymbolicLinksSync());
    keys = _Keys();
    picker = _Picker();
    picker.output = '${root.path}/另存合成文件.txt';
    await open();
    await seed();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
  Future<WorkspaceFileActionResult> save([String id = 'file-save']) => source
      .fileAction(record, key, 1, WorkspaceFileAction.saveAs, operationId: id);

  test(
    'production save preserves record, bytes and exact receipt across reopen',
    () async {
      final before = service.owner.information.single.version;
      final result = await save();
      expect(result.completed, isTrue);
      expect(result.cleanupPending, isFalse);
      expect(File(picker.output!).readAsBytesSync(), content);
      expect(service.owner.information.single.version, before);
      final receipt = (await source.fileOperationReceipt('file-save'))!;
      expect(
        receipt.commandDigest,
        workspaceFileActionDigest(record, key, 1, WorkspaceFileAction.saveAs),
      );
      expect(receipt.actionCompleted, isTrue);
      expect(receipt.record, record);
      await close();
      await open();
      expect((await save()).completed, isTrue);
      expect(picker.panels, 1);
      await expectLater(
        source.fileAction(
          record,
          key,
          2,
          WorkspaceFileAction.saveAs,
          operationId: 'file-save',
        ),
        fails('operation_conflict'),
      );
      expect(
        root.listSync().whereType<Directory>().where(
          (d) => d.path.contains('own-stage-'),
        ),
        isEmpty,
      );
    },
  );
  test(
    'panel cancel has no journal and existing destination cannot be overwritten',
    () async {
      picker.output = null;
      expect((await save()).completed, isFalse);
      expect(await source.fileOperationReceipt('file-save'), isNull);
      picker.output = '${root.path}/保留.txt';
      await File(picker.output!).writeAsString('保留');
      await expectLater(save(), fails('not_saved'));
      expect(File(picker.output!).readAsStringSync(), '保留');
      expect(
        (await source.fileOperationReceipt('file-save'))!.actionCompleted,
        isFalse,
      );
    },
  );
  test('cleanup failure preserves completed save and can retry', () async {
    picker.failRelease = true;
    final done = await save();
    expect(done.completed, isTrue);
    expect(done.cleanupPending, isTrue);
    expect((await source.fileActionState(record, key)).cleanupPending, 1);
    picker.failRelease = false;
    await source.cleanupFileActions(record, key);
    expect((await source.fileActionState(record, key)).cleanupPending, 0);
    expect(File(picker.output!).readAsBytesSync(), content);
  });
  test(
    'lost SQL receipt after publication reconciles, access denied stays pending across reopen',
    () async {
      picker.requiresAccess = true;
      sql(
        "CREATE TRIGGER fail_receipt BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.phase')='succeeded' BEGIN SELECT RAISE(ABORT,'synthetic'); END",
      );
      await expectLater(save(), fails('unknown_outcome'));
      expect(File(picker.output!).readAsBytesSync(), content);
      sql('DROP TRIGGER fail_receipt');
      await close();
      await open();
      picker.denyAccess = true;
      final state = await source.fileActionState(record, key);
      expect(state.pending!.operationId, 'file-save');
      await expectLater(
        source.fileOperationReceipt('file-save'),
        fails('file_access_required'),
      );
      await expectLater(save('another'), fails('previous_pending'));
      expect(picker.panels, 1);
      await source.recoverFileActionAccess('file-save');
      expect(
        (await source.fileOperationReceipt('file-save'))!.actionCompleted,
        isTrue,
      );
      expect(picker.opens, picker.closes);
    },
  );
  test(
    'output removed after lost response stays unknown and preserves private anchor',
    () async {
      sql(
        "CREATE TRIGGER fail_receipt BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.phase')='succeeded' BEGIN SELECT RAISE(ABORT,'synthetic'); END",
      );
      await expectLater(save(), fails('unknown_outcome'));
      sql('DROP TRIGGER fail_receipt');
      await File(picker.output!).delete();
      await close();
      await open();
      await expectLater(
        source.fileOperationReceipt('file-save'),
        fails('unknown_outcome'),
      );
      expect((await source.fileActionState(record, key)).pending, isNotNull);
      expect(
        root
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.contains('own-stage-'))
            .single
            .listSync(),
        isNotEmpty,
      );
    },
  );
  test(
    'library scope changed during native panel cannot export old content',
    () async {
      picker.panelStarted = Completer<void>();
      picker.panelDone = Completer<void>();
      final attempt = save();
      final rejected = expectLater(attempt, fails('library_changed'));
      await picker.panelStarted!.future;
      await service.owner.restoreLibrary(() async {});
      picker.panelDone!.complete();
      await rejected;
      expect(File(picker.output!).existsSync(), isFalse);
      expect(await repo.fileOutputs.pending(), isEmpty);
    },
  );
  test(
    'source disposed during native panel cannot publish late selection',
    () async {
      picker.panelStarted = Completer<void>();
      picker.panelDone = Completer<void>();
      final attempt = save();
      final rejected = expectLater(attempt, fails('library_changed'));
      await picker.panelStarted!.future;
      await source.dispose();
      picker.panelDone!.complete();
      await rejected;
      expect(File(picker.output!).existsSync(), isFalse);
      expect(await repo.fileOutputs.pending(), isEmpty);
    },
  );
  test(
    'portable backup restores original bytes without local output paths or receipts',
    () async {
      await save();
      final recovery = await repo.backups.enable();
      await repo.backups.saveRecoveryKeyTo('${root.path}/recovery.txt');
      await service.owner.exportLibrary(
        () => repo.backups.exportTo('${root.path}/backup.aimbackup'),
      );
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
      );
      final other = core.InformationService(repository: target);
      try {
        final contents = await target.backups.inspect(
          '${root.path}/backup.aimbackup',
          recovery,
        );
        await other.owner.restoreLibrary(
          () => target.backups.restore(contents),
        );
        expect(await target.fileOutputs.status('file-save'), isNull);
        expect(
          await target.fileOutputs.pending(includeInvalidated: true),
          isEmpty,
        );
        final file = other.owner.information.single.fields.single.attachment!;
        expect(
          (await other.owner.readInformationAttachment(file)).bytes,
          content,
        );
      } finally {
        await other.close();
        await target.close();
      }
    },
  );
  testWidgets(
    'reopened pending action is visible and wrong digest cannot unlock controls',
    (t) async {
      t.view.physicalSize = const Size(1440, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await real(t, () async {
        sql(
          "CREATE TRIGGER fail_receipt BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.phase')='succeeded' BEGIN SELECT RAISE(ABORT,'synthetic'); END",
        );
        await expectLater(save(), fails('unknown_outcome'));
        sql('DROP TRIGGER fail_receipt');
        await close();
        await open();
      });
      final detail = await real(t, () => source.readDetail(record));
      (source as _Source).wrongReceipt = true;
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: LibraryFile(detail: detail, fieldKey: key, source: source),
            ),
          ),
        ),
      );
      await settle(
        t,
        () =>
            find.text('核对此次操作').evaluate().isNotEmpty &&
            find.text('正在读取预览…').evaluate().isEmpty,
      );
      expect(find.text('重新选择原文件并核对'), findsOneWidget);
      await t.tap(find.text('核对此次操作'));
      await settle(
        t,
        () => find.text('返回的结果与原操作不一致，请继续核对。').evaluate().isNotEmpty,
      );
      expect(find.text('核对此次操作'), findsOneWidget);
      expect(picker.panels, 1);
      (source as _Source).wrongReceipt = false;
      await t.tap(find.text('核对此次操作'));
      await settle(t, () => find.text('核对此次操作').evaluate().isEmpty);
      expect(File(picker.output!).readAsBytesSync(), content);
      expect(picker.panels, 1);
      await t.pumpWidget(const SizedBox.shrink());
      await real(t, close);
    },
  );
}
