import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:info_storage/info_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/workspace/owner_workspace_backup_files.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Picker extends BackupFilePicker {
  Future<String?> Function() next = () async => null;
  @override
  Future<String?> recoveryKeyOutput() => next();
  @override
  Future<String?> backupOutput() => next();
  @override
  Future<String?> backupInput() => next();
  @override
  Future<String?> recoveryKeyInput() => next();
}

String nativePath(String path) =>
    Platform.isWindows ? 'C:${path.replaceAll('/', r'\')}' : path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InformationService service;
  late _Picker picker;
  late OwnerWorkspaceBackupFiles files;
  setUp(() {
    service = InformationService(repository: MemoryInformationRepository([]));
    picker = _Picker();
    files = OwnerWorkspaceBackupFiles(owner: service.owner, picker: picker);
  });
  tearDown(() async {
    files.dispose();
    await service.close();
  });
  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));

  test(
    'native backup scope channel preserves capabilities and hides platform diagnostics',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      const channel = MethodChannel('agent_info_manage/backup_files');
      const native = NativeBackupFilePicker();
      final calls = <MethodCall>[];
      var denied = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (denied) {
              throw PlatformException(
                code: 'native',
                message: '/private/original-key.txt',
              );
            }
            return switch (call.method) {
              'prepareBackupStaging' => {
                'directory': '/synthetic/stage',
                'token': 'stage',
                'stagingBookmark': 'AQID',
              },
              'captureBackupOutputBookmark' => 'BAUG',
              'acquireBackupAccess' => 'lease',
              _ => null,
            };
          });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final staging = (await native.prepareStaging('/synthetic/output'))!;
      expect(staging.stagingBookmark, 'AQID');
      expect(await native.outputBookmark(staging), 'BAUG');
      expect(
        await native.acquireAccess({
          'stagingBookmark': 'AQID',
        }, needsOutput: true),
        'lease',
      );
      expect(calls.last.arguments, {
        'access': {'stagingBookmark': 'AQID'},
        'needsOutput': true,
      });
      await native.releaseAccess('lease');
      expect(calls.last.arguments, 'lease');
      expect(await native.reselectOutput('/synthetic/output'), isNull);
      expect(calls.last.method, 'reselectBackupOutput');
      denied = true;
      await expectLater(
        native.reselectOutput('/synthetic/output'),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'backup_access_required',
          ),
        ),
      );
    },
  );

  test(
    'same names remain distinct, cancel retains selection and reselect invalidates old handle',
    () async {
      picker.next = () async =>
          nativePath('/synthetic private/a/中文 备份.aimbackup');
      final first = (await files.pick(WorkspaceBackupPick.archiveInput))!;
      expect(first.name, '中文 备份.aimbackup');
      expect(jsonEncode(first.json), isNot(contains('/synthetic private')));
      picker.next = () async => null;
      expect(await files.pick(WorkspaceBackupPick.archiveInput), isNull);
      expect(
        files.pathFor(first, kind: WorkspaceBackupPick.archiveInput),
        startsWith(nativePath('/synthetic private/a/')),
      );
      picker.next = () async =>
          nativePath('/synthetic private/b/中文 备份.aimbackup');
      final second = (await files.pick(WorkspaceBackupPick.archiveInput))!;
      expect(second.id, isNot(first.id));
      expect(
        () => files.pathFor(first, kind: WorkspaceBackupPick.archiveInput),
        fails('invalid_selection'),
      );
      expect(
        files.pathFor(second, kind: WorkspaceBackupPick.archiveInput),
        startsWith(nativePath('/synthetic private/b/')),
      );
      for (final altered in [
        WorkspaceBackupResource(id: second.id, name: '伪造名称', kind: second.kind),
        WorkspaceBackupResource(
          id: second.id,
          name: second.name,
          kind: second.kind,
          version: 2,
        ),
        WorkspaceBackupResource(
          id: second.id,
          name: second.name,
          kind: WorkspaceBackupPick.keyInput,
        ),
      ]) {
        expect(
          () => files.pathFor(altered, kind: WorkspaceBackupPick.archiveInput),
          fails('invalid_selection'),
        );
      }
      expect(
        () => files.pathFor(second, kind: WorkspaceBackupPick.archiveOutput),
        fails('invalid_selection'),
      );
    },
  );

  test(
    'late native selection cannot survive library replacement or disposal',
    () async {
      final pending = Completer<String?>();
      picker.next = () => pending.future;
      final selected = files.pick(WorkspaceBackupPick.keyInput);
      final refused = expectLater(selected, fails('library_changed'));
      await service.owner.restoreLibrary(() async {});
      pending.complete('/synthetic/key.txt');
      await refused;
      files.dispose();
      files = OwnerWorkspaceBackupFiles(owner: service.owner, picker: picker);
      final closing = Completer<String?>();
      picker.next = () => closing.future;
      final late = files.pick(WorkspaceBackupPick.keyOutput);
      final closed = expectLater(late, fails('unavailable'));
      files.dispose();
      closing.complete('/synthetic/output.txt');
      await closed;
    },
  );

  test(
    'native failure hides private diagnostics, concurrent picks and relative paths are refused',
    () async {
      final pending = Completer<String?>();
      picker.next = () => pending.future;
      final selected = files.pick(WorkspaceBackupPick.archiveOutput);
      await expectLater(
        files.pick(WorkspaceBackupPick.keyInput),
        fails('busy'),
      );
      final failed = expectLater(
        selected,
        throwsA(
          isA<WorkspaceFailure>()
              .having((e) => e.code, 'code', 'selection_failed')
              .having(
                (e) => e.message,
                'message',
                isNot(contains('private-directory')),
              ),
        ),
      );
      pending.completeError(StateError('/private-directory/original-key.txt'));
      await failed;
      picker.next = () async => 'relative/key.txt';
      await expectLater(
        files.pick(WorkspaceBackupPick.keyInput),
        fails('invalid_selection'),
      );
    },
  );

  test(
    'production native picker routes all four purposes without writing or staging',
    () async {
      const channel = MethodChannel('agent_info_manage/backup_files');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return nativePath('/synthetic/${call.method}.txt');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      files.dispose();
      files = OwnerWorkspaceBackupFiles(owner: service.owner);
      for (final kind in WorkspaceBackupPick.values) {
        final selected = (await files.pick(kind))!;
        expect(selected.kind, kind);
        expect(
          files.pathFor(selected, kind: kind),
          nativePath('/synthetic/${calls.last}.txt'),
        );
      }
      expect(calls, [
        'recoveryKeyOutput',
        'backupOutput',
        'backupInput',
        'recoveryKeyInput',
      ]);
    },
  );
}
