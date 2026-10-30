import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_history.dart';
import 'package:info_desktop/workspace/owner_workspace_information.dart';
import 'package:info_desktop/workspace/workspace_history.dart';
import 'package:info_desktop/workspace/workspace_records.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceHistory history;
  var now = DateTime.utc(2026, 10, 30);
  void connect({void Function(WorkspaceRecordRef)? changed}) {
    history = OwnerWorkspaceHistory(
      information: OwnerWorkspaceInformation(
        owner: service.owner,
        templates: {},
      ),
      onChanged: changed,
    );
  }

  Future<int> catalog() async =>
      (await service.owner.informationClassificationSnapshot()).version;
  WorkspaceRecordRef ref(core.InformationItem item) =>
      WorkspaceRecordRef(WorkspaceRecordKind.information, item.id);
  setUp(() async {
    now = DateTime.utc(2026, 10, 30);
    root = await Directory.systemTemp.createTemp('owner-history-');
    keys = _Keys();
    repo = await EncryptedInformationRepository.open(
      root.path,
      keys,
      clock: () => now,
    );
    service = core.InformationService(repository: repo, clock: () => now);
    connect();
  });
  tearDown(() async {
    await service.close();
    await repo.close();
    await root.delete(recursive: true);
  });
  test(
    'history projects real snapshots and restored receipts match exact UI intents across reopen',
    () async {
      final item = await service.owner.createInformation('合成资料', '', [
        const core.FieldInput('字段', '', 'original'),
      ]);
      await service.owner.correctValue(
        core.FieldRef(item.id, item.fields.single.id),
        'updated',
      );
      final revisions = await history.loadRevisions(ref(item));
      expect(revisions.single.version, 1);
      final preview = await history.previewRevision(
        ref(item),
        1,
        expectedVersion: 2,
      );
      expect(preview.canRestore, isTrue);
      expect(preview.archive.detail.values.values, contains('original'));
      final restore = WorkspaceRecordChange(
        operationId: 'restore-version',
        ref: ref(item),
        expectedVersion: 2,
        action: WorkspaceRecordAction.restoreRevision,
        revisionVersion: 1,
        expectedCatalogVersion: preview.catalogVersion,
      );
      final restored = await history.changeRecord(restore);
      expect(restored.version, 3);
      expect(repo.items.single.fields.single.value, 'original');
      final receipt = (await history.lifecycleOperationReceipt(
        restore.operationId,
      ))!;
      expect(
        receipt.intent.matches(WorkspaceOperationIntent.change(restore)),
        isTrue,
      );
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(
        root.path,
        keys,
        clock: () => now,
      );
      service = core.InformationService(repository: repo, clock: () => now);
      connect();
      expect(
        (await history.lifecycleOperationReceipt(
          restore.operationId,
        ))!.intent.matches(receipt.intent),
        isTrue,
      );
      await history.changeRecord(restore);
      expect(repo.items.single.version, 3);
    },
  );
  test(
    'post-commit failure reconciles deletion then restores new field identities',
    () async {
      final item = await service.owner.createInformation('资料', '公开说明', [
        const core.FieldInput('字段', '', 'body-not-searchable'),
      ]);
      connect(
        changed: (_) => throw const WorkspaceFailure(
          'validation',
          'synthetic refresh failure',
        ),
      );
      final deletion = WorkspaceRecordChange(
        operationId: 'delete',
        ref: ref(item),
        expectedVersion: 1,
        action: WorkspaceRecordAction.recycle,
      );
      await expectLater(
        history.changeRecord(deletion),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'committed but refresh failed',
            'unknown_outcome',
          ),
        ),
      );
      final receipt = (await history.lifecycleOperationReceipt('delete'))!;
      expect(
        receipt.intent.matches(WorkspaceOperationIntent.change(deletion)),
        isTrue,
      );
      expect(repo.items, isEmpty);
      connect();
      expect(
        (await history.queryRecycled(keyword: 'body-not-searchable')).total,
        0,
      );
      final page = await history.queryRecycled(
        keyword: '公开说明',
        offset: 999,
        limit: 1,
      );
      expect(page.total, 1);
      expect(page.offset, 0);
      final archive = await history.readRecycled(receipt.result.entryId!);
      expect(archive.detail.values.values, contains('body-not-searchable'));
      final restore = WorkspaceRecordChange(
        operationId: 'restore',
        ref: ref(item),
        expectedVersion: receipt.result.version,
        entryId: receipt.result.entryId,
        action: WorkspaceRecordAction.restoreRecycled,
        expectedCatalogVersion: await catalog(),
      );
      await history.changeRecord(restore);
      expect(repo.items.single.fields.single.id, isNot(item.fields.single.id));
      expect(
        (await history.lifecycleOperationReceipt(
          'restore',
        ))!.intent.matches(WorkspaceOperationIntent.change(restore)),
        isTrue,
      );
      expect((await history.queryRecycled()).total, 0);
      await expectLater(
        history.readRecycled(receipt.result.entryId!),
        throwsA(isA<WorkspaceFailure>()),
      );
    },
  );
  test(
    'missing fields require explicit recycle restoration and expired content is inaccessible',
    () async {
      final item = await service.owner.createInformation('资料', '', [
        const core.FieldInput('甲', '', 'one'),
        const core.FieldInput('乙', '', 'two'),
      ]);
      final entry = await service.owner.deleteInformation(
        item.id,
        1,
        fieldId: item.fields.first.id,
      );
      final preview = await history.previewRevision(
        ref(item),
        1,
        expectedVersion: 2,
      );
      expect(preview.canRestore, isFalse);
      expect(preview.missingFields, ['甲']);
      await expectLater(
        history.changeRecord(
          WorkspaceRecordChange(
            operationId: 'unsafe',
            ref: ref(item),
            expectedVersion: 2,
            action: WorkspaceRecordAction.restoreRevision,
            revisionVersion: 1,
            expectedCatalogVersion: await catalog(),
          ),
        ),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'requires explicit recovery',
            'recycle_restore_required',
          ),
        ),
      );
      expect(await history.lifecycleOperationReceipt('unsafe'), isNull);
      final partial = await history.readRecycled(entry.id);
      expect(partial.wholeItem, isFalse);
      expect(partial.detail.values.values, ['one']);
      now = now.add(const Duration(days: 31));
      expect((await history.queryRecycled()).total, 0);
      await expectLater(
        history.readRecycled(entry.id),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect(await history.loadRevisions(ref(item)), isEmpty);
    },
  );
  test(
    'unsupported purge and credentials never masquerade as success and query errors propagate',
    () async {
      final item = await service.owner.createInformation('资料', '', [
        const core.FieldInput('字段', '', 'private'),
      ]);
      await expectLater(
        history.changeRecord(
          WorkspaceRecordChange(
            operationId: 'purge',
            ref: ref(item),
            expectedVersion: 1,
            action: WorkspaceRecordAction.purge,
          ),
        ),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'unsupported',
            'unsupported',
          ),
        ),
      );
      await expectLater(
        history.loadRevisions(
          const WorkspaceRecordRef(
            WorkspaceRecordKind.credential,
            'credential',
          ),
        ),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect(repo.items.single.id, item.id);
      await service.close();
      await expectLater(
        history.lifecycleOperationReceipt('missing'),
        throwsA(isA<core.AccessFailure>()),
      );
    },
  );
}
