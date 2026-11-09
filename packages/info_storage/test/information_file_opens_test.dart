@TestOn('mac-os || windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

class _Dispatch implements OwnerFileOpenDispatcher {
  final results = <String, OwnerFileDispatchOutcome>{};
  var calls = 0;
  var accept = true, dropReply = false;
  @override
  Future<OwnerFileDispatchOutcome> open(
    String id,
    String digest,
    InformationDeliveryLease lease,
    int length,
    String sha256,
  ) async {
    calls++;
    expect(File(lease.filePath).readAsBytesSync().length, length);
    final outcome = accept
        ? OwnerFileDispatchOutcome.opened
        : OwnerFileDispatchOutcome.notOpened;
    results[id] = outcome;
    if (dropReply) throw StateError('synthetic lost response');
    return outcome;
  }

  @override
  Future<OwnerFileDispatchOutcome?> status(String id, String digest) async =>
      results[id];
}

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late _Dispatch dispatch;
  final content = Uint8List.fromList(utf8.encode('仅限合成打开副本'));
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      '${root.path}/library',
      keys,
    );
  }

  Database raw() {
    final db = sqlite3.open('${root.path}/library/library.db');
    final hex = keys.key!
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  void sql(String s) {
    final db = raw();
    try {
      db.execute(s);
    } finally {
      db.close();
    }
  }

  InformationDeliveryLease lease() {
    final db = raw();
    try {
      return InformationDeliveryLease.fromPrivateJson(
        jsonDecode(
              db
                      .select(
                        "SELECT payload FROM backup_operations WHERE operation_id LIKE 'file-open:%'",
                      )
                      .single['payload']
                  as String,
            )['lease']
            as Map<String, dynamic>,
      );
    } finally {
      db.close();
    }
  }

  Future<void> prepare([String id = 'open']) => repo.fileOpens.prepare(
    operationId: id,
    commandDigest: 'a' * 64,
    itemId: 'item',
    fieldKey: 'file',
    reference: InformationAttachmentRef('attachment', 1),
    fileName: '合成.txt',
    safeName: 'attachment.txt',
    bytes: content,
    sha256: sha256.convert(content).toString(),
  );
  Matcher fails(String code) =>
      throwsA(isA<StorageFailure>().having((e) => e.code, 'code', code));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-open-journal-');
    keys = TestKeyStore();
    dispatch = _Dispatch();
    await open();
  });
  tearDown(() async {
    await repo.fileOpens.maintain(closeAll: true);
    await repo.close();
    await root.delete(recursive: true);
  });

  test(
    'real native copy is journaled, verified, opened once and explicitly cleaned',
    () async {
      await prepare();
      final copy = lease();
      expect(File(copy.filePath).readAsBytesSync(), content);
      expect((await repo.fileOpens.open('open', dispatch)).completed, true);
      expect((await repo.fileOpens.open('open', dispatch)).completed, true);
      expect(dispatch.calls, 1);
      expect(await repo.backups.pendingOutputCleanupCount(), 0);
      expect(await repo.backups.pendingOutputOperationIds(), isEmpty);
      expect(await repo.backups.latestExportOperation(), isNull);
      expect(await repo.fileOpens.maintain(closePrevious: true), 0);
      expect(File(copy.filePath).existsSync(), true);
      await repo.fileOpens.close('open');
      expect(File(copy.filePath).existsSync(), false);
      expect((await repo.fileOpens.status('open'))!.completed, true);
      expect((await repo.fileOpens.status('open'))!.cleanupPending, false);
    },
  );
  test(
    'reopen cleans previous-process copies but never dispatches again',
    () async {
      await prepare();
      await repo.fileOpens.open('open', dispatch);
      final copy = lease();
      await repo.close();
      await open();
      await repo.fileOpens.maintain(closePrevious: true);
      expect(File(copy.filePath).existsSync(), false);
      expect((await repo.fileOpens.open('open', dispatch)).completed, true);
      expect(dispatch.calls, 1);
    },
  );
  test(
    'prepared intent after reopen is not submitted and cannot launch',
    () async {
      await prepare();
      final copy = lease();
      await repo.close();
      await open();
      final result = await repo.fileOpens.open('open', dispatch);
      expect(result.completed, false);
      expect(result.closed, true);
      expect(dispatch.calls, 0);
      expect(File(copy.filePath).existsSync(), false);
    },
  );
  test('rejected dispatch is durable and cleans its copy', () async {
    await prepare();
    final copy = lease();
    dispatch.accept = false;
    expect((await repo.fileOpens.open('open', dispatch)).completed, false);
    expect(File(copy.filePath).existsSync(), false);
    await repo.fileOpens.open('open', dispatch);
    expect(dispatch.calls, 1);
  });
  test(
    'lost native response reconciles process receipt without another launch',
    () async {
      await prepare();
      dispatch.dropReply = true;
      await expectLater(
        repo.fileOpens.open('open', dispatch),
        throwsA(anything),
      );
      expect((await repo.fileOpens.status('open'))!.uncertain, true);
      expect(
        (await repo.fileOpens.reconcile('open', dispatch))!.completed,
        true,
      );
      expect(dispatch.calls, 1);
    },
  );
  test(
    'native cache absence after restart remains unknown; close does not invent result',
    () async {
      await prepare();
      final copy = lease();
      dispatch.dropReply = true;
      await expectLater(
        repo.fileOpens.open('open', dispatch),
        throwsA(anything),
      );
      await repo.close();
      await open();
      dispatch = _Dispatch();
      await expectLater(
        repo.fileOpens.open('open', dispatch),
        fails('file_outcome_unknown'),
      );
      expect(File(copy.filePath).existsSync(), true);
      expect(dispatch.calls, 0);
      await repo.fileOpens.close('open');
      expect(File(copy.filePath).existsSync(), false);
      expect((await repo.fileOpens.status('open'))!.uncertain, true);
      expect((await repo.fileOpens.status('open'))!.closed, true);
      await expectLater(
        repo.fileOpens.open('open', dispatch),
        fails('file_outcome_unknown'),
      );
      expect(dispatch.calls, 0);
    },
  );
  test(
    'SQL result failure preserves dispatch for exact reconciliation',
    () async {
      await prepare();
      sql(
        "CREATE TRIGGER fail_open BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.phase')='opened' BEGIN SELECT RAISE(ABORT,'synthetic'); END",
      );
      await expectLater(
        repo.fileOpens.open('open', dispatch),
        throwsA(anything),
      );
      expect(dispatch.calls, 1);
      sql('DROP TRIGGER fail_open');
      expect(
        (await repo.fileOpens.reconcile('open', dispatch))!.completed,
        true,
      );
      expect(dispatch.calls, 1);
    },
  );
  test(
    'closing SQL acknowledgement failure retries deletion without reopening',
    () async {
      await prepare();
      await repo.fileOpens.open('open', dispatch);
      final copy = lease();
      sql(
        "CREATE TRIGGER fail_clean BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.cleanupPending')=0 BEGIN SELECT RAISE(ABORT,'synthetic'); END",
      );
      await expectLater(repo.fileOpens.close('open'), throwsA(anything));
      expect(File(copy.filePath).existsSync(), false);
      expect((await repo.fileOpens.status('open'))!.closed, true);
      sql('DROP TRIGGER fail_clean');
      await repo.fileOpens.close('open');
      expect((await repo.fileOpens.status('open'))!.cleanupPending, false);
      expect(dispatch.calls, 1);
    },
  );
  test(
    'failed prepare SQL receipt retains registered copy for maintenance',
    () async {
      sql(
        "CREATE TRIGGER fail_prepare BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.phase')='prepared' BEGIN SELECT RAISE(ABORT,'synthetic'); END",
      );
      await expectLater(prepare(), throwsA(anything));
      expect(dispatch.calls, 0);
      expect((await repo.fileOpens.status('open'))!.closed, true);
      expect((await repo.fileOpens.status('open'))!.cleanupPending, false);
      sql('DROP TRIGGER fail_prepare');
    },
  );
  test(
    'invalidated records refuse use but runtime still cleans copies',
    () async {
      await prepare();
      await repo.fileOpens.open('open', dispatch);
      final copy = lease();
      sql('UPDATE backup_operations SET invalidated=1');
      await expectLater(
        repo.fileOpens.status('open'),
        fails('library_changed'),
      );
      expect(await repo.fileOpens.copies(), isEmpty);
      expect(
        (await repo.fileOpens.copies(
          includeInvalidated: true,
        )).single.invalidated,
        true,
      );
      await repo.fileOpens.maintain();
      expect(File(copy.filePath).existsSync(), false);
      expect(dispatch.calls, 1);
    },
  );
  test(
    'different command and corrupt JSON never become absence or new launches',
    () async {
      await prepare();
      await expectLater(prepare(), fails('operation_conflict'));
      final original = lease();
      sql("UPDATE backup_operations SET payload='{}'");
      await expectLater(
        repo.fileOpens.status('open'),
        fails('invalid_file_open_receipt'),
      );
      await expectLater(
        repo.fileOpens.copies(),
        fails('invalid_file_open_receipt'),
      );
      expect(dispatch.calls, 0);
      // Only this test's exact registered generated copy is reclaimed.
      await NativeInformationDeliveryFiles().cleanup(original);
      sql('DELETE FROM backup_operations');
    },
  );
  test(
    'modified prepared bytes cannot be dispatched and abandon cleans exact copy',
    () async {
      await prepare();
      final copy = lease();
      await File(copy.filePath).writeAsString('changed');
      await expectLater(
        repo.fileOpens.open('open', dispatch),
        throwsA(isA<RuntimeMaterialFailure>()),
      );
      expect(dispatch.calls, 0);
      expect(
        (await repo.fileOpens.reconcile('open', dispatch))!.completed,
        false,
      );
      expect(File(copy.filePath).existsSync(), false);
    },
  );
  test(
    'copy capacity includes unclosed preparations and permits reuse only after cleanup',
    () async {
      for (var i = 0; i < 32; i++) {
        await prepare('copy-$i');
      }
      await expectLater(prepare('overflow'), fails('file_open_capacity'));
      expect((await repo.fileOpens.copies()).length, 32);
      expect(dispatch.calls, 0);
      await repo.fileOpens.close('copy-0');
      await prepare('fresh');
      expect((await repo.fileOpens.copies()).length, 32);
    },
  );
}
