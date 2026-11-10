@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

Matcher failure(String code) =>
    throwsA(isA<StorageFailure>().having((e) => e.code, 'code', code));

void main() {
  test(
    'separate first-launch processes serialize without replacing the winning key',
    () async {
      final root = await Directory.systemTemp.createTemp('并发 journal ');
      addTearDown(() => root.delete(recursive: true));
      final path = '${root.path}/device';
      // Build once before the race. Concurrent `dart run` also races the SDK's
      // native-asset copier, which is unrelated to journal locking.
      final helper = '${root.path}/helper';
      final build = await Process.run(Platform.resolvedExecutable, [
        'build',
        'cli',
        '--target',
        'test/support/windows_journal_writer.dart',
        '--output',
        helper,
      ]);
      expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
      final results = await Future.wait(
        List.generate(
          4,
          (_) => Process.run('$helper/bundle/bin/windows_journal_writer.exe', [
            path,
          ]),
        ),
      );
      var opened = 0;
      for (final result in results) {
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        if (result.stdout.toString().contains('"opened":true')) opened++;
      }
      expect(opened, greaterThan(0));
      final key = await File('$path/operations.key').readAsBytes();
      final store = await DeviceBackupOperations.open(
        path,
        serverId: 'original-server',
      );
      try {
        expect(
          (await store.read('first_launch'))!.intent.operationId,
          'first_launch',
        );
      } finally {
        await store.close();
      }
      expect(await File('$path/operations.key').readAsBytes(), key);
    },
  );

  test(
    'SQLCipher device receipts reopen with DPAPI key and reject lost original facts',
    () async {
      final root = await Directory.systemTemp.createTemp('操作 journal space ');
      addTearDown(() => root.delete(recursive: true));
      final path = '${root.path}/device';
      var store = await DeviceBackupOperations.open(
        path,
        serverId: 'original-server',
      );
      var closed = false;
      addTearDown(() async {
        if (!closed) await store.close();
      });
      final command = <String, Object?>{
        'operationId': 'original-operation',
        'action': 'export',
        'expectedVersion': 73,
        'selection': {
          'id': 'original_selection',
          'name': 'original.aimbackup',
          'kind': 'archiveOutput',
          'version': 1,
        },
        'previewToken': null,
      };
      expect(await store.record(command), isTrue);
      await expectLater(
        DeviceBackupOperations.open(path, serverId: 'original-server'),
        failure('device_journal_in_use'),
      );
      await store.close();
      closed = true;
      final keyFile = File('$path/operations.key'),
          dbFile = File('$path/operations.db');
      final keyBytes = await keyFile.readAsBytes(),
          dbBytes = await dbFile.readAsBytes();
      expect(keyBytes.length, greaterThan(32));
      expect(latin1.decode(dbBytes), isNot(contains('original-operation')));
      WindowsPrivateFiles.verify(keyFile.path);
      WindowsPrivateFiles.verify(dbFile.path);
      store = await DeviceBackupOperations.open(
        path,
        serverId: 'original-server',
      );
      closed = false;
      expect((await store.read('original-operation'))!.intent.command, command);
      expect(await store.record(command), isFalse);
      await store.close();
      closed = true;
      await expectLater(
        DeviceBackupOperations.open(path, serverId: 'wrong-server'),
        failure('device_journal_scope_changed'),
      );
      expect(await dbFile.readAsBytes(), dbBytes);
      await keyFile.rename('$path/saved-key');
      await expectLater(
        DeviceBackupOperations.open(path, serverId: 'original-server'),
        failure('key_unavailable'),
      );
      expect(await keyFile.exists(), isFalse);
      await File('$path/saved-key').rename(keyFile.path);
      final replacement = List<int>.filled(32, 47);
      WindowsPrivateFiles.write(keyFile, [
        73,
        65,
        75,
        1,
        ...WindowsDataProtection.crypt(replacement, protect: true),
      ]);
      await expectLater(
        DeviceBackupOperations.open(path, serverId: 'original-server'),
        failure('device_journal_unavailable'),
      );
      expect(await dbFile.readAsBytes(), dbBytes);
      WindowsPrivateFiles.write(keyFile, keyBytes);
      await dbFile.rename('$path/saved-db');
      await expectLater(
        DeviceBackupOperations.open(path, serverId: 'original-server'),
        failure('device_journal_missing'),
      );
      expect(await dbFile.exists(), isFalse);
      expect(await keyFile.readAsBytes(), keyBytes);
      await File('$path/saved-db').rename(dbFile.path);
      WindowsPrivateFiles.write(dbFile, []);
      await expectLater(
        DeviceBackupOperations.open(path, serverId: 'original-server'),
        failure('device_journal_unavailable'),
      );
      expect(await dbFile.length(), 0);
      WindowsPrivateFiles.write(dbFile, dbBytes);
      await dbFile.rename('$path/saved-db');
      await keyFile.rename('$path/saved-key');
      await expectLater(
        DeviceBackupOperations.open(path, serverId: 'original-server'),
        failure('device_journal_missing'),
      );
      expect(await dbFile.exists(), isFalse);
      expect(await keyFile.exists(), isFalse);
      await File('$path/saved-db').rename(dbFile.path);
      await File('$path/saved-key').rename(keyFile.path);
      store = await DeviceBackupOperations.open(
        path,
        serverId: 'original-server',
      );
      closed = false;
      expect((await store.read('original-operation'))!.intent.command, command);
      await store.close();
      closed = true;
    },
  );
}
