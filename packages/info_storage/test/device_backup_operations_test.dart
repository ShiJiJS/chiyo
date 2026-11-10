import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_storage/macos_backup_publication.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Map<String, int> counts() => {
  for (final key in [
    'information',
    'credentials',
    'materials',
    'files',
    'fileBytes',
    'directories',
    'tags',
    'templates',
    'plugins',
    'legacyTemplates',
    'revisions',
    'recycled',
    'directoryBatches',
    'grants',
    'operations',
    'hosts',
  ])
    key: 0,
};
Map<String, Object?> command(String id, {String action = 'export'}) => {
  'operationId': id,
  'action': action,
  'expectedVersion': 73,
  'selection': {
    'id': 'selection_$id',
    'name': action == 'saveKey' ? 'recovery.txt' : 'synthetic.aimbackup',
    'kind': action == 'saveKey' ? 'keyOutput' : 'archiveOutput',
    'version': 1,
  },
  'previewToken': null,
};
Matcher fails(String code) =>
    throwsA(isA<StorageFailure>().having((e) => e.code, 'code', code));

void main() {
  late Directory root;
  late DeviceBackupOperations store;
  late String path;
  var closed = true;
  Future<void> open() async {
    store = await DeviceBackupOperations.open(
      path,
      serverId: 'synthetic-server',
    );
    closed = false;
  }

  Future<void> close() async {
    if (!closed) {
      await store.close();
      closed = true;
    }
  }

  Future<List<int>> journalKey() async => Platform.isWindows
      ? (await WindowsDatabaseKeyStore(
          '$path/operations.key',
          privateFile: true,
        ).read())!
      : await File('$path/operations.key').readAsBytes();

  Future<void> privateDirectory(Directory directory) async {
    if (Platform.isWindows) {
      WindowsPrivateFiles.directory(directory);
    } else {
      await directory.create();
      expect(
        (await Process.run('/bin/chmod', ['700', directory.path])).exitCode,
        0,
      );
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('device-backup-journal-');
    root = Directory(await root.resolveSymbolicLinks());
    path = '${root.path}/journal';
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });

  Future<({String id, String digest, String stage, String output, int version})>
  prepare(
    String id,
    List<int> bytes, {
    String action = 'export',
    bool wrongBytes = false,
  }) async {
    final c = command(id, action: action);
    expect(await store.record(c), isTrue);
    final digest = sha256.convert(utf8.encode(jsonEncode(c))).toString();
    await store.bindOutput(
      id,
      sha256: sha256.convert(bytes).toString(),
      byteLength: bytes.length,
      counts: action == 'saveKey' ? {} : counts(),
    );
    final dir = Directory('${root.path}/stage-$id');
    await privateDirectory(dir);
    final output = '${root.path}/${(c['selection'] as Map)['name']}';
    final version = await store.publication.operationVersion();
    await store.publication.registerOutputStaging(
      operationId: id,
      commandDigest: digest,
      expectedVersion: version,
      action: BackupOutputAction.values.byName(action),
      directory: dir.path,
      destination: output,
    );
    final received = wrongBytes ? List.filled(bytes.length, 255) : bytes;
    if (action == 'saveKey') {
      MacBackupPublicationFiles.writeRecoveryKey(
        '${dir.path}/prepared',
        received,
      );
    } else {
      MacBackupPublicationFiles.writeBackupFile(
        '${dir.path}/prepared',
        received,
      );
    }
    final publication = MacBackupPublicationFiles.prepare(
      '${dir.path}/prepared',
      output,
    );
    await store.publication.prepareOutputOperation(
      operationId: id,
      commandDigest: digest,
      expectedVersion: version,
      action: BackupOutputAction.values.byName(action),
      publication: publication,
    );
    return (
      id: id,
      digest: digest,
      stage: dir.path,
      output: output,
      version: version,
    );
  }

  Map<String, Object?> receipt(
    String id,
    String digest, {
    String action = 'export',
  }) => {
    'wireVersion': 1,
    'operationId': id,
    'commandDigest': digest,
    'action': action,
    'expectedVersion': 73,
    'version': 74,
    'resource': {
      'id': 'saved_$id',
      'name': action == 'saveKey' ? 'recovery.txt' : 'synthetic.aimbackup',
      'kind': action == 'saveKey' ? 'keyInput' : 'archiveInput',
      'version': 1,
    },
    'counts': action == 'saveKey' ? null : counts(),
  };

  test(
    'Windows staging rejects an output inside its own private root with backslashes/case aliases',
    () async {
      final output = '${root.path}/outside.bin';
      final staging = MacBackupPublicationFiles.createWindowsStaging(output);
      try {
        await expectLater(
          store.publication.registerOutputStaging(
            operationId: 'inside',
            commandDigest: 'a' * 64,
            expectedVersion: await store.publication.operationVersion(),
            action: BackupOutputAction.export,
            directory: staging.path,
            destination: '${staging.path}\\nested.bin'.toUpperCase(),
          ),
          fails('invalid_backup_operation_receipt'),
        );
        expect(await store.publication.pendingOutputStaging(), isEmpty);
      } finally {
        MacBackupPublicationFiles.cleanupStaging(staging);
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'Windows occupied backup anchor retains cleanup facts until consumer releases it',
    () async {
      final p = await prepare('occupied-backup', List.filled(8192, 38));
      await store.publication.publishOutputOperation(p.id);
      await store.settle(p.id, receipt(p.id, p.digest));
      final kernel = DynamicLibrary.open('kernel32.dll');
      final openFile = kernel
          .lookupFunction<
            IntPtr Function(
              Pointer<Utf16>,
              Uint32,
              Uint32,
              Pointer<Void>,
              Uint32,
              Uint32,
              IntPtr,
            ),
            int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
          >('CreateFileW');
      final closeHandle = kernel
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'CloseHandle',
          );
      final path = File('${p.stage}/prepared').path.toNativeUtf16();
      final handle = openFile(path, 0x80000000, 3, nullptr, 3, 0, 0);
      calloc.free(path);
      expect(handle != -1, true);
      try {
        await expectLater(
          store.publication.cleanupRegisteredOutputStaging(p.id),
          fails('backup_cleanup_pending'),
        );
        expect(
          (await store.publication.pendingOutputStaging()).contains(p.id),
          true,
        );
        expect(await Directory(p.stage).exists(), true);
        expect(await File(p.output).length(), 8192);
      } finally {
        closeHandle(handle);
      }
      await close();
      await open();
      await store.publication.cleanupRegisteredOutputStaging(p.id);
      expect(await Directory(p.stage).exists(), false);
      expect(await File(p.output).length(), 8192);
    },
    skip: !Platform.isWindows,
  );

  test(
    'native backup publication above the ordinary attachment limit survives reopen without a local information database',
    () async {
      final bytes = Uint8List(18 * 1024 * 1024)
        ..fillRange(0, 18 * 1024 * 1024, 107);
      final p = await prepare('large-backup', bytes);
      expect(p.version, 1); // Server expected version is independently 73.
      final saved = await store.publication.publishOutputOperation(p.id);
      expect(saved.commandDigest, p.digest);
      expect(await File(p.output).length(), bytes.length);
      expect(
        sha256.convert(await File(p.output).readAsBytes()).toString(),
        sha256.convert(bytes).toString(),
      );
      await close();
      await open();
      expect((await store.pending()).single.intent.digest, p.digest);
      expect(
        (await store.publication.reconcileOutputOperation(p.id))!.commandDigest,
        p.digest,
      );
      final result = receipt(p.id, p.digest);
      await store.settle(p.id, result);
      expect(await store.pending(), isEmpty);
      await store.publication.cleanupRegisteredOutputStaging(p.id);
      expect(await Directory(p.stage).exists(), isFalse);
      // A durable saved fact is not permission to republish if the user later
      // deletes the output. An exact old command cannot create it again.
      await File(p.output).delete();
      expect(
        (await store.publication.publishOutputOperation(p.id)).commandDigest,
        p.digest,
      );
      expect(await File(p.output).exists(), isFalse);
      expect(await store.record(command(p.id)), isFalse);
      await close();
      await open();
      expect((await store.read(p.id))!.result, result);
      await expectLater(
        store.publication.recoveryKey(),
        throwsA(isA<StorageFailure>()),
      );
      await close();
      final key = await journalKey();
      final db = sqlite3.open('$path/operations.db');
      try {
        db.execute(
          'PRAGMA key = "x\'${key.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\'"',
        );
        expect(
          db
              .select("SELECT name FROM sqlite_master WHERE type='table'")
              .map((r) => r['name']),
          unorderedEquals([
            'backup_operations',
            'device_file_scope',
            'backup_operation_state',
            'device_backup_intents',
          ]),
        );
      } finally {
        db.close();
      }
      expect(
        latin1
            .decode(await File('$path/operations.db').readAsBytes())
            .contains('large-backup'),
        isFalse,
      );
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );

  test(
    'a prepared but never published backup is abandoned after reopen, never resumed',
    () async {
      final p = await prepare('never-published', List.filled(8192, 42));
      await close();
      await open();
      expect(await store.publication.reconcileOutputOperation(p.id), isNull);
      expect(await File(p.output).exists(), isFalse);
      await expectLater(
        store.publication.publishOutputOperation(p.id),
        fails('backup_not_published'),
      );
      await store.settle(p.id, null);
      expect((await store.read(p.id))!.intent.pending, isFalse);
      await store.publication.cleanupRegisteredOutputStaging(p.id);
      expect(await Directory(p.stage).exists(), isFalse);
      expect(await store.record(command(p.id)), isFalse);
      await expectLater(
        store.bindOutput(
          p.id,
          sha256: 'a' * 64,
          byteLength: 8192,
          counts: counts(),
        ),
        fails('operation_conflict'),
      );
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );

  test(
    'a transient Windows reader releases before abandoned staging cleanup finishes',
    () async {
      final p = await prepare('transient-reader', List.filled(8192, 42));
      await close();
      await open();
      expect(await store.publication.reconcileOutputOperation(p.id), isNull);
      await store.settle(p.id, null);
      final reader = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${Directory.current.path}/../info_core/test/support/windows_private_reader.dart',
        '${p.stage}/prepared',
      ]);
      final errors = utf8.decoder.bind(reader.stderr).join();
      try {
        expect(
          await reader.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first,
          'reader-ready',
        );
        await store.publication.cleanupRegisteredOutputStaging(p.id);
        expect(await Directory(p.stage).exists(), isFalse);
        expect(await store.publication.reconcileOutputOperation(p.id), isNull);
        expect(await File(p.output).exists(), isFalse);
      } finally {
        await reader.stdin.close();
        expect(
          await reader.exitCode.timeout(const Duration(seconds: 5)),
          0,
          reason: await errors,
        );
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'publication uncertainty requires the original file identity and cannot be settled as absence',
    () async {
      final p = await prepare('uncertain', List.filled(8192, 19));
      await expectLater(
        store.publication.publishOutputOperation(
          p.id,
          afterPublication: () async {
            throw StateError('synthetic bookmark failure');
          },
        ),
        fails('backup_outcome_unknown'),
      );
      expect(await File(p.output).exists(), isTrue);
      await close();
      await open();
      await File(p.output).delete();
      await expectLater(
        store.publication.reconcileOutputOperation(p.id),
        fails('backup_outcome_unknown'),
      );
      await expectLater(
        store.settle(p.id, null),
        fails('backup_outcome_unknown'),
      );
      await expectLater(
        store.settle(p.id, receipt(p.id, p.digest)),
        fails('backup_outcome_unknown'),
      );
      // Identical content at a new inode is still not proof of the original save.
      await File(p.output).writeAsBytes(List.filled(8192, 19));
      await expectLater(
        store.publication.reconcileOutputOperation(p.id),
        fails('backup_outcome_unknown'),
      );
      expect((await store.pending()).single.intent.pending, isTrue);
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );

  test(
    'a published recovery-key file is reconciled through the original publisher without storing its plaintext in the journal',
    () async {
      final text = 'aim-recovery-v1:${base64UrlEncode(List.filled(32, 37))}\n';
      final p = await prepare(
        'key-output',
        utf8.encode(text),
        action: 'saveKey',
      );
      await expectLater(
        store.publication.publishOutputOperation(
          p.id,
          afterPublication: () async {
            throw StateError('synthetic loss');
          },
        ),
        fails('backup_outcome_unknown'),
      );
      await close();
      await open();
      expect(
        (await store.publication.reconcileOutputOperation(p.id))!.commandDigest,
        p.digest,
      );
      expect(await File(p.output).readAsString(), text);
      await store.settle(p.id, receipt(p.id, p.digest, action: 'saveKey'));
      await store.publication.cleanupRegisteredOutputStaging(p.id);
      await close();
      final key = await journalKey();
      final db = sqlite3.open('$path/operations.db');
      try {
        db.execute(
          'PRAGMA key = "x\'${key.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\'"',
        );
        for (final table in ['backup_operations', 'device_backup_intents']) {
          expect(
            db
                .select('SELECT payload FROM $table')
                .map((r) => r['payload'])
                .join()
                .contains(text.trim()),
            isFalse,
          );
        }
      } finally {
        db.close();
      }
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );

  test(
    'pending commands and metadata are immutable, bounded and scoped to the configured server',
    () async {
      final c = command('pending');
      expect(await store.record(c), isTrue);
      expect(await store.record(c), isFalse);
      await expectLater(
        store.record({...c, 'expectedVersion': 74}),
        fails('operation_conflict'),
      );
      await expectLater(
        store.record(command('second')),
        fails('backup_outcome_unknown'),
      );
      await expectLater(
        store.record({...c, 'recoveryKey': 'SYNTHETIC_RAW_KEY'}),
        fails('invalid_backup_operation'),
      );
      await expectLater(
        store.bindOutput(
          'pending',
          sha256: 'a' * 64,
          byteLength: 256 * 1024 * 1024 + 1,
          counts: counts(),
        ),
        fails('invalid_backup_operation_receipt'),
      );
      await store.bindOutput(
        'pending',
        sha256: 'a' * 64,
        byteLength: 8192,
        counts: counts(),
      );
      await expectLater(
        store.bindOutput(
          'pending',
          sha256: 'b' * 64,
          byteLength: 8192,
          counts: counts(),
        ),
        fails('operation_conflict'),
      );
      await close();
      await expectLater(
        DeviceBackupOperations.open(path, serverId: 'other-server'),
        fails('device_journal_scope_changed'),
      );
      await open();
      await store.settle('pending', null);
      expect(await store.pending(), isEmpty);
    },
  );
  test(
    'bytes differing from the pinned server manifest cannot be published',
    () async {
      await expectLater(
        prepare('wrong-bytes', List.filled(8192, 7), wrongBytes: true),
        fails('backup_changed'),
      );
      expect(await File('${root.path}/synthetic.aimbackup').exists(), isFalse);
      expect(
        await store.publication.outputOperationPhase('wrong-bytes'),
        isNull,
      );
      await store.settle('wrong-bytes', null);
      await store.publication.cleanupRegisteredOutputStaging('wrong-bytes');
      expect(
        await Directory('${root.path}/stage-wrong-bytes').exists(),
        isFalse,
      );
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );

  test(
    'version-1 device journal migrates its native receipts without opening information data or touching a wrong-server journal',
    () async {
      await close();
      var original = await DeviceFileOperations.open(
        path,
        serverId: 'synthetic-server',
      );
      final dir = Directory('${root.path}/original-stage');
      await privateDirectory(dir);
      final bytes = [0, 1, 128, 255];
      await original.fileOutputs.reserve(
        operationId: 'old-file',
        commandDigest: 'a' * 64,
        itemId: 'original-item',
        fieldKey: 'file',
        reference: InformationAttachmentRef('original-attachment', 1),
        root: MacBackupPublicationFiles.captureStaging(dir.path),
        destination: '${root.path}/old.bin',
        length: bytes.length,
        contentDigest: sha256.convert(bytes).toString(),
      );
      await original.fileOutputs.prepare('old-file', bytes);
      expect(
        (await original.fileOutputs.publish('old-file')).completed,
        isTrue,
      );
      await original.close();
      final key = await journalKey();
      final db = sqlite3.open('$path/operations.db');
      try {
        db.execute(
          'PRAGMA key = "x\'${key.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\'"',
        );
        db.execute('DROP TABLE device_backup_intents');
        db.execute('DROP TABLE backup_operation_state');
        db.execute('PRAGMA user_version=1');
      } finally {
        db.close();
      }
      final before = await File('$path/operations.db').readAsBytes();
      await expectLater(
        DeviceBackupOperations.open(path, serverId: 'wrong-server'),
        fails('device_journal_scope_changed'),
      );
      expect(await File('$path/operations.db').readAsBytes(), before);
      await open();
      expect(await store.pending(), isEmpty);
      expect(await store.publication.operationVersion(), 1);
      await close();
      original = await DeviceFileOperations.open(
        path,
        serverId: 'synthetic-server',
      );
      try {
        expect(
          (await original.fileOutputs.status('old-file'))!.completed,
          isTrue,
        );
        expect(await File('${root.path}/old.bin').readAsBytes(), bytes);
      } finally {
        await original.close();
      }
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );
}
