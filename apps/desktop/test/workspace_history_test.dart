import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/library_controller.dart';

const ref = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
const credential = WorkspaceRecordRef(
  WorkspaceRecordKind.credential,
  'aliyunkey',
);
Matcher fails(String code) =>
    throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));

Future<WorkspaceSaved> edit(
  SampleWorkspaceSource source,
  String id, {
  String name = '修改后的服务器',
  String? directory,
}) async {
  final old = await source.readDetail(ref);
  return await source.saveRecord(
        WorkspaceEdit(
          operationId: id,
          expectedVersion: old.version,
          record: old.record.copyWith(name: name, directoryId: directory),
          values: {'host': 'updated.example'},
        ),
      )
      as WorkspaceSaved;
}

Future<WorkspaceRecordReceipt> recycle(
  SampleWorkspaceSource source,
  WorkspaceRecordRef target,
  String id,
) async {
  final old = await source.readDetail(target);
  return source.changeRecord(
    WorkspaceRecordChange(
      operationId: id,
      ref: target,
      expectedVersion: old.version,
      action: WorkspaceRecordAction.recycle,
    ),
  );
}

void main() {
  late SampleWorkspaceSource source;
  setUp(() {
    source = SampleWorkspaceSource();
  });
  tearDown(() {
    source.dispose();
  });

  test(
    'save archives immutable full snapshots; restore versions and idempotency remain monotonic',
    () async {
      final original = await source.readDetail(ref);
      final saved = await edit(source, 'edit');
      final revisions = await source.loadRevisions(ref);
      expect(revisions.single.version, 1);
      final preview = await source.previewRevision(
        ref,
        1,
        expectedVersion: saved.detail.version,
      );
      expect(preview.archive.detail.values, original.values);
      expect(preview.archive.targets, isNotEmpty);
      expect(
        () => preview.archive.detail.values.clear(),
        throwsUnsupportedError,
      );
      expect(() => preview.archive.targets.clear(), throwsUnsupportedError);
      final command = WorkspaceRecordChange(
        operationId: 'restore',
        ref: ref,
        expectedVersion: 2,
        expectedCatalogVersion: preview.catalogVersion,
        action: WorkspaceRecordAction.restoreRevision,
        revisionVersion: 1,
      );
      final receipt = await source.changeRecord(command);
      expect(identical(await source.changeRecord(command), receipt), isTrue);
      final restored = await source.readDetail(ref);
      expect(restored.version, 3);
      expect(restored.values, original.values);
      expect((await source.loadRevisions(ref)).map((r) => r.version), [2, 1]);
      expect(
        (await source.previewRevision(
          ref,
          1,
          expectedVersion: 3,
        )).archive.detail.record.name,
        original.record.name,
      );
      await expectLater(
        source.changeRecord(
          const WorkspaceRecordChange(
            operationId: 'restore',
            ref: ref,
            expectedVersion: 3,
            action: WorkspaceRecordAction.recycle,
          ),
        ),
        fails('operation_conflict'),
      );
    },
  );

  test(
    'concurrent duplicate restore returns one receipt and competing restore cannot overwrite it',
    () async {
      await edit(source, 'edit-concurrent');
      final catalog = await source.loadCatalog();
      final change = WorkspaceRecordChange(
        operationId: 'duplicate',
        ref: ref,
        expectedVersion: 2,
        expectedCatalogVersion: catalog.version,
        action: WorkspaceRecordAction.restoreRevision,
        revisionVersion: 1,
      );
      final outcomes = await Future.wait([
        source.changeRecord(change),
        source.changeRecord(change),
      ]);
      expect(identical(outcomes.first, outcomes.last), isTrue);
      expect((await source.readDetail(ref)).version, 3);
      expect((await source.loadRevisions(ref)).length, 2);
    },
  );

  test(
    'rejected restore leaves body, revision history and counts intact; conflict requires fresh preview',
    () async {
      await edit(source, 'edit');
      final preview = await source.previewRevision(ref, 1, expectedVersion: 2);
      final command = WorkspaceRecordChange(
        operationId: 'restore-failure',
        ref: ref,
        expectedVersion: 2,
        expectedCatalogVersion: preview.catalogVersion,
        action: WorkspaceRecordAction.restoreRevision,
        revisionVersion: 1,
      );
      source.nextSaveFailure = const WorkspaceFailure('save_failed', '磁盘空间不足');
      await expectLater(source.changeRecord(command), fails('save_failed'));
      expect((await source.readDetail(ref)).version, 2);
      expect((await source.loadRevisions(ref)).length, 1);
      expect((await source.queryRecycled()).total, 0);
      await edit(source, 'concurrent');
      await expectLater(source.changeRecord(command), fails('conflict'));
      await expectLater(
        source.previewRevision(ref, 1, expectedVersion: 2),
        fails('conflict'),
      );
      final catalog = await source.loadCatalog();
      await source.changeDirectory(
        WorkspaceDirectoryChange(
          operationId: 'catalog',
          expectedVersion: catalog.version,
          action: WorkspaceDirectoryAction.create,
          name: '后创建目录',
        ),
      );
      await expectLater(
        source.changeRecord(
          WorkspaceRecordChange(
            operationId: 'stale-catalog',
            ref: ref,
            expectedVersion: 3,
            expectedCatalogVersion: preview.catalogVersion,
            revisionVersion: 1,
            action: WorkspaceRecordAction.restoreRevision,
          ),
        ),
        fails('conflict'),
      );
      expect((await source.readDetail(ref)).version, 3);
    },
  );

  test(
    'recycle excludes current queries and relation candidates, restores above deletion watermark',
    () async {
      final original = await source.readDetail(ref);
      final deletion = await recycle(source, ref, 'recycle');
      expect(deletion.version, 2);
      expect((await source.loadSummary()).records, 30);
      expect((await source.loadCatalog()).recycledCount, 1);
      expect(await source.readSummaries([ref]), isEmpty);
      await expectLater(source.readDetail(ref), fails('not_found'));
      await expectLater(source.loadRevisions(ref), fails('not_found'));
      final candidates = await source.queryRelationCandidates(
        const WorkspaceRelationQuery(
          typeId: 'server',
          key: 'related',
          source: WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun'),
        ),
      );
      expect(candidates.items.any((r) => r.ref == ref), isFalse);
      final entry = (await source.queryRecycled()).items.single;
      expect(
        (await source.readRecycled(entry.id)).detail.values,
        original.values,
      );
      final restore = WorkspaceRecordChange(
        operationId: 'restore-recycled',
        ref: ref,
        expectedVersion: entry.version,
        expectedCatalogVersion: (await source.loadCatalog()).version,
        entryId: entry.id,
        action: WorkspaceRecordAction.restoreRecycled,
      );
      final receipt = await source.changeRecord(restore);
      expect(identical(await source.changeRecord(restore), receipt), isTrue);
      expect((await source.readDetail(ref)).version, 3);
      expect((await source.loadSummary()).records, 31);
      expect((await source.queryRecycled()).total, 0);
      await expectLater(source.readRecycled(entry.id), fails('not_found'));
      expect((await recycle(source, ref, 'second-recycle')).version, 4);
    },
  );

  test(
    'deleted classifications stay historical; restoring never recreates a removed directory',
    () async {
      var catalog = await source.loadCatalog();
      final directory = (await source.changeDirectory(
        WorkspaceDirectoryChange(
          operationId: 'dir',
          expectedVersion: catalog.version,
          action: WorkspaceDirectoryAction.create,
          name: '可移除目录',
        ),
      ))!;
      await edit(source, 'move', directory: directory.id);
      final deletion = await recycle(source, ref, 'delete');
      catalog = await source.loadCatalog();
      await source.changeDirectory(
        WorkspaceDirectoryChange(
          operationId: 'remove-dir',
          expectedVersion: catalog.version,
          action: WorkspaceDirectoryAction.delete,
          directoryId: directory.id,
        ),
      );
      final archive = await source.readRecycled(deletion.entryId!);
      expect(archive.directoryName, '可移除目录');
      expect(archive.detail.record.directoryId, directory.id);
      final receipt = await source.changeRecord(
        WorkspaceRecordChange(
          operationId: 'restore',
          ref: ref,
          expectedVersion: deletion.version,
          expectedCatalogVersion: (await source.loadCatalog()).version,
          entryId: deletion.entryId,
          action: WorkspaceRecordAction.restoreRecycled,
        ),
      );
      expect(receipt.notices, contains('原目录已移除，恢复后归入未分类。'));
      expect((await source.readDetail(ref)).record.directoryId, isNull);
      expect(
        (await source.loadCatalog()).directories.any(
          (d) => d.id == directory.id,
        ),
        isFalse,
      );
    },
  );

  test(
    'purge removes history and cached old save bodies; old commands never recreate the object',
    () async {
      final old = await source.readDetail(ref);
      final save = WorkspaceEdit(
        operationId: 'old-save',
        expectedVersion: old.version,
        record: old.record,
        values: {'host': 'purge-me.example'},
      );
      await source.saveRecord(save);
      final deletion = await recycle(source, ref, 'delete');
      final command = WorkspaceRecordChange(
        operationId: 'purge',
        ref: ref,
        expectedVersion: deletion.version,
        entryId: deletion.entryId,
        action: WorkspaceRecordAction.purge,
      );
      final receipt = await source.changeRecord(command);
      expect(identical(await source.changeRecord(command), receipt), isTrue);
      await expectLater(
        source.readRecycled(deletion.entryId!),
        fails('not_found'),
      );
      expect((await source.queryRecycled()).total, 0);
      expect(
        (await source.saveRecord(save) as WorkspaceRejected).failure.code,
        'purged',
      );
      await expectLater(
        source.changeRecord(
          WorkspaceRecordChange(
            operationId: 'after-purge',
            ref: ref,
            expectedVersion: deletion.version,
            entryId: deletion.entryId,
            expectedCatalogVersion: (await source.loadCatalog()).version,
            action: WorkspaceRecordAction.restoreRecycled,
          ),
        ),
        fails('not_found'),
      );
      expect((await source.loadSummary()).records, 30);
      source.reset();
      expect(
        (await source.readDetail(ref)).values,
        old.values,
      ); // Only the explicit fictional reset revives fixtures.
      expect(await source.loadRevisions(ref), isEmpty);
    },
  );

  test(
    '30-day expiration removes recycled content and revisions without resetting version facts',
    () async {
      var now = DateTime.utc(2026, 10, 26);
      final timed = SampleWorkspaceSource(now: () => now);
      addTearDown(timed.dispose);
      await edit(timed, 'edit');
      final deletion = await recycle(timed, ref, 'delete');
      now = now.add(const Duration(days: 30));
      expect((await timed.queryRecycled()).total, 0);
      await expectLater(
        timed.readRecycled(deletion.entryId!),
        fails('not_found'),
      );
      final active = const WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        'aliyun',
      );
      final detail = await timed.readDetail(active);
      await timed.saveRecord(
        WorkspaceEdit(
          operationId: 'active-edit',
          expectedVersion: detail.version,
          record: detail.record,
          values: {},
        ),
      );
      now = now.add(const Duration(days: 30));
      expect(await timed.loadRevisions(active), isEmpty);
      expect((await timed.readDetail(active)).version, 2);
    },
  );

  test(
    'credentials, stale identities, bad pages and failed recycle are rejected without mutation',
    () async {
      await expectLater(source.loadRevisions(credential), fails('unsupported'));
      await expectLater(
        recycle(source, credential, 'credential'),
        fails('unsupported'),
      );
      await expectLater(source.queryRecycled(limit: 0), fails('invalid_query'));
      source.nextSaveFailure = const WorkspaceFailure('save_failed', '保存失败');
      await expectLater(recycle(source, ref, 'failure'), fails('save_failed'));
      expect((await source.loadSummary()).records, 31);
      expect((await source.queryRecycled()).total, 0);
      await source.changeRecord(
        const WorkspaceRecordChange(
          operationId: 'retry',
          ref: ref,
          expectedVersion: 1,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      await expectLater(
        source.changeRecord(
          const WorkspaceRecordChange(
            operationId: 'stale',
            ref: ref,
            expectedVersion: 1,
            action: WorkspaceRecordAction.recycle,
          ),
        ),
        fails('not_found'),
      );
    },
  );

  test(
    'collection shrink repairs last page, selection and controller query offset',
    () async {
      final model = LibraryController(source);
      addTearDown(model.dispose);
      await model.load(const WorkspaceQuery(limit: 10, offset: 30));
      expect(model.results!.items.length, 1);
      final last = model.results!.items.single.ref;
      // Last row can be a credential, use the last ordinary item by name instead.
      if (last.kind == WorkspaceRecordKind.information) {
        await recycle(source, last, 'last');
      } else {
        await recycle(source, ref, 'last');
      }
      await Future<void>.delayed(Duration.zero);
      await model.load(model.query);
      expect(model.query.offset, 20);
      expect(model.results!.offset, 20);
      expect(model.results!.items, isNotEmpty);
      expect(model.selection, isNotNull);
      final empty = await source.queryRecords(
        const WorkspaceQuery(keyword: 'nothing matches', offset: 900),
      );
      expect(empty.offset, 0);
      expect(empty.selection, isNull);
    },
  );
}
