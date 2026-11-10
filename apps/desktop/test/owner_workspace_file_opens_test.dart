@TestOn('mac-os || windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/library_file.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:sqlite3/sqlite3.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> bytes) async {
    key = List.of(bytes);
  }
}

class _Dispatch implements OwnerFileOpenDispatcher {
  core.InformationDeliveryLease? lease;
  int count = 0;
  bool accept = true, drop = false, loseStatus = false;
  OwnerFileDispatchOutcome? result;
  @override
  Future<OwnerFileDispatchOutcome> open(
    String id,
    String digest,
    core.InformationDeliveryLease copy,
    int length,
    String hash,
  ) async {
    count++;
    lease = copy;
    await core.NativeInformationDeliveryFiles().verify(copy, length, hash);
    result = accept
        ? OwnerFileDispatchOutcome.opened
        : OwnerFileDispatchOutcome.notOpened;
    if (drop) throw StateError('lost response');
    return result!;
  }

  @override
  Future<OwnerFileDispatchOutcome?> status(String id, String digest) async =>
      loseStatus ? null : result;
}

class _OutputPicker extends BackupFilePicker {
  final started = Completer<void>(), selected = Completer<String?>();
  int allocations = 0;
  @override
  Future<String?> recoveryKeyOutput() async => null;
  @override
  Future<String?> backupOutput() async => null;
  @override
  Future<String?> backupInput() async => null;
  @override
  Future<String?> ownerFileOutput(String name) async {
    started.complete();
    return selected.future;
  }

  @override
  Future<BackupStaging?> prepareStaging(String path) async {
    allocations++;
    return null;
  }
}

class _Source extends OwnerWorkspaceSource {
  _Source({
    required super.owner,
    required super.fileOpens,
    required super.openDispatcher,
  }) : super(refreshInterval: Duration.zero);
  bool wrong = false;
  @override
  Future<WorkspaceFileOperationReceipt?> fileOperationReceipt(String id) async {
    final r = await super.fileOperationReceipt(id);
    return !wrong || r == null
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
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceSource source;
  late _Dispatch dispatch;
  late WorkspaceRecordRef record;
  late String field;
  var isOpen = false;
  final body = utf8.encode('合成外部打开原文');
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      '${root.path}/library',
      keys,
    );
    service = core.InformationService(repository: repo);
    isOpen = true;
    source = _Source(
      owner: service.owner,
      fileOpens: repo.fileOpens,
      openDispatcher: dispatch,
    );
  }

  Future<void> close() async {
    if (!isOpen) return;
    await source.dispose();
    await service.close();
    await repo.fileOpens.maintain(closeAll: true);
    await repo.close();
    isOpen = false;
  }

  Future<void> seed({String mime = 'text/plain'}) async {
    final path = '${root.path}/合成输入.txt';
    await File(path).writeAsBytes(body);
    final draft = await service.owner.beginInformationFileDraft();
    try {
      final stage = await service.owner.stageInformationFile(
        draft,
        path,
        mediaType: mime,
      );
      final item = await service.owner.commitInformationDraft(
        draft,
        'seed',
        core.InformationDraftInput(
          name: '合成外部打开',
          description: '',
          fields: [core.InformationDraftField.stagedFile('文件', '', stage.id)],
        ),
      );
      record = WorkspaceRecordRef(WorkspaceRecordKind.information, item.id);
      field = (await source.readDetail(record)).fieldIds.keys.single;
    } finally {
      await service.owner.releaseInformationFileDraft(draft);
    }
  }

  void sql(String query) {
    final db = sqlite3.open('${root.path}/library/library.db');
    try {
      final hex = keys.key!
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      db.execute(query);
    } finally {
      db.close();
    }
  }

  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
  Future<WorkspaceFileActionResult> launch([String id = 'owner-open']) => source
      .fileAction(record, field, 1, WorkspaceFileAction.open, operationId: id);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-open-source-');
    keys = _Keys();
    dispatch = _Dispatch();
    await open();
    await seed();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
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

  test(
    'production source opens a verified disposable copy, never modifies original and replays receipt',
    () async {
      final before = service.owner.information.single.version;
      expect((await launch()).completed, true);
      expect(dispatch.count, 1);
      expect(File(dispatch.lease!.filePath).readAsBytesSync(), body);
      expect((await launch()).completed, true);
      expect(dispatch.count, 1);
      final receipt = (await source.fileOperationReceipt('owner-open'))!;
      expect(
        receipt.commandDigest,
        workspaceFileActionDigest(record, field, 1, WorkspaceFileAction.open),
      );
      expect(receipt.actionCompleted, true);
      expect(receipt.openCopyHeld, true);
      await File(dispatch.lease!.filePath).writeAsString('外部修改仅在临时副本');
      expect(
        (await source.readFilePreview(record, field)).text,
        utf8.decode(body),
      );
      expect(service.owner.information.single.version, before);
      expect((await source.fileActionState(record, field)).openCopies, 1);
      await source.closeOpenFileCopies(record, field);
      expect(File(dispatch.lease!.filePath).existsSync(), false);
      expect(
        (await source.fileOperationReceipt('owner-open'))!.openCopyHeld,
        false,
      );
      expect((await source.fileActionState(record, field)).openCopies, 0);
    },
  );
  test('system rejection cleans only its copy and reports failure', () async {
    dispatch.accept = false;
    await expectLater(launch(), fails('not_opened'));
    expect(dispatch.count, 1);
    expect(File(dispatch.lease!.filePath).existsSync(), false);
    expect(
      (await source.fileOperationReceipt('owner-open'))!.actionCompleted,
      false,
    );
  });
  test(
    'lost channel response reconciles accepted native receipt once',
    () async {
      dispatch.drop = true;
      expect((await launch()).completed, true);
      expect(dispatch.count, 1);
      await source.finishFileOpen('owner-open');
      expect(File(dispatch.lease!.filePath).existsSync(), false);
    },
  );
  test(
    'unknown native outcome survives restart and explicit end never invents success',
    () async {
      dispatch.drop = true;
      dispatch.loseStatus = true;
      await expectLater(launch(), fails('unknown_outcome'));
      final old = dispatch.lease!;
      await source.dispose();
      await service.close();
      await repo.close();
      isOpen = false;
      dispatch = _Dispatch();
      await open();
      final state = await source.fileActionState(record, field);
      expect(state.pending!.action, WorkspaceFileAction.open);
      await expectLater(launch('another'), fails('previous_pending'));
      expect(dispatch.count, 0);
      await expectLater(
        source.fileOperationReceipt('owner-open'),
        fails('unknown_outcome'),
      );
      await source.finishFileOpen('owner-open');
      expect(File(old.filePath).existsSync(), false);
      expect((await source.fileActionState(record, field)).pending, isNull);
      await expectLater(
        source.fileOperationReceipt('owner-open'),
        fails('unknown_outcome'),
      );
      expect((await launch('new-open')).completed, true);
      expect(dispatch.count, 1);
    },
  );
  test(
    'SQL result failure leaves original intent, then exact receipt reconciles',
    () async {
      sql(
        "CREATE TRIGGER fail_open BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.phase')='opened' BEGIN SELECT RAISE(ABORT,'synthetic'); END",
      );
      await expectLater(launch(), fails('unknown_outcome'));
      sql('DROP TRIGGER fail_open');
      expect(
        (await source.fileOperationReceipt('owner-open'))!.actionCompleted,
        true,
      );
      expect(dispatch.count, 1);
    },
  );
  test(
    'stale version or field cannot open and command-family conflict is refused',
    () async {
      await expectLater(
        source.fileAction(
          record,
          field,
          2,
          WorkspaceFileAction.open,
          operationId: 'stale',
        ),
        fails('conflict'),
      );
      await expectLater(
        source.fileAction(
          record,
          'forged',
          1,
          WorkspaceFileAction.open,
          operationId: 'field',
        ),
        fails('not_found'),
      );
      expect(dispatch.count, 0);
      await launch();
      await expectLater(
        source.fileAction(
          record,
          field,
          2,
          WorkspaceFileAction.open,
          operationId: 'owner-open',
        ),
        fails('conflict'),
      );
    },
  );
  test(
    'unsupported media is not sent to a program or written as a copy',
    () async {
      await seed(mime: 'application/octet-stream');
      await expectLater(launch(), fails('unsupported'));
      expect(dispatch.count, 0);
      expect(await repo.fileOpens.copies(), isEmpty);
    },
  );
  test(
    'portable backup restores bytes without owner-copy leases or launch authority',
    () async {
      await launch();
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
        expect(await target.fileOpens.status('owner-open'), isNull);
        expect(
          await target.fileOpens.copies(includeInvalidated: true),
          isEmpty,
        );
        expect(
          (await other.owner.readInformationAttachment(
            other.owner.information.single.fields.single.attachment!,
          )).bytes,
          body,
        );
      } finally {
        await other.close();
        await target.close();
      }
    },
  );
  test(
    'late Save panel cannot race a newly unknown Open into a second publication',
    () async {
      await source.dispose();
      final picker = _OutputPicker();
      source = OwnerWorkspaceSource(
        owner: service.owner,
        fileOpens: repo.fileOpens,
        fileOutputs: repo.fileOutputs,
        openDispatcher: dispatch,
        outputPicker: picker,
        refreshInterval: Duration.zero,
      );
      final saving = source.fileAction(
        record,
        field,
        1,
        WorkspaceFileAction.saveAs,
        operationId: 'late-save',
      );
      final rejected = expectLater(saving, fails('previous_pending'));
      await picker.started.future;
      dispatch.drop = true;
      dispatch.loseStatus = true;
      await expectLater(launch(), fails('unknown_outcome'));
      picker.selected.complete('${root.path}/must-not-write.txt');
      await rejected;
      expect(File('${root.path}/must-not-write.txt').existsSync(), false);
      expect(picker.allocations, 0);
      expect(
        (await source.fileActionState(record, field)).pending!.operationId,
        'owner-open',
      );
      expect(await repo.fileOutputs.status('late-save'), null);
      expect(dispatch.count, 1);
    },
  );
  test(
    'replaced consumer copy stays pending for cleanup without deleting a new inode',
    () async {
      await launch();
      final lease = dispatch.lease!;
      final moved = '${lease.path}/synthetic-original';
      await File(lease.filePath).rename(moved);
      await File(lease.filePath).writeAsString('replacement');
      try {
        await expectLater(
          source.closeOpenFileCopies(record, field),
          fails('cleanup_pending'),
        );
        expect(File(lease.filePath).readAsStringSync(), 'replacement');
        final state = await source.fileActionState(record, field);
        expect(state.openCleanupPending, 1);
        expect(state.openCopies, 0);
        expect(
          (await source.readFilePreview(record, field)).text,
          utf8.decode(body),
        );
      } finally {
        if (await File(lease.filePath).exists()) {
          await File(lease.filePath).delete();
        }
        if (await File(moved).exists()) {
          await File(moved).rename(lease.filePath);
        }
        await source.closeOpenFileCopies(record, field);
        await core.NativeInformationDeliveryFiles().cleanup(lease);
      }
      expect(
        (await source.fileActionState(record, field)).openCleanupPending,
        0,
      );
    },
  );
  testWidgets(
    'reopened unknown open is visible; wrong receipt stays frozen; exact result permits copy cleanup',
    (t) async {
      t.view.physicalSize = const Size(1440, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await real(t, () async {
        dispatch.drop = true;
        dispatch.loseStatus = true;
        await expectLater(launch(), fails('unknown_outcome'));
      });
      final detail = await real(t, () => source.readDetail(record));
      (source as _Source).wrong = true;
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: LibraryFile(
                detail: detail,
                fieldKey: field,
                source: source,
              ),
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
      expect(find.text('结束核对并清理临时副本'), findsOneWidget);
      expect(find.text('重新选择原文件并核对'), findsNothing);
      dispatch.loseStatus = false;
      await t.tap(find.text('核对此次操作'));
      await settle(
        t,
        () => find.text('返回的结果与原操作不一致，请继续核对。').evaluate().isNotEmpty,
      );
      expect(find.text('核对此次操作'), findsOneWidget);
      (source as _Source).wrong = false;
      await t.tap(find.text('核对此次操作'));
      await settle(t, () => find.text('核对此次操作').evaluate().isEmpty);
      await t.tap(find.text('结束使用并清理本机打开副本'));
      await settle(
        t,
        () =>
            !File(dispatch.lease!.filePath).existsSync() &&
            find.text('正在读取预览…').evaluate().isEmpty,
      );
      expect(dispatch.count, 1);
      await t.pumpWidget(const SizedBox.shrink());
      await real(t, close);
    },
  );
}
