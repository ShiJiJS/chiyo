import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  late DateTime now;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('information-purge-');
    keys = TestKeyStore();
    now = DateTime.utc(2026, 10, 30);
    repo = await EncryptedInformationRepository.open(
      root.path,
      keys,
      clock: () => now,
    );
    service = InformationService(repository: repo, clock: () => now);
  });
  tearDown(() async {
    await service.close();
    await repo.close();
    await root.delete(recursive: true);
  });
  Database inspect() {
    final db = sqlite3.open('${root.path}/library.db');
    db.execute(
      'PRAGMA key = "x\'${keys.key!.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\'"',
    );
    return db;
  }

  Future<void> reopen() async {
    await service.close();
    await repo.close();
    repo = await EncryptedInformationRepository.open(
      root.path,
      keys,
      clock: () => now,
    );
    service = InformationService(repository: repo, clock: () => now);
  }

  Future<InformationLifecycleCommand> command(
    RecycleEntry entry, {
    String op = 'purge',
    int? current,
  }) async => InformationLifecycleCommand(
    operationId: op,
    itemId: entry.itemId,
    action: InformationLifecycleAction.purge,
    expectedVersion: entry.version,
    entryId: entry.id,
    expectedCurrentVersion: current,
    expectedCatalogVersion:
        (await service.owner.informationClassificationSnapshot()).version,
  );
  Future<(InformationItem, InformationFileDraft, InformationDraftInput)>
  text() async {
    final draft = await service.owner.beginInformationFileDraft();
    final input = InformationDraftInput(
      name: '合成资料',
      description: '',
      fields: [
        const InformationDraftField.text('正文', '', 'purge-private-original'),
      ],
    );
    final item = await service.owner.commitInformationDraft(
      draft,
      'create',
      input,
    );
    return (item, draft, input);
  }

  Future<(InformationItem, InformationFileDraft)> file() async {
    final path = File('${root.path}/synthetic.txt');
    await path.writeAsString('SYNTHETIC-FILE-PRIVATE');
    final draft = await service.owner.beginInformationFileDraft();
    final staged = await service.owner.stageInformationFile(draft, path.path);
    final item = await service.owner.commitInformationDraft(
      draft,
      'file',
      InformationDraftInput(
        name: '文件',
        description: '',
        fields: [InformationDraftField.stagedFile('附件', '', staged.id)],
      ),
    );
    return (item, draft);
  }

  test(
    'whole purge removes history pending bodies and replay caches but retains exact no-body receipt',
    () async {
      final (item, draft, input) = await text();
      final session = service.agent.openSession('合成聊天');
      final update = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, 1, [
          FieldChange.correct(item.fields.single.id, 'purge-private-proposed'),
        ]),
      );
      final deletion = await service.agent.submitDelete(session, item.id, 1);
      await service.owner.correctValue(
        FieldRef(item.id, item.fields.single.id),
        'purge-private-corrected',
      );
      final entry = await service.owner.deleteInformation(item.id, 2);
      final purge = await command(entry);
      final receipt = await service.owner.changeInformationLifecycle(purge);
      expect(repo.items, isEmpty);
      expect(repo.informationRevisions, isEmpty);
      expect(service.owner.recycleEntries, isEmpty);
      expect(
        repo.updateProposals.singleWhere((p) => p.id == update).state,
        UpdateProposalState.conflicted,
      );
      expect(repo.updateProposals.single.input.changes, isEmpty);
      expect(
        repo.deleteProposals.singleWhere((p) => p.id == deletion).state,
        DeleteProposalState.conflicted,
      );
      await expectLater(
        service.owner.commitInformationDraft(draft, 'create', input),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'no replay',
            'information_purged',
          ),
        ),
      );
      final db = inspect();
      try {
        for (final table in [
          'information_revisions',
          'recycle_entries',
          'update_proposals',
          'information_draft_commits',
          'information_lifecycle_operations',
        ]) {
          expect(
            db
                .select('SELECT payload FROM $table')
                .map((r) => r['payload'])
                .join(),
            isNot(contains('purge-private')),
          );
        }
        expect(
          db
              .select('SELECT count(*) AS n FROM revision_purge_facts')
              .single['n'],
          2,
        );
      } finally {
        db.close();
      }
      await reopen();
      expect(
        (await service.owner.changeInformationLifecycle(purge)).toJson(),
        receipt.toJson(),
      );
      expect(repo.items, isEmpty);
      expect(repo.informationRevisions, isEmpty);
      await expectLater(
        service.owner.restoreRecycled(entry.id),
        throwsA(isA<AccessFailure>()),
      );
    },
  );

  test(
    'partial purge preserves current values unrelated proposals and disjoint recycle entries',
    () async {
      final item = await service.owner.createInformation('资料', '', [
        const FieldInput('甲', '', 'private-A'),
        const FieldInput('乙', '', 'private-B'),
        const FieldInput('丙', '', 'private-C'),
      ]);
      final entryA = await service.owner.deleteInformation(
        item.id,
        1,
        fieldId: item.fields[0].id,
      );
      final entryB = await service.owner.deleteInformation(
        item.id,
        2,
        fieldId: item.fields[1].id,
      );
      await service.owner.correctValue(
        FieldRef(item.id, item.fields[2].id),
        'updated-C',
      );
      final session = service.agent.openSession('partial');
      final pending = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, 4, [
          FieldChange.correct(item.fields[2].id, 'proposed-C'),
        ]),
      );
      final before = repo.items.single;
      await expectLater(
        service.owner.changeInformationLifecycle(
          await command(entryA, op: 'stale', current: 3),
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(await service.owner.informationLifecycleReceipt('stale'), isNull);
      final receipt = await service.owner.changeInformationLifecycle(
        await command(entryA, current: 4),
      );
      expect(receipt.version, greaterThan(4));
      expect(informationToJson(repo.items.single), informationToJson(before));
      expect(service.owner.recycleEntries.single.id, entryB.id);
      expect(
        repo.updateProposals.singleWhere((p) => p.id == pending).state,
        UpdateProposalState.pending,
      );
      expect(repo.informationRevisions.map((r) => r.item.version), [2, 3]);
      expect(
        jsonEncode(
          repo.informationRevisions
              .map((r) => informationToJson(r.item))
              .toList(),
        ),
        isNot(contains('private-A')),
      );
      final restored = await service.owner.restoreRecycled(entryB.id);
      expect(restored.fields.map((f) => f.value), ['updated-C', 'private-B']);
      expect(restored.version, greaterThan(receipt.version));
      await reopen();
      expect(repo.items.single.fields.map((f) => f.value), [
        'updated-C',
        'private-B',
      ]);
    },
  );

  test(
    'purge clears unpinned BLOB immediately and keeps immutable metadata and source file',
    () async {
      final (item, draft) = await file();
      final ref = item.fields.single.attachment!;
      final entry = await service.owner.deleteInformation(item.id, 1);
      await service.owner.changeInformationLifecycle(await command(entry));
      final db = inspect();
      try {
        expect(
          db
              .select('SELECT body FROM information_attachment_versions')
              .single['body'],
          isNull,
        );
        expect(
          jsonDecode(
            db
                    .select('SELECT payload FROM information_draft_commits')
                    .single['payload']
                as String,
          ),
          {'purged': true},
        );
      } finally {
        db.close();
      }
      expect(
        (await repo.informationAttachmentVersions(
          ref.attachmentId,
        )).single.available,
        isFalse,
      );
      await expectLater(
        repo.readInformationAttachmentChunk(ref, 0, 1),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        repo.informationDraftReceipt(draft.id, 'file'),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        await File('${root.path}/synthetic.txt').readAsString(),
        'SYNTHETIC-FILE-PRIVATE',
      );
      final recovery = await enableTestBackups(repo.backups);
      final path = '${root.path}/purged.aimbackup';
      await repo.backups.exportTo(path);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        TestKeyStore(),
        clock: () => now,
      );
      try {
        await target.backups.restoreFrom(path, recovery);
        expect(target.items, isEmpty);
        expect(target.informationRevisions, isEmpty);
        expect(
          (await target.informationAttachmentVersions(
            ref.attachmentId,
          )).single.available,
          isFalse,
        );
        expect(await target.informationLifecycleReceipt('purge'), isNull);
      } finally {
        await target.close();
      }
    },
  );

  test(
    'another live information field pins shared bytes despite target purge',
    () async {
      final (item, _) = await file();
      final ref = item.fields.single.attachment!;
      // Legal persisted shared reference; no copy and no new material identity.
      await repo.save(
        InformationItem(
          'shared',
          '保留资料',
          '',
          1,
          [InformationField.file('shared-field', '附件', '', ref, 1)],
          createdAt: now,
          modifiedAt: now,
        ),
      );
      final entry = await service.owner.deleteInformation(item.id, 1);
      await service.owner.changeInformationLifecycle(await command(entry));
      expect(repo.items.single.id, 'shared');
      expect(
        utf8.decode(await repo.readInformationAttachmentChunk(ref, 0, 22)),
        'SYNTHETIC-FILE-PRIVATE',
      );
      expect(
        (await repo.informationAttachmentVersions(
          ref.attachmentId,
        )).single.available,
        isTrue,
      );
    },
  );

  test(
    'receipt failure rolls back every purge surface including BLOB and draft tombstone',
    () async {
      final (item, draft) = await file();
      final ref = item.fields.single.attachment!;
      final entry = await service.owner.deleteInformation(item.id, 1);
      final purge = await command(entry);
      final db = inspect();
      try {
        db.execute(
          "CREATE TRIGGER fail_purge BEFORE INSERT ON information_lifecycle_operations BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
        );
        await expectLater(
          service.owner.changeInformationLifecycle(purge),
          throwsA(isA<StorageFailure>()),
        );
        expect(service.owner.recycleEntries.single.id, entry.id);
        expect(repo.informationRevisions, hasLength(1));
        expect(await repo.informationDraftReceipt(draft.id, 'file'), isNotNull);
        expect(
          (await repo.informationAttachmentVersions(
            ref.attachmentId,
          )).single.available,
          isTrue,
        );
        expect(
          db
              .select('SELECT body FROM information_attachment_versions')
              .single['body'],
          isNotNull,
        );
        expect(
          await service.owner.informationLifecycleReceipt('purge'),
          isNull,
        );
        expect(
          db
              .select('SELECT count(*) AS n FROM revision_purge_facts')
              .single['n'],
          0,
        );
        db.execute('DROP TRIGGER fail_purge');
      } finally {
        db.close();
      }
      await service.owner.changeInformationLifecycle(purge);
      await reopen();
      expect(service.owner.recycleEntries, isEmpty);
      expect(repo.informationRevisions, isEmpty);
      expect(
        (await repo.informationAttachmentVersions(
          ref.attachmentId,
        )).single.available,
        isFalse,
      );
    },
  );

  test(
    'retention uses the same purge without leaving a replayable old draft',
    () async {
      final (item, draft, input) = await text();
      final entry = await service.owner.deleteInformation(item.id, 1);
      now = now.add(const Duration(days: 31));
      await service.owner.purgeRecycle();
      expect(repo.recycleEntries.single.state, RecycleState.purged);
      expect(repo.informationRevisions, isEmpty);
      await expectLater(
        service.owner.commitInformationDraft(draft, 'create', input),
        throwsA(isA<AccessFailure>()),
      );
      expect(repo.items, isEmpty);
      await service.owner.purgeRecycle();
      expect(
        repo.recycleFacts.where(
          (f) => f.entryId == entry.id && f.kind == RecycleFactKind.purged,
        ),
        hasLength(1),
      );
    },
  );

  for (final old in [32, 33]) {
    test(
      'format $old upgrades existing lifecycle receipts before supporting purge',
      () async {
        final (item, _, _) = await text();
        final oldCommand = InformationLifecycleCommand(
          operationId: 'old-delete',
          itemId: item.id,
          action: InformationLifecycleAction.recycle,
          expectedVersion: 1,
        );
        final original = await service.owner.changeInformationLifecycle(
          oldCommand,
        );
        final entry = service.owner.recycleEntries.single;
        await service.close();
        await repo.close();
        final db = inspect();
        try {
          db.execute('UPDATE library_format SET version=$old');
          db.execute('PRAGMA user_version=$old');
        } finally {
          db.close();
        }
        repo = await EncryptedInformationRepository.open(
          root.path,
          keys,
          clock: () => now,
        );
        service = InformationService(repository: repo, clock: () => now);
        expect(
          (await service.owner.informationLifecycleReceipt(
            'old-delete',
          ))!.toJson(),
          original.toJson(),
        );
        expect(
          (await service.owner.changeInformationLifecycle(oldCommand)).toJson(),
          original.toJson(),
        );
        await service.owner.changeInformationLifecycle(await command(entry));
        await reopen();
        final check = inspect();
        try {
          expect(
            check.select('PRAGMA user_version').single.values.single,
            old == 32 ? 34 : 35,
          );
        } finally {
          check.close();
        }
        expect(
          await service.owner.informationLifecycleReceipt('purge'),
          isNotNull,
        );
      },
    );
  }
}
