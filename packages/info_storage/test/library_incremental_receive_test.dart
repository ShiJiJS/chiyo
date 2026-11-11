import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:info_core/info_core.dart';
import 'package:info_core/library_sync_changes.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

import 'storage_test.dart' show TestKeyStore;

class _Device {
  _Device(this.root, this.keys, this.repo, this.service)
    : incremental = LibraryIncremental(LibraryReplication(repo));
  final Directory root;
  final TestKeyStore keys;
  final EncryptedInformationRepository repo;
  final InformationService service;
  final LibraryIncremental incremental;
  static Future<_Device> open(String root, {TestKeyStore? existingKeys}) async {
    final keys = existingKeys ?? TestKeyStore();
    final repo = await EncryptedInformationRepository.open(root, keys);
    return _Device(
      Directory(root),
      keys,
      repo,
      InformationService(repository: repo),
    );
  }

  Future<List<LibraryIncrementalEntry>> after(int cursor) =>
      service.owner.exportLibrary(() => incremental.after(cursor));
  Future<void> start({LibraryReplicaContents? initial}) => service.owner
      .exportLibrary(() => incremental.start(initialContents: initial));
  Future<LibrarySyncReceipt> receive(LibrarySyncBatch batch) =>
      service.owner.exportLibrary(() => incremental.receive(batch));
  Future<void> close() async {
    await service.close();
    await repo.close();
  }

  sqlite.Database inspect() {
    final db = sqlite.sqlite3.open('${root.path}/library.db');
    db.execute(
      'PRAGMA key = "x\'${keys.key!.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\'"',
    );
    return db;
  }
}

class _Pair {
  _Pair(this.root, this.a, this.b, this.initial);
  final Directory root;
  final _Device a, b;
  final InformationItem initial;
  static Future<_Pair> create() async {
    final root = await Directory.systemTemp.createTemp('sync-receive-');
    final a = await _Device.open('${root.path}/a');
    final b = await _Device.open('${root.path}/b');
    final initial = await a.service.owner.createInformation('共同的初始资料', '', [
      const FieldInput('正文', '', 'SYNTHETIC_BASE'),
    ]);
    await a.start();
    final seed = await a.service.owner.exportLibrary(
      () => LibraryReplication(a.repo).snapshotContents(),
    );
    final prepared = await a.service.owner.exportLibrary(
      () => LibraryReplication(
        a.repo,
      ).exportInitial('${root.path}/initial.encrypted'),
    );
    await b.service.owner.restoreLibrary(
      () => LibraryReplication(b.repo).installInitial(
        path: '${root.path}/initial.encrypted',
        transferKey: prepared.transferKey,
        operationId: 'receive-baseline',
        transfer: prepared.transfer,
      ),
    );
    await b.start(initial: seed);
    return _Pair(root, a, b, initial);
  }

  Future<void> close() async {
    await a.close();
    await b.close();
    await root.delete(recursive: true);
  }
}

Future<LibrarySyncReceipt> transfer(
  _Device source,
  _Device target,
  LibrarySyncBatch batch,
) async {
  for (final change in batch.changes.where(
    (c) => c.key.kind == LibrarySyncKind.attachment && c.content != null,
  )) {
    for (final raw in change.content!['attachments'] as List) {
      final version = InformationAttachmentVersion.fromPrivateJson(
        Map<String, dynamic>.from(raw as Map),
      );
      if (await target.incremental.hasAttachment(version)) continue;
      Stream<List<int>> bytes() async* {
        for (var offset = 0; offset < version.byteLength; offset += 65536) {
          yield await source.repo.readInformationAttachmentChunk(
            version.reference,
            offset,
            min(65536, version.byteLength - offset),
          );
        }
      }

      await target.service.owner.exportLibrary(
        () => target.incremental.cacheAttachment(version, bytes()),
      );
    }
  }
  return target.receive(batch);
}

void main() {
  test(
    'synchronized grant facts stay inactive in SQL and after process restart',
    () async {
      final pair = await _Pair.create();
      _Device? reopened;
      try {
        final ref = FieldRef(pair.initial.id, pair.initial.fields.single.id);
        final session = pair.a.service.agent.openSession('原始授权会话');
        final request = pair.a.service.agent.request(session, '合成历史传输', [ref]);
        pair.a.service.owner.approve(request.id, [ref]);
        final original = pair.a.service.agent.claim(session, request.id);
        for (final entry in await pair.a.after(0)) {
          expect((await pair.b.receive(entry.batch)).conflict, false);
        }
        expect(pair.b.repo.grantHistory, isNotEmpty);
        expect(
          pair.b.repo.grantHistory.every(
            (g) => !g.active && g.restoredAt != null,
          ),
          true,
        );
        final native = pair.b.inspect();
        try {
          for (final row in native.select(
            'SELECT payload FROM grant_history',
          )) {
            expect(
              (jsonDecode(row['payload'] as String) as Map)['restoredAt'],
              isNotNull,
            );
          }
        } finally {
          native.close();
        }
        await pair.b.close();
        reopened = await _Device.open(
          pair.b.root.path,
          existingKeys: pair.b.keys,
        );
        await reopened.start();
        expect(
          reopened.repo.grantHistory.every(
            (g) => !g.active && g.restoredAt != null,
          ),
          true,
        );
        await expectLater(
          reopened.service.agent.read(original.token, ref),
          throwsA(isA<AccessFailure>()),
        );
        expect(
          await pair.a.service.agent.read(original.token, ref),
          'SYNTHETIC_BASE',
        );
      } finally {
        await reopened?.close();
        await pair.close();
      }
    },
  );

  test(
    'a real delta preserves active local approval and a pending proposal',
    () async {
      final pair = await _Pair.create();
      try {
        final owner = pair.a.service.owner;
        final ref = FieldRef(pair.initial.id, pair.initial.fields.single.id);
        final session = pair.a.service.agent.openSession('本机仍有效的聊天');
        final request = pair.a.service.agent.request(session, '合成读取', [ref]);
        owner.approve(request.id, [ref]);
        final token = pair.a.service.agent.claim(session, request.id);
        await pair.a.service.agent.submitImport(session, [
          ImportItemInput('仍待核对的提案', '', [
            const FieldInput('正文', '', 'SYNTHETIC_PENDING'),
          ]),
        ]);
        await pair.b.service.owner.correctValue(ref, 'SYNTHETIC_FROM_B');
        final changes = await pair.b.after(0);
        expect(changes, hasLength(1));
        final receipt = await pair.a.receive(changes.single.batch);
        expect(receipt.conflict, false);
        expect(
          owner.information.single.fields.single.value,
          'SYNTHETIC_FROM_B',
        );
        expect(owner.importProposals.single.state, ImportProposalState.pending);
        expect(
          await pair.a.service.agent.read(token.token, ref),
          'SYNTHETIC_FROM_B',
        );
        // A keeps its own grant fact active; unrelated synchronization is not a
        // backup restore and must not clear the authorization library.
        expect(pair.a.repo.grantHistory.any((g) => g.active), true);
        final stored = pair.a.inspect();
        try {
          expect(
            stored
                .select('SELECT count(*) AS n FROM library_sync_changes')
                .single['n'],
            greaterThanOrEqualTo(0),
          );
          final duplicate = await pair.a.receive(changes.single.batch);
          expect(duplicate.toJson(), receipt.toJson());
        } finally {
          stored.close();
        }
      } finally {
        await pair.close();
      }
    },
  );

  test(
    'both edits are retained as a conflict while another record still applies',
    () async {
      final pair = await _Pair.create();
      try {
        final ref = FieldRef(pair.initial.id, pair.initial.fields.single.id);
        await pair.a.service.owner.correctValue(ref, 'SYNTHETIC_OFFLINE_A');
        await pair.b.service.owner.correctValue(ref, 'SYNTHETIC_ONLINE_B');
        final b = (await pair.b.after(0)).single;
        final first = await pair.a.receive(b.batch);
        expect(first.conflict, true);
        expect(
          pair.a.service.owner.information.single.fields.single.value,
          'SYNTHETIC_OFFLINE_A',
        );
        expect(
          pair.b.service.owner.information.single.fields.single.value,
          'SYNTHETIC_ONLINE_B',
        );
        final native = pair.a.inspect();
        try {
          final stored = native
              .select(
                "SELECT payload,local_candidate FROM library_sync_feed WHERE outcome='conflict'",
              )
              .single;
          expect(stored['payload'], contains('SYNTHETIC_ONLINE_B'));
          expect(stored['local_candidate'], contains('SYNTHETIC_OFFLINE_A'));
        } finally {
          native.close();
        }
        final unrelated = await pair.b.service.owner.createInformation(
          '独立的新资料',
          '',
          [const FieldInput('正文', '', 'SYNTHETIC_INDEPENDENT')],
        );
        final second = (await pair.b.after(b.cursor)).single;
        expect((await pair.a.receive(second.batch)).conflict, false);
        expect(
          pair.a.service.owner.information.any((i) => i.id == unrelated.id),
          true,
        );
        expect((await pair.a.receive(b.batch)).toJson(), first.toJson());
      } finally {
        await pair.close();
      }
    },
  );

  test(
    'lost commit response is reconciled and a failed receipt leaves no partial data',
    () async {
      final pair = await _Pair.create();
      final native = pair.b.inspect();
      try {
        final created = await pair.a.service.owner.createInformation(
          '原子接收',
          '',
          [const FieldInput('正文', '', 'SYNTHETIC_ATOMIC')],
        );
        final batch = (await pair.a.after(0)).single.batch;
        native.execute(
          "CREATE TRIGGER fail_received_receipt BEFORE INSERT ON library_sync_feed BEGIN SELECT RAISE(ABORT,'synthetic receive failure'); END",
        );
        await expectLater(pair.b.receive(batch), throwsA(isA<Exception>()));
        expect(
          pair.b.service.owner.information.any((i) => i.id == created.id),
          false,
        );
        expect(
          native.select('SELECT id FROM information_items WHERE id=?', [
            created.id,
          ]),
          isEmpty,
        );
        native.execute('DROP TRIGGER fail_received_receipt');
        final accepted = await pair.b.receive(batch);
        final cursor = accepted.cursor;
        expect(accepted.conflict, false);
        await pair.b.service.owner.createInformation('之后的本机资料', '', [
          const FieldInput('正文', '', 'SYNTHETIC_LATER'),
        ]);
        final duplicate = await pair.b.receive(batch);
        expect(duplicate.cursor, cursor);
        expect(
          pair.b.service.owner.information.where((i) => i.id == created.id),
          hasLength(1),
        );
        // Incoming SQL writes do not echo into a newly generated local batch.
        final feed = await pair.b.after(0);
        expect(
          feed.where((e) => e.batch.operationId == batch.operationId),
          hasLength(1),
        );
        expect(
          feed.where((e) => e.batch.sourceReplicaId == batch.sourceReplicaId),
          hasLength(1),
        );
      } finally {
        native.close();
        await pair.close();
      }
    },
  );

  test(
    'file originals transfer lazily and original versions remain readable',
    () async {
      final pair = await _Pair.create();
      try {
        Future<InformationItem> file(
          List<int> bytes, [
          InformationItem? old,
        ]) async {
          final input = File('${pair.root.path}/original.bin');
          await input.writeAsBytes(bytes);
          final draft = await pair.a.service.owner.beginInformationFileDraft();
          try {
            final staged = await pair.a.service.owner.stageInformationFile(
              draft,
              input.path,
            );
            return await pair.a.service.owner.commitInformationDraft(
              draft,
              'file-${old?.version ?? 0}',
              InformationDraftInput(
                name: '合成文件',
                description: '',
                itemId: old?.id,
                baseVersion: old?.version,
                fields: [
                  InformationDraftField.stagedFile(
                    '文件',
                    '',
                    staged.id,
                    fieldId: old?.fields.single.id,
                  ),
                ],
              ),
            );
          } finally {
            await pair.a.service.owner.releaseInformationFileDraft(draft);
          }
        }

        final first = await file([1, 2, 3, 4]);
        var cursor = 0;
        for (final entry in await pair.a.after(cursor)) {
          expect((await transfer(pair.a, pair.b, entry.batch)).conflict, false);
          cursor = entry.cursor;
        }
        final second = await file([5, 6, 7], first);
        for (final entry in await pair.a.after(cursor)) {
          expect((await transfer(pair.a, pair.b, entry.batch)).conflict, false);
          cursor = entry.cursor;
        }
        expect(
          await pair.b.repo.readInformationAttachmentChunk(
            first.fields.single.attachment!,
            0,
            4,
          ),
          [1, 2, 3, 4],
        );
        expect(
          await pair.b.repo.readInformationAttachmentChunk(
            second.fields.single.attachment!,
            0,
            3,
          ),
          [5, 6, 7],
        );
        expect(
          pair.b.service.owner.information
              .singleWhere((i) => i.id == first.id)
              .version,
          second.version,
        );
        final projected = await pair.b.service.owner.exportLibrary(
          () => LibraryReplication(pair.b.repo).snapshotContents(),
        );
        projected.validate(DateTime.now().toUtc());
      } finally {
        await pair.close();
      }
    },
  );
}
