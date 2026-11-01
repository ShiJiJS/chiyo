@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/workspace/library_file_dialogs.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:info_desktop/information_files.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/owner_workspace_file_selections.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async {
    key = List.of(value);
  }
}

class _Picker implements InformationFilePicker {
  String? next;
  Completer<String?>? pending;
  @override
  Future<String?> choose() async =>
      pending == null ? next : await pending!.future;
  @override
  Future<String?> saveAs(String name) async => null;
}

class _Source extends OwnerWorkspaceSource {
  _Source({required super.owner, required super.fileSelections})
    : super(refreshInterval: Duration.zero);
  bool dropReply = false, wrongReceipt = false;
  @override
  Future<WorkspaceRecordRef> importFile(WorkspaceFileImport input) async {
    final result = await super.importFile(input);
    if (dropReply) {
      dropReply = false;
      throw const WorkspaceFailure(
        'unknown_outcome',
        'Synthetic lost response',
      );
    }
    return result;
  }

  @override
  Future<WorkspaceFileOperationReceipt?> fileOperationReceipt(String id) async {
    final result = await super.fileOperationReceipt(id);
    if (wrongReceipt && result != null) {
      return WorkspaceFileOperationReceipt(
        result.record,
        result.file,
        commandDigest: 'f' * 64,
      );
    }
    return result;
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
  late OwnerWorkspaceFileSelections files;
  int sequence = 0;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      '${root.path}/library',
      keys,
    );
    service = core.InformationService(repository: repo);
    files = OwnerWorkspaceFileSelections(service.owner, picker: picker);
    source = _Source(owner: service.owner, fileSelections: files);
  }

  Future<void> close() async {
    await source.dispose();
    await service.close();
    await repo.close();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-file-write-');
    keys = _Keys();
    picker = _Picker();
    sequence = 0;
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  Future<WorkspaceFileCandidate> pick(String text) async {
    final input = File('${root.path}/合成文件-${++sequence}.txt');
    await input.writeAsString(text);
    picker.next = input.path;
    return (await files.pick())!;
  }

  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
  void sql(String query) {
    final db = sqlite3.open('${root.path}/library/library.db');
    final key = keys.key!
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    try {
      db.execute('PRAGMA key = "x\'$key\'"');
      db.execute(query);
    } finally {
      db.close();
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
        await t.pumpAndSettle();
        return;
      }
    }
    fail('Owner file UI did not settle');
  }

  testWidgets(
    'real import controls keep lost response frozen, reject wrong receipt, then reconcile',
    (t) async {
      t.view.physicalSize = const Size(1440, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await real(t, () => pick('widget-original'));
      final catalog = await real(t, source.loadCatalog);
      (source as _Source).dropReply = true;
      WorkspaceRecordRef? imported;
      var finished = false;
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: DesktopButton(
                onPressed: () async {
                  imported = await showLibraryFileImport(
                    context,
                    source,
                    catalog,
                    () => files.pick(),
                    null,
                  );
                  finished = true;
                },
                child: const Text('Open import'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('Open import'));
      await settle(
        t,
        () => find
            .byKey(const ValueKey('library-file-import-submit'))
            .evaluate()
            .isNotEmpty,
      );
      await t.tap(find.byKey(const ValueKey('library-file-import-submit')));
      await settle(t, () => find.text('核对导入结果').evaluate().isNotEmpty);
      expect(finished, isFalse);
      expect(service.owner.information.length, 1);
      final cancel = find.widgetWithText(DesktopButton, '取消');
      expect(t.widget<DesktopButton>(cancel).onPressed, isNull);
      (source as _Source).wrongReceipt = true;
      await t.tap(find.text('核对导入结果'));
      await settle(
        t,
        () => find.text('仍无法确认导入结果，请稍后核对。').evaluate().isNotEmpty,
      );
      expect(finished, isFalse);
      (source as _Source).wrongReceipt = false;
      await t.tap(find.text('核对导入结果'));
      await settle(t, () => finished);
      expect(imported, isNotNull);
      expect(service.owner.information.length, 1);
      expect(
        (await real(t, () => source.readFilePreview(imported!, 'file'))).text,
        'widget-original',
      );
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'selection stages encrypted original; import is durable, exact and replay safe',
    () async {
      final selected = await pick('private-synthetic-original');
      expect(service.owner.information, isEmpty);
      expect((await service.owner.informationAttachmentUsage()).stagedFiles, 1);
      picker.next = null;
      expect(await files.pick(), isNull);
      final command = WorkspaceFileImport(
        operationId: 'import',
        selectionId: selected.selectionId,
        name: '普通附件',
      );
      final record = await source.importFile(command);
      final detail = await source.readDetail(record);
      expect(detail.record.type.id, 'file');
      expect(
        (await source.readFilePreview(record, 'file')).text,
        'private-synthetic-original',
      );
      final receipt = await source.fileOperationReceipt('import');
      expect(receipt!.commandDigest, command.digest);
      final persisted = (await repo.informationRecordReceipt('import'))!;
      expect(
        jsonEncode(persisted.toJson()),
        isNot(contains('private-synthetic-original')),
      );
      expect(jsonEncode(persisted.toJson()), isNot(contains(root.path)));
      expect((await service.owner.informationAttachmentUsage()).stagedFiles, 0);
      for (final f in root.listSync().whereType<File>()) {
        await f.delete();
      }
      await close();
      await open();
      expect(await source.importFile(command), record);
      expect(service.owner.information.length, 1);
      expect((await source.fileOperationReceipt('import'))!.file, receipt.file);
      await expectLater(
        source.importFile(
          WorkspaceFileImport(
            operationId: 'import',
            selectionId: selected.selectionId,
            name: 'different',
          ),
        ),
        fails('operation_conflict'),
      );
    },
  );
  test(
    'replace and restore create new versions preserving mixed fields and layout',
    () async {
      final selected = await pick('version-one');
      final record = await source.importFile(
        WorkspaceFileImport(
          operationId: 'import',
          selectionId: selected.selectionId,
          name: '混合资料',
        ),
      );
      var item = service.owner.information.single;
      final file = item.fields.single;
      await service.owner.saveInformationRecord(
        'add-text',
        core.InformationDraftInput(
          itemId: item.id,
          baseVersion: item.version,
          name: item.name,
          description: item.description,
          fields: [
            core.InformationDraftField.retainedFile(
              file.name,
              file.description,
              file.attachment,
              fieldId: file.id,
            ),
            const core.InformationDraftField.text('说明', '', 'retained-text'),
          ],
        ),
      );
      item = service.owner.information.single;
      final text = item.fields.last;
      final replacement = await pick('version-two');
      final command = WorkspaceFileChange(
        operationId: 'replace',
        record: record,
        fieldKey: 'file',
        expectedRecordVersion: item.version,
        expectedFileVersion: 1,
        kind: WorkspaceFileChangeKind.replace,
        selectionId: replacement.selectionId,
      );
      final changed = await source.changeFile(command);
      expect(changed.version, 2);
      expect(changed.id, file.attachment!.attachmentId);
      item = service.owner.information.single;
      expect(item.fields.last.id, text.id);
      expect(item.fields.last.value, 'retained-text');
      expect(item.fields.first.id, file.id);
      expect(item.layout!.typeId, 'file');
      final restore = WorkspaceFileChange(
        operationId: 'restore',
        record: record,
        fieldKey: 'file',
        expectedRecordVersion: item.version,
        expectedFileVersion: 2,
        kind: WorkspaceFileChangeKind.restore,
        restoreVersion: 1,
      );
      final restored = await source.changeFile(restore);
      expect(restored.version, 3);
      expect(restored.id, changed.id);
      expect(
        (await source.readFilePreview(record, 'file')).text,
        'version-one',
      );
      expect(
        (await source.readFilePreview(record, 'file', version: 2)).text,
        'version-two',
      );
      await close();
      await open();
      expect(await source.changeFile(restore), restored);
      expect(
        (await source.loadFileHistory(
          record,
          'file',
        )).versions.map((v) => v.ref.version),
        [3, 2, 1],
      );
      expect(
        service.owner.information.single.fields.last.value,
        'retained-text',
      );
    },
  );
  test(
    'receipt insertion failure rolls back body and item; original staged retry succeeds',
    () async {
      final selected = await pick('rollback-original');
      final c = WorkspaceFileImport(
        operationId: 'rollback',
        selectionId: selected.selectionId,
        name: '合成',
      );
      sql(
        "CREATE TRIGGER fail_file_receipt BEFORE INSERT ON information_record_operations BEGIN SELECT RAISE(ABORT,'injected'); END",
      );
      await expectLater(source.importFile(c), fails('unavailable'));
      expect(service.owner.information, isEmpty);
      expect(await source.fileOperationReceipt('rollback'), isNull);
      expect((await service.owner.informationAttachmentUsage()).stagedFiles, 1);
      sql('DROP TRIGGER fail_file_receipt');
      await source.importFile(c);
      expect(service.owner.information.length, 1);
    },
  );
  test(
    'replacement checks record/file versions and existing non-file operation IDs',
    () async {
      final selected = await pick('first');
      final record = await source.importFile(
        WorkspaceFileImport(
          operationId: 'import',
          selectionId: selected.selectionId,
          name: '合成',
        ),
      );
      final next = await pick('second');
      await expectLater(
        source.changeFile(
          WorkspaceFileChange(
            operationId: 'stale',
            record: record,
            fieldKey: 'file',
            expectedRecordVersion: 1,
            expectedFileVersion: 99,
            kind: WorkspaceFileChangeKind.replace,
            selectionId: next.selectionId,
          ),
        ),
        fails('conflict'),
      );
      expect((await source.readFilePreview(record, 'file')).text, 'first');
      await service.owner.saveInformationRecord(
        'normal',
        core.InformationDraftInput(
          name: '正常文字',
          description: '',
          fields: [const core.InformationDraftField.text('正文', '', 'body')],
        ),
      );
      await expectLater(
        source.importFile(
          WorkspaceFileImport(
            operationId: 'normal',
            selectionId: next.selectionId,
            name: '合成',
          ),
        ),
        fails('operation_conflict'),
      );
    },
  );
  test(
    'portable backup includes original bytes but excludes local file operation proofs',
    () async {
      final selected = await pick('portable-only-original');
      final record = await source.importFile(
        WorkspaceFileImport(
          operationId: 'portable',
          selectionId: selected.selectionId,
          name: '合成',
        ),
      );
      final recovery = await repo.backups.enable();
      await repo.backups.saveRecoveryKeyTo('${root.path}/recovery.txt');
      await service.owner.exportLibrary(
        () => repo.backups.exportTo('${root.path}/backup.aimbackup'),
      );
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
      );
      final targetService = core.InformationService(repository: target);
      try {
        final preview = await target.backups.inspect(
          '${root.path}/backup.aimbackup',
          recovery,
        );
        await targetService.owner.restoreLibrary(
          () => target.backups.restore(preview),
        );
        expect(await target.informationRecordReceipt('portable'), isNull);
        final item = targetService.owner.information.single;
        expect(item.id, record.id);
        expect(
          utf8.decode(
            (await targetService.owner.readInformationAttachment(
              item.fields.single.attachment!,
            )).bytes,
          ),
          'portable-only-original',
        );
      } finally {
        await targetService.close();
        await target.close();
      }
    },
  );
  test(
    'cancel selection removes encrypted stages without deleting owner original',
    () async {
      final selected = await pick('cancelled');
      final path = picker.next!;
      await source.releaseFileSelection(selected.selectionId);
      expect((await service.owner.informationAttachmentUsage()).stagedFiles, 0);
      expect(File(path).readAsStringSync(), 'cancelled');
      expect(service.owner.information, isEmpty);
    },
  );
  test('malformed file receipt remains unknown, never absent', () async {
    final selected = await pick('proof');
    await source.importFile(
      WorkspaceFileImport(
        operationId: 'proof',
        selectionId: selected.selectionId,
        name: '合成',
      ),
    );
    sql(
      "UPDATE information_record_operations SET payload=json_set(payload,'\$.file.command.digest','broken') WHERE operation_id='proof'",
    );
    await expectLater(
      source.fileOperationReceipt('proof'),
      fails('unknown_outcome'),
    );
  });
  test(
    'reselect invalidates old handle and late closed panel never writes',
    () async {
      final first = await pick('one');
      await pick('two');
      await expectLater(
        source.importFile(
          WorkspaceFileImport(
            operationId: 'old',
            selectionId: first.selectionId,
            name: '合成',
          ),
        ),
        fails('selection_expired'),
      );
      expect((await service.owner.informationAttachmentUsage()).stagedFiles, 1);
      picker.pending = Completer();
      final pending = files.pick();
      await source.dispose();
      picker.pending!.complete(picker.next);
      await expectLater(pending, fails('unavailable'));
      expect(service.owner.information, isEmpty);
      expect((await service.owner.informationAttachmentUsage()).stagedFiles, 0);
    },
  );
}
