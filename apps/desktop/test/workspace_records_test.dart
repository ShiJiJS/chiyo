import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/workspace_controller.dart';
import 'package:info_desktop/workspace/workspace_records_controller.dart';

const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
const aliyun = WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun');

class DeferredDetails extends Fake implements WorkspaceSource {
  final requests = <WorkspaceRecordRef, Completer<WorkspaceDetail>>{};
  @override
  Stream<WorkspaceRecordRef?> get changes => const Stream.empty();
  @override
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) =>
      (requests[ref] = Completer<WorkspaceDetail>()).future;
}

class DeferredQueries extends Fake implements WorkspaceSource {
  DeferredQueries(this.catalog, this.details);
  final WorkspaceCatalog catalog;
  final Map<WorkspaceRecordRef, WorkspaceDetail> details;
  final requests = <Completer<WorkspaceResults>>[];
  @override
  Stream<WorkspaceRecordRef?> get changes => const Stream.empty();
  @override
  Future<WorkspaceCatalog> loadCatalog() async => catalog;
  @override
  Future<WorkspaceResults> queryRecords(
    WorkspaceQuery query, {
    WorkspaceRecordRef? keepSelection,
  }) {
    final pending = Completer<WorkspaceResults>();
    requests.add(pending);
    return pending.future;
  }

  @override
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) async =>
      details[ref]!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SampleWorkspaceSource source;
  setUp(() => source = SampleWorkspaceSource());
  tearDown(() => source.dispose());

  test(
    'query intersects metadata filters; values never become search text',
    () async {
      final catalog = await source.loadCatalog();
      final production = catalog.tags.singleWhere((t) => t.name == '生产环境');
      final result = await source.queryRecords(
        WorkspaceQuery(
          directoryId: 'selfhost',
          typeId: 'server',
          tagId: production.id,
          keyword: '日本 服务器',
        ),
      );
      expect(result.items.single.ref, azure);
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(keyword: 'tokyo.beichen.example'),
        )).total,
        0,
      );
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(directoryId: 'personal'),
        )).items.any((r) => r.ref.id == 'resume'),
        isTrue,
      );
      expect((await source.loadSummary()).records, 31);
    },
  );

  test(
    'group counts precede paging; selection identity includes record kind',
    () async {
      final all = await source.queryRecords(
        const WorkspaceQuery(grouping: WorkspaceGrouping.type, limit: 1),
        keepSelection: aliyun,
      );
      expect(all.total, 31);
      expect(all.items.length, 1);
      expect(all.groupCounts.values.reduce((a, b) => a + b), 31);
      expect(all.selection, aliyun);
      expect(
        azure,
        isNot(
          const WorkspaceRecordRef(WorkspaceRecordKind.credential, 'azure'),
        ),
      );
      final credential = await source.readDetail(
        const WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey'),
      );
      expect(credential.values, isEmpty);
      expect(() => credential.values['secret'] = 'no', throwsUnsupportedError);
    },
  );

  test(
    'save uses versions, immutable snapshots and an idempotent operation',
    () async {
      final before = await source.readDetail(azure);
      final edit = WorkspaceEdit(
        operationId: 'edit-1',
        expectedVersion: before.version,
        record: before.record.copyWith(name: '日本入口 · 已修改'),
        values: {'port': '2200'},
      );
      final result = await source.saveRecord(edit) as WorkspaceSaved;
      expect(result.detail.version, 2);
      expect(result.detail.values['port'], '2200');
      expect(before.values['port'], '2222');
      expect(identical(await source.saveRecord(edit), result), isTrue);
      final stale =
          await source.saveRecord(
                WorkspaceEdit(
                  operationId: 'stale',
                  expectedVersion: 1,
                  record: before.record,
                  values: {},
                ),
              )
              as WorkspaceRejected;
      expect(stale.failure.code, 'conflict');
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(keyword: '已修改'),
        )).items.single.ref,
        azure,
      );
      final other = SampleWorkspaceSource();
      addTearDown(other.dispose);
      expect((await other.readDetail(azure)).version, 1);
      source.reset();
      expect((await source.readDetail(azure)).record.name, before.record.name);
    },
  );

  test('validation and save failure never write partial changes', () async {
    final before = await source.readDetail(azure);
    final invalid =
        await source.saveRecord(
              WorkspaceEdit(
                operationId: 'bad',
                expectedVersion: 1,
                record: before.record.copyWith(name: ''),
                values: {'host': ''},
              ),
            )
            as WorkspaceRejected;
    expect(invalid.failure.fieldErrors.keys, containsAll(['name', 'host']));
    source.nextSaveFailure = const WorkspaceFailure('offline', '保存失败');
    final failed =
        await source.saveRecord(
              WorkspaceEdit(
                operationId: 'fail',
                expectedVersion: 1,
                record: before.record.copyWith(name: '保留的草稿'),
                values: {},
              ),
            )
            as WorkspaceRejected;
    expect(failed.failure.code, 'offline');
    expect((await source.readDetail(azure)).record.name, before.record.name);
    final retry = await source.saveRecord(
      WorkspaceEdit(
        operationId: 'retry',
        expectedVersion: 1,
        record: before.record.copyWith(name: '保留的草稿'),
        values: {},
      ),
    );
    expect(retry, isA<WorkspaceSaved>());
  });

  test(
    'late details cannot replace selection or notify after disposal',
    () async {
      final delayed = DeferredDetails();
      final controller = WorkspaceRecordsController(delayed);
      final old = controller.select(azure);
      final latest = controller.select(aliyun);
      delayed.requests[aliyun]!.complete(await source.readDetail(aliyun));
      await latest;
      delayed.requests[azure]!.complete(await source.readDetail(azure));
      await old;
      expect(controller.detail!.record.ref, aliyun);
      final pending = controller.select(azure);
      controller.dispose();
      delayed.requests[azure]!.completeError(StateError('after dispose'));
      await pending;
    },
  );

  test(
    'return and destination switches preserve query and scroll position',
    () {
      final controller = WorkspaceController(source);
      addTearDown(controller.dispose);
      const query = WorkspaceQuery(
        keyword: '日本',
        directoryId: 'selfhost',
        typeId: 'server',
      );
      controller.navigate(
        WorkspacePage.library,
        objectId: 'azure',
        query: query,
        scrollOffset: 240,
      );
      controller.navigate(
        WorkspacePage.history,
        objectId: 'grant-1',
        remember: true,
      );
      controller.goBack();
      expect(controller.location.query, query);
      expect(controller.location.scrollOffset, 240);
      controller.navigate(WorkspacePage.settings);
      controller.navigate(WorkspacePage.library);
      expect(controller.location.objectId, 'azure');
      expect(controller.location.query, query);
      expect(controller.location.scrollOffset, 240);
    },
  );

  test('late query cannot replace current query and selection', () async {
    final a = await source.readDetail(azure),
        b = await source.readDetail(aliyun);
    final delayed = DeferredQueries(await source.loadCatalog(), {
      azure: a,
      aliyun: b,
    });
    final controller = WorkspaceRecordsController(delayed);
    addTearDown(controller.dispose);
    final old = controller.load(const WorkspaceQuery(keyword: '日本'));
    await Future<void>.delayed(Duration.zero);
    final latest = controller.load(const WorkspaceQuery(keyword: '杭州'));
    await Future<void>.delayed(Duration.zero);
    delayed.requests[1].complete(
      WorkspaceResults(
        items: [b.record],
        total: 1,
        offset: 0,
        selection: aliyun,
      ),
    );
    await latest;
    delayed.requests[0].complete(
      WorkspaceResults(
        items: [a.record],
        total: 1,
        offset: 0,
        selection: azure,
      ),
    );
    await old;
    expect(controller.query.keyword, '杭州');
    expect(controller.detail!.record.ref, aliyun);
    expect(controller.results!.items.single.ref, aliyun);
  });
  test('separate page controllers share changes through one source', () async {
    final first = WorkspaceRecordsController(source),
        second = WorkspaceRecordsController(source);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.load(const WorkspaceQuery(typeId: 'server'));
    await second.load(const WorkspaceQuery(typeId: 'server'));
    final draft = first.detail!;
    await first.save(
      WorkspaceEdit(
        operationId: 'cross-page-save',
        expectedVersion: draft.version,
        record: draft.record.copyWith(name: '共享的新名称'),
        values: {},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(second.detail!.record.name, '共享的新名称');
    expect(second.detail!.version, 2);
  });
}
