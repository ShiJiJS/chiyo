import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/library_sync_changes.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';
import '../../info_core/test_support/operation_history.dart';
import '../../info_core/test_support/native_fill.dart' show nativeTargetFixture;
import 'storage_test.dart' show TestKeyStore;

class _Replica {
  _Replica(this.path, this.clock);
  final String path;
  final DateTime Function() clock;
  final keys = TestKeyStore();
  late EncryptedInformationRepository repo;
  late OnlineInformationRuntime runtime;
  late LibraryIncremental incremental;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.openOnline(
      path,
      keys,
      clock: clock,
    );
    runtime = await OnlineInformationRuntime.open(
      repository: repo,
      clock: clock,
    );
    incremental = LibraryIncremental(LibraryReplication(repo));
  }

  Future<void> close() async {
    await runtime.close();
    await repo.close();
  }

  Future<T> snapshot<T>(Future<T> Function() action) =>
      runtime.run(() => runtime.service.owner.exportLibrary(action));
  Future<List<LibraryIncrementalEntry>> after(int cursor) =>
      snapshot(() => incremental.after(cursor));
  Future<LibraryReplicaContents> contents() =>
      snapshot(() => LibraryReplication(repo).snapshotContents());
}

Future<int> _initial(_Replica a, _Replica b) async {
  final file = File('${a.path}/initial.encrypted');
  final prepared = await a.snapshot(
    () => a.incremental.exportInitialWithBaseline(file.path),
  );
  await b.runtime.run(
    () => b.runtime.service.owner.restoreLibrary(
      () => b.incremental.installInitialWithBaseline(
        path: file.path,
        transferKey: prepared.initial.transferKey,
        operationId: 'initial-copy',
        transfer: prepared.initial.transfer,
        baseline: prepared.baseline,
        expectedSourceReplicaId: prepared.baseline.sourceReplicaId,
      ),
    ),
  );
  await file.delete();
  return prepared.initial.transfer.contentFormat;
}

Future<LibrarySyncReceipt> _transfer(
  _Replica a,
  _Replica b,
  LibrarySyncBatch batch, {
  int? contentFormat,
}) async {
  final file = File('${a.path}/delta.encrypted');
  final prepared = await a.snapshot(
    () => a.incremental.exportDelta(
      file.path,
      sourceReplicaId: batch.sourceReplicaId,
      operationId: batch.operationId,
    ),
  );
  if (contentFormat != null) {
    expect(prepared.transfer.archive.contentFormat, contentFormat);
  }
  try {
    final receipt = await b.snapshot(
      () => b.incremental.installDelta(
        path: file.path,
        transferKey: prepared.transferKey,
        transfer: prepared.transfer,
      ),
    );
    await file.delete();
    // Recovery uses the original receipt even when the archive has gone away.
    final retry = await b.snapshot(
      () => b.incremental.installDelta(
        path: file.path,
        transferKey: prepared.transferKey,
        transfer: prepared.transfer,
      ),
    );
    expect(retry.toJson(), receipt.toJson());
    return receipt;
  } finally {
    if (await file.exists()) await file.delete();
  }
}

LibrarySyncKey _history(String id) =>
    LibrarySyncKey(LibrarySyncKind.history, 'credential-batch:$id');

Map<LibrarySyncKey, Map<String, Object?>> _historyUnits(
  LibraryReplicaContents contents,
  String requestId,
) => {
  for (final entry in contents.units.entries)
    if (entry.key == _history(requestId) ||
        ['credential_batch_operations', 'credential_program_operations'].any(
          (table) =>
              ((entry.value['tables'] as Map)[table] as List? ?? const []).any(
                (r) => (r as Map)['request_id'] == requestId,
              ),
        ))
      entry.key: entry.value,
};

Future<void> _refuseReparentedSourceOperation(
  _Replica a,
  _Replica b,
  OperationHistoryFixture f,
  LibraryReplicaContents contents,
  bool program,
) async {
  final unit = _historyUnits(
    contents,
    f.request.id,
  ).entries.firstWhere((e) => e.key != _history(f.request.id));
  Map<String, Object?> copy(Map<String, Object?> value) =>
      Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);
  final parent = copy(contents.units[_history(f.request.id)]!);
  const other = 'synthetic-reparented-archive';
  final requestRow =
      ((parent['tables'] as Map)['credential_batches'] as List).single as Map;
  final requestPayload = jsonDecode(requestRow['payload'] as String) as Map;
  requestPayload['id'] = other;
  requestPayload['operationId'] = 'other-submit';
  requestRow['id'] = other;
  requestRow['operation_id'] = 'other-submit';
  requestRow['payload'] = jsonEncode(requestPayload);
  final operation = copy(unit.value);
  final table = program
      ? 'credential_program_operations'
      : 'credential_batch_operations';
  final row = ((operation['tables'] as Map)[table] as List).single as Map;
  final payload = jsonDecode(row['payload'] as String) as Map;
  if (program) {
    (payload['progress'] as Map)['requestId'] = other;
  } else {
    payload['requestId'] = other;
  }
  row['request_id'] = other;
  row['payload'] = jsonEncode(payload);
  final baseline = await a.snapshot(() => a.incremental.baseline('a' * 64));
  final batch = LibrarySyncBatch(
    libraryId: contents.libraryId,
    sourceReplicaId: (await LibraryReplication(b.repo).identity()).replicaId,
    operationId: 'cannot-reparent-source-operation',
    sequence: 1,
    edits: [
      LibrarySyncEdit(key: _history(other), baseVersion: null, content: parent),
      LibrarySyncEdit(
        key: unit.key,
        baseVersion: baseline.versions[unit.key],
        content: operation,
      ),
    ],
  );
  // The candidate itself is a valid inactive archive. Protection must examine
  // the existing source operation too, not just its proposed new parent.
  contents.replacing(batch).validate(a.clock());
  final receipt = await a.snapshot(() => a.incremental.receive(batch));
  expect(receipt.conflict, isTrue);
  expect(a.repo.credentialBatches.any((r) => r.id == other), isFalse);
  expect(
    a.runtime.service.agent.showOwnOperation(
      f.session,
      'op-000000',
    )['requestId'],
    f.request.id,
  );
}

void _assertArchive(
  _Replica b,
  OperationHistoryFixture f, {
  required bool program,
  required int count,
}) {
  final r = b.repo.credentialBatches.where((r) => r.id == f.request.id).single;
  expect(r.archived, isTrue);
  final operations = program
      ? b.repo.credentialProgramOperations
            .where((o) => o.requestId == r.id)
            .toList()
      : b.repo.credentialBatchOperations
            .where((o) => o.requestId == r.id)
            .toList();
  expect(operations, hasLength(count));
  final other = b.runtime.service.agent.openSession('合成记录分页');
  expect(
    () =>
        b.runtime.service.agent.credentialBatchStatus(other, r.deviceId, r.id),
    throwsA(isA<CredentialUseFailure>()),
  );
  expect(
    () => b.runtime.service.agent.credentialBatchStatus(
      f.session,
      r.deviceId,
      r.id,
    ),
    throwsA(isA<AccessFailure>()),
  );
}

void main() {
  for (final nativeKind in [
    'appkit_secure_text',
    'macos_ax_password',
    'windows_uia_password',
  ]) {
    final format = nativeKind == 'appkit_secure_text' ? 30 : 31;
    test(
      '$nativeKind snapshots use format $format and incremental operations remain inactive on the replica',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'native-batch-sync-',
        );
        final now = DateTime.utc(2026, 11, 14);
        final a = _Replica('${root.path}/a', () => now),
            b = _Replica('${root.path}/b', () => now);
        await a.open();
        await b.open();
        addTearDown(() async {
          await a.close();
          await b.close();
          await root.delete(recursive: true);
        });
        final f = OperationHistoryFixture(a.runtime.service, a.repo, now);
        await a.runtime.run(() async {
          await f.open(program: false);
          f.input = CredentialBatchInput.fromJson({
            ...f.input.toJson(),
            'items': [
              {
                ...f.input.items.single.toJson(),
                'destination': {
                  'via': 'native',
                  'target': nativeTargetFixture(controlKind: nativeKind),
                },
              },
            ],
          });
          f.request = await a.runtime.service.agent.requestCredentialBatch(
            f.session,
            'A' * 22,
            f.input,
            operationId: 'native-sync-submit',
          );
          f.request = await a.runtime.service.owner.decideCredentialBatch(
            f.request.id,
            operationId: 'native-sync-approve',
            revision: 1,
            approvedItems: ['b1'],
          );
          await f.append('native-first');
        });
        expect(await _initial(a, b), format);
        _assertArchive(b, f, program: false, count: 1);
        expect(
          b.repo.credentialBatches
              .singleWhere((r) => r.id == f.request.id)
              .items
              .single
              .destination
              .native!
              .fieldLabel,
          'Password',
        );
        await a.runtime.run(() => f.append('native-second'));
        final operations = await a.after(0);
        for (final entry in operations) {
          expect(
            (await _transfer(a, b, entry.batch, contentFormat: 28)).conflict,
            false,
          );
        }
        _assertArchive(b, f, program: false, count: 2);
        await a.runtime.run(
          () => a.runtime.service.owner.revokeCredentialBatch(
            f.request.id,
            operationId: 'native-revoke',
            revision: f.request.revision,
            itemIds: ['b1'],
          ),
        );
        final snapshots = await a.after(operations.last.cursor);
        expect(snapshots, hasLength(1));
        expect(
          (await _transfer(
            a,
            b,
            snapshots.single.batch,
            contentFormat: format,
          )).conflict,
          false,
        );
      },
    );
  }
  for (final program in [false, true]) {
    test(
      '${program ? 'program' : 'fill'} source retention synchronizes parent and child deletion without replaying old history',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'batch-sync-retention-',
        );
        var now = DateTime.utc(2026, 11, 14);
        final a = _Replica('${root.path}/a', () => now),
            b = _Replica('${root.path}/b', () => now);
        await a.open();
        await b.open();
        addTearDown(() async {
          await a.close();
          await b.close();
          await root.delete(recursive: true);
        });
        final f = OperationHistoryFixture(a.runtime.service, a.repo, now);
        await a.runtime.run(() => f.open(program: program, count: 1));
        await _initial(a, b);
        await a.runtime.run(() => f.append('later-use-before-retention'));
        final changes = await a.after(0);
        for (final entry in changes) {
          expect((await _transfer(a, b, entry.batch)).conflict, isFalse);
        }
        _assertArchive(b, f, program: program, count: 2);
        await a.runtime.run(
          () => a.runtime.service.agent.endSession(f.session),
        );
        now = now.add(const Duration(days: 100));
        await a.runtime.run(a.runtime.service.owner.pruneCredentialUseHistory);
        final deletions = await a.after(changes.last.cursor);
        expect(deletions, hasLength(1));
        expect(deletions.single.batch.changes, hasLength(3));
        expect(
          deletions.single.batch.changes.every((c) => c.content == null),
          isTrue,
        );
        expect(
          (await _transfer(a, b, deletions.single.batch)).conflict,
          isFalse,
        );
        expect(b.repo.credentialBatches, isEmpty);
        expect(b.repo.credentialBatchOperations, isEmpty);
        expect(b.repo.credentialProgramOperations, isEmpty);
        expect((await _transfer(a, b, changes.last.batch)).conflict, isFalse);
        expect(b.repo.credentialBatches, isEmpty);
        expect(b.repo.credentialBatchOperations, isEmpty);
        expect(b.repo.credentialProgramOperations, isEmpty);
        await b.close();
        await b.open();
        expect(b.repo.credentialBatches, isEmpty);
        expect(b.repo.credentialBatchOperations, isEmpty);
        expect(b.repo.credentialProgramOperations, isEmpty);
      },
    );

    test(
      '${program ? 'program' : 'fill'} initial content keeps complete inactive history and exact baseline',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'batch-sync-initial-',
        );
        final now = DateTime.utc(2026, 11, 14);
        final a = _Replica('${root.path}/a', () => now),
            b = _Replica('${root.path}/b', () => now);
        await a.open();
        await b.open();
        addTearDown(() async {
          await a.close();
          await b.close();
          await root.delete(recursive: true);
        });
        final f = OperationHistoryFixture(a.runtime.service, a.repo, now);
        const initialCount = 1005;
        await a.runtime.run(() async {
          await f.open(program: program, count: initialCount);
          if (program) await f.append('unfinished-before-copy', finish: false);
        });
        final before = await a.contents();
        final unit = before.units[_history(f.request.id)]!;
        final historyUnits = _historyUnits(before, f.request.id);
        final encoded = jsonEncode(historyUnits.values.toList());
        for (final private in [
          'NEVER-PAGE-THIS-MATERIAL',
          'executionCapability',
          'materialLease',
          'jobName',
          'workerPid',
        ]) {
          expect(encoded, isNot(contains(private)));
        }
        final tables = unit['tables'] as Map;
        expect(tables['credential_batches'], hasLength(1));
        expect(historyUnits.length, 1 + initialCount + (program ? 1 : 0));
        expect(
          tables.length,
          1,
        ); // Each subsequent use transfers only its own row.
        await _initial(a, b);
        final after = await b.contents();
        expect(
          jsonEncode(after.units[_history(f.request.id)]),
          jsonEncode(unit),
        );
        expect(
          jsonEncode(
            _historyUnits(after, f.request.id).map((k, v) => MapEntry(k.id, v)),
          ),
          jsonEncode(historyUnits.map((k, v) => MapEntry(k.id, v))),
        );
        _assertArchive(
          b,
          f,
          program: program,
          count: initialCount + (program ? 1 : 0),
        );
        expect(a.repo.credentialBatches.single.archived, isFalse);
        expect(
          a.runtime.service.agent.credentialBatchStatus(
            f.session,
            f.request.deviceId,
            f.request.id,
          )['items'],
          everyElement(containsPair('grantState', 'available')),
        );
        if (program) {
          final o = b.repo.credentialProgramOperations
              .where((o) => o.operationId == 'unfinished-before-copy')
              .single;
          expect(o.archived, isTrue);
          expect(o.progress.state, 'unknown');
          expect(o.progress.jobName, isNull);
        }
        // A pure unchanged poll does not invent a second version from archive markers.
        expect(await b.after(0), isEmpty);
        await _refuseReparentedSourceOperation(a, b, f, before, program);
      },
    );

    test(
      '${program ? 'program' : 'fill'} deltas capture lazy tables, preserve other local approvals and fence source deletion',
      () async {
        final root = await Directory.systemTemp.createTemp('batch-sync-delta-');
        var now = DateTime.utc(2026, 11, 14);
        final a = _Replica('${root.path}/a', () => now),
            b = _Replica('${root.path}/b', () => now);
        await a.open();
        await b.open();
        addTearDown(() async {
          await a.close();
          await b.close();
          await root.delete(recursive: true);
        });
        await _initial(a, b); // No batch tables exist when the journal starts.
        final f = OperationHistoryFixture(a.runtime.service, a.repo, now);
        await a.runtime.run(() => f.open(program: program, count: 1));
        var cursor = 0;
        for (final entry in await a.after(cursor)) {
          expect((await _transfer(a, b, entry.batch)).conflict, isFalse);
          cursor = entry.cursor;
        }
        _assertArchive(b, f, program: program, count: 1);

        final local = OperationHistoryFixture(b.runtime.service, b.repo, now);
        await b.runtime.run(() => local.open(program: !program));
        await a.runtime.run(() => f.append('second-use'));
        for (final entry in await a.after(cursor)) {
          expect((await _transfer(a, b, entry.batch)).conflict, isFalse);
          cursor = entry.cursor;
        }
        _assertArchive(b, f, program: program, count: 2);
        expect(
          b.repo.credentialBatches
              .where((r) => r.id == local.request.id)
              .single
              .archived,
          isFalse,
        );
        expect(
          b.runtime.service.agent.credentialBatchStatus(
            local.session,
            local.request.deviceId,
            local.request.id,
          )['items'],
          everyElement(containsPair('grantState', 'available')),
        );
        final beforeRestart = jsonEncode(
          (await b.contents()).units[_history(f.request.id)],
        );
        await b.close();
        await b.open();
        expect(
          jsonEncode((await b.contents()).units[_history(f.request.id)]),
          beforeRestart,
        );

        now = now.add(const Duration(days: 100));
        await b.runtime.run(b.runtime.service.owner.pruneCredentialUseHistory);
        expect(
          b.repo.credentialBatches.any((r) => r.id == f.request.id),
          isFalse,
        );
        var protectedSource = false;
        for (final entry in await b.after(0)) {
          final deletion = entry.batch.changes.any(
            (c) => c.key == _history(f.request.id) && c.content == null,
          );
          final receipt = await _transfer(b, a, entry.batch);
          if (deletion) {
            expect(receipt.conflict, isTrue);
            protectedSource = true;
          }
        }
        expect(protectedSource, isTrue);
        expect(
          a.repo.credentialBatches
              .where((r) => r.id == f.request.id)
              .single
              .archived,
          isFalse,
        );
        expect(
          a.runtime.service.agent.showOwnOperation(
            f.session,
            'second-use',
          )['requestId'],
          f.request.id,
        );
      },
    );
  }

  test(
    'upgrading an old live journal seeds pre-existing history exactly once without editing its source rows',
    () async {
      final root = await Directory.systemTemp.createTemp('batch-sync-upgrade-');
      final now = DateTime.utc(2026, 11, 14);
      final a = _Replica(root.path, () => now);
      await a.open();
      addTearDown(() async {
        await a.close();
        await root.delete(recursive: true);
      });
      await a.snapshot(a.incremental.start);
      final f = OperationHistoryFixture(a.runtime.service, a.repo, now);
      await a.runtime.run(() => f.open(program: true, count: 1));
      final source = jsonEncode(a.repo.credentialBatches.single.toJson());
      await a.close();
      final db = sqlite.sqlite3.open('${root.path}/library.db');
      db.execute(
        'PRAGMA key = "x\'${a.keys.key!.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}\'"',
      );
      for (final table in [
        'credential_batches',
        'credential_batch_operations',
        'credential_program_operations',
      ]) {
        for (final suffix in ['insert', 'delete', 'update', 'key']) {
          db.execute('DROP TRIGGER sync_${table}_$suffix');
        }
        db.execute('DELETE FROM library_sync_changes WHERE changes LIKE ?', [
          '%"table":"$table"%',
        ]);
      }
      db.close();
      await a.open();
      expect(jsonEncode(a.repo.credentialBatches.single.toJson()), source);
      final entries = await a.after(0);
      final histories = [
        for (final entry in entries)
          for (final change in entry.batch.changes)
            if (change.key == _history(f.request.id)) change,
      ];
      expect(histories, hasLength(1));
      final operations = [
        for (final entry in entries)
          for (final change in entry.batch.changes)
            if ((change.content?['tables'] as Map?)?.containsKey(
                  'credential_program_operations',
                ) ==
                true)
              change,
      ];
      expect(operations, hasLength(1));
      expect(
        ((operations.single.content!['tables']
                as Map)['credential_program_operations']
            as List),
        hasLength(1),
      );
      final last = entries.last.cursor;
      await a.close();
      await a.open();
      expect(await a.after(last), isEmpty);
      expect(jsonEncode(a.repo.credentialBatches.single.toJson()), source);
    },
  );
}
