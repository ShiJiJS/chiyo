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

class _Dispatcher implements OwnerFileOpenDispatcher {
  InformationDeliveryLease? lease;
  int launches = 0;
  OwnerFileDispatchOutcome? observation;
  @override
  Future<OwnerFileDispatchOutcome> open(
    String id,
    String digest,
    InformationDeliveryLease value,
    int length,
    String hash,
  ) async {
    launches++;
    lease = value;
    await NativeInformationDeliveryFiles().verify(value, length, hash);
    observation = OwnerFileDispatchOutcome.opened;
    throw StateError('synthetic dropped dispatch response');
  }

  @override
  Future<OwnerFileDispatchOutcome?> status(String id, String digest) async =>
      observation;
}

void main() {
  Matcher failure(String code) =>
      throwsA(isA<StorageFailure>().having((e) => e.code, 'code', code));
  test(
    'device journal is encrypted, private, scoped and locked without an information library',
    () async {
      var root = await Directory.systemTemp.createTemp('device-files-store-');
      root = Directory(await root.resolveSymbolicLinks());
      final path = '${root.path}/device';
      var store = await DeviceFileOperations.open(
        path,
        serverId: 'synthetic-server-A',
      );
      var closed = false;
      addTearDown(() async {
        if (!closed) await store.close();
        await root.delete(recursive: true);
      });
      if (Platform.isWindows) {
        WindowsPrivateFiles.verify('$path/operations.key');
        WindowsPrivateFiles.verify(path, directory: true);
      } else {
        expect((await File('$path/operations.key').stat()).mode & 0x3F, 0);
        expect((await Directory(path).stat()).mode & 0x3F, 0);
      }
      expect(await store.fileOutputs.status('absent'), isNull);
      await expectLater(
        DeviceFileOperations.open(path, serverId: 'synthetic-server-A'),
        failure('device_journal_in_use'),
      );
      await store.close();
      closed = true;
      final key = Platform.isWindows
          ? (await WindowsDatabaseKeyStore(
              '$path/operations.key',
              privateFile: true,
            ).read())!
          : await File('$path/operations.key').readAsBytes();
      final db = sqlite3.open('$path/operations.db');
      try {
        final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        db.execute('PRAGMA key = "x\'$hex\'"');
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
      final before = await File('$path/operations.db').readAsBytes();
      expect(latin1.decode(before), isNot(contains('synthetic-server-A')));
      await expectLater(
        DeviceFileOperations.open(path, serverId: 'synthetic-server-B'),
        failure('device_journal_scope_changed'),
      );
      expect(await File('$path/operations.db').readAsBytes(), before);
      await File('$path/operations.key').rename('$path/key-saved');
      await expectLater(
        DeviceFileOperations.open(path, serverId: 'synthetic-server-A'),
        failure('key_unavailable'),
      );
      expect(await File('$path/operations.key').exists(), isFalse);
      await File('$path/key-saved').rename('$path/operations.key');
      if (Platform.isWindows) {
        expect(
          (await Process.run('icacls.exe', [
            '$path/operations.key',
            '/grant',
            '*S-1-1-0:R',
          ])).exitCode,
          0,
        );
      } else {
        await Process.run('chmod', ['644', '$path/operations.key']);
      }
      await expectLater(
        DeviceFileOperations.open(path, serverId: 'synthetic-server-A'),
        failure('key_unavailable'),
      );
      if (Platform.isWindows) {
        expect(
          (await Process.run('icacls.exe', [
            '$path/operations.key',
            '/remove:g',
            '*S-1-1-0',
          ])).exitCode,
          0,
        );
      } else {
        await Process.run('chmod', ['600', '$path/operations.key']);
      }
      store = await DeviceFileOperations.open(
        path,
        serverId: 'synthetic-server-A',
      );
      closed = false;
      expect(await store.fileOutputs.pending(), isEmpty);
      await store.close();
      closed = true;
      await File('$path/operations.db').rename('$path/db-saved');
      if (Platform.isWindows) {
        // NTFS hard links need no symlink privilege/system developer setting.
        // The production private-file check must reject the second link.
        final create = DynamicLibrary.open('kernel32.dll')
            .lookupFunction<
              Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
              int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>)
            >('CreateHardLinkW');
        final name = '$path/operations.db'.toNativeUtf16(),
            target = '$path/db-saved'.toNativeUtf16();
        try {
          expect(create(name, target, nullptr), 1);
        } finally {
          calloc.free(name);
          calloc.free(target);
        }
      } else {
        await Link('$path/operations.db').create('$path/db-saved');
      }
      await expectLater(
        DeviceFileOperations.open(path, serverId: 'synthetic-server-A'),
        failure('device_journal_unavailable'),
      );
      expect(await File('$path/db-saved').readAsBytes(), before);
    },
  );

  test(
    'existing publication and open coordinators recover device-only receipts without repeating actions',
    () async {
      var root = await Directory.systemTemp.createTemp('device-files-actions-');
      root = Directory(await root.resolveSymbolicLinks());
      final path = '${root.path}/device';
      var store = await DeviceFileOperations.open(
        path,
        serverId: 'synthetic-server',
      );
      final destination = '${root.path}/user-saved.txt';
      final stage = await root.createTemp('own-stage-');
      final bytes = Uint8List.fromList(
        utf8.encode('SYNTHETIC_REMOTE_ORIGINAL'),
      );
      final hash = sha256.convert(bytes).toString();
      final dispatcher = _Dispatcher();
      addTearDown(() async {
        await store.fileOpens.maintain(closeAll: true);
        await store.close();
        await root.delete(recursive: true);
      });
      await store.fileOutputs.reserve(
        operationId: 'save-original',
        commandDigest: '1' * 64,
        itemId: 'record',
        fieldKey: 'file',
        reference: InformationAttachmentRef('attachment', 2),
        root: MacBackupPublicationFiles.captureStaging(stage.path),
        destination: destination,
        length: bytes.length,
        contentDigest: hash,
      );
      await store.fileOutputs.prepare('save-original', bytes);
      expect(
        (await store.fileOutputs.publish('save-original')).completed,
        isTrue,
      );
      await store.fileOutputs.cleanup('save-original');
      expect(await File(destination).readAsBytes(), bytes);
      await store.fileOpens.prepare(
        operationId: 'open-original',
        commandDigest: '2' * 64,
        itemId: 'record',
        fieldKey: 'file',
        reference: InformationAttachmentRef('attachment', 2),
        fileName: 'original.txt',
        safeName: 'attachment.txt',
        bytes: bytes,
        sha256: hash,
      );
      await expectLater(
        store.fileOpens.open('open-original', dispatcher),
        throwsStateError,
      );
      expect(dispatcher.launches, 1);
      expect(await File(dispatcher.lease!.filePath).readAsBytes(), bytes);
      await store.close();
      store = await DeviceFileOperations.open(
        path,
        serverId: 'synthetic-server',
      );
      expect(
        (await store.fileOutputs.status('save-original'))!.completed,
        isTrue,
      );
      expect(
        (await store.fileOpens.status('open-original'))!.uncertain,
        isTrue,
      );
      final outcome = dispatcher.observation;
      dispatcher.observation = null;
      await expectLater(
        store.fileOpens.reconcile('open-original', dispatcher),
        failure('file_outcome_unknown'),
      );
      dispatcher.observation = outcome;
      expect(
        (await store.fileOpens.reconcile(
          'open-original',
          dispatcher,
        ))!.completed,
        isTrue,
      );
      expect(dispatcher.launches, 1);
      expect(
        (await store.fileOutputs.reconcile('save-original'))!.completed,
        isTrue,
      );
      await store.fileOpens.close('open-original');
      expect(await File(dispatcher.lease!.filePath).exists(), isFalse);
      expect(await File(destination).readAsBytes(), bytes);
      // Old operation IDs still cannot be repurposed across output and open.
      await expectLater(
        store.fileOpens.prepare(
          operationId: 'save-original',
          commandDigest: '3' * 64,
          itemId: 'record',
          fieldKey: 'file',
          reference: InformationAttachmentRef('attachment', 2),
          fileName: 'original.txt',
          safeName: 'attachment.txt',
          bytes: bytes,
          sha256: hash,
        ),
        failure('operation_conflict'),
      );
      final stage2 = await root.createTemp('own-stage-');
      await store.fileOutputs.reserve(
        operationId: 'no-overwrite',
        commandDigest: '4' * 64,
        itemId: 'record',
        fieldKey: 'file',
        reference: InformationAttachmentRef('attachment', 2),
        root: MacBackupPublicationFiles.captureStaging(stage2.path),
        destination: destination,
        length: bytes.length,
        contentDigest: hash,
      );
      await store.fileOutputs.prepare('no-overwrite', bytes);
      expect(
        (await store.fileOutputs.publish('no-overwrite')).completed,
        isFalse,
      );
      await store.fileOutputs.cleanup('no-overwrite');
      expect(await File(destination).readAsBytes(), bytes);
    },
    testOn: 'mac-os',
  );
}
