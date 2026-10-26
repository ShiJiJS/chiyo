import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/sample_workspace_fixture.dart';
import 'package:info_desktop/workspace/sample_workspace_stress_fixture.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
Map<String, dynamic> fixture(String text) =>
    jsonDecode(text) as Map<String, dynamic>;
Matcher failure(String code) =>
    throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));

void main() {
  test(
    'pressure data is deterministic and separate: 200 information, 8 credentials, 50 directories, 100 tags',
    () async {
      final json = buildWorkspaceStressFixture();
      expect(buildWorkspaceStressFixture(), json);
      expect(buildWorkspaceStressFixture(seed: 1234), isNot(json));
      expect((fixture(sampleWorkspaceJson)['records'] as List).length, 31);
      final source = SampleWorkspaceSource(fixtureJson: json);
      addTearDown(source.dispose);
      final all = await source.queryRecords(const WorkspaceQuery(limit: 500));
      final catalog = await source.loadCatalog();
      expect(all.total, 208);
      expect(
        all.items
            .where((r) => r.ref.kind == WorkspaceRecordKind.information)
            .length,
        200,
      );
      expect(
        all.items
            .where((r) => r.ref.kind == WorkspaceRecordKind.credential)
            .length,
        8,
      );
      expect(
        catalog.directories
            .where((d) => !['all', 'unfiled'].contains(d.id))
            .length,
        50,
      );
      expect(catalog.tags.length, 100);
      expect(catalog.recycledCount, 1);
      expect(catalog.directoryCounts['all'], 208);
      expect(all.items.map((r) => r.ref).toSet().length, 208);
      expect(all.items.any((r) => r.name.length > 80), isTrue);
      expect(catalog.tags.any((t) => t.name.length > 40), isTrue);
      expect(catalog.directories.any((d) => d.name.length > 30), isTrue);
    },
  );

  test(
    'sorting/grouping are global before paging and repeated-name ties use typed IDs',
    () async {
      final source = SampleWorkspaceSource(
        fixtureJson: buildWorkspaceStressFixture(),
      );
      addTearDown(source.dispose);
      for (final grouping in WorkspaceGrouping.values) {
        for (final sort in WorkspaceSort.values) {
          final global = await source.queryRecords(
            WorkspaceQuery(grouping: grouping, sort: sort, limit: 500),
          );
          final seen = <WorkspaceRecordRef>[];
          for (var offset = 0; offset < global.total; offset += 17) {
            final page = await source.queryRecords(
              WorkspaceQuery(
                grouping: grouping,
                sort: sort,
                offset: offset,
                limit: 17,
              ),
            );
            expect(page.total, 208);
            expect(page.groupCounts, global.groupCounts);
            seen.addAll(page.items.map((r) => r.ref));
          }
          expect(seen, global.items.map((r) => r.ref).toList());
        }
      }
      final names = await source.queryRecords(
        const WorkspaceQuery(
          sort: WorkspaceSort.name,
          keyword: '压力资料 同名资料',
          limit: 500,
        ),
      );
      expect(names.total, greaterThan(10));
      final keys = names.items.map((r) => r.ref.key).toList();
      expect(keys, [...keys]..sort());
    },
  );

  test(
    'typed fixture references keep colliding information and credential IDs independent',
    () async {
      final data = fixture(sampleWorkspaceJson);
      final rows = (data['records'] as List).cast<Map<String, dynamic>>();
      final info = rows.firstWhere((r) => r['id'] == 'azure');
      final credential = rows.firstWhere((r) => r['kind'] == 'credential');
      credential['id'] = 'azure';
      credential['relations'] = {};
      info['relations'] = {
        'related': [
          {'kind': 'credential', 'id': 'azure'},
        ],
      };
      data['records'] = [info, credential];
      data['trash'] = [];
      final source = SampleWorkspaceSource(fixtureJson: jsonEncode(data));
      addTearDown(source.dispose);
      const secret = WorkspaceRecordRef(
        WorkspaceRecordKind.credential,
        'azure',
      );
      final all = await source.queryRecords(const WorkspaceQuery());
      expect(all.total, 2);
      expect(all.items.map((r) => r.ref).toSet(), {azure, secret});
      expect((await source.readDetail(azure)).relations['related'], [secret]);
      expect((await source.readDetail(secret)).values, isEmpty);
      final original = await source.readDetail(azure);
      await source.saveRecord(
        WorkspaceEdit(
          operationId: 'typed-edit',
          expectedVersion: 1,
          record: original.record.copyWith(name: '普通信息已修改'),
          values: {},
        ),
      );
      expect((await source.readDetail(secret)).record.name, credential['name']);
      expect((await source.readDetail(secret)).version, 1);
      expect((await source.readSummaries([azure, secret])).length, 2);
    },
  );

  test(
    'ambiguous legacy relation fixtures fail instead of silently resolving the wrong kind',
    () async {
      final data = fixture(sampleWorkspaceJson);
      final rows = (data['records'] as List).cast<Map<String, dynamic>>();
      final info = rows.firstWhere((r) => r['id'] == 'azure');
      final credential = rows.firstWhere((r) => r['kind'] == 'credential');
      credential['id'] = 'azure';
      credential['relations'] = {};
      info['relations'] = {
        'related': ['azure'],
      };
      data['records'] = [info, credential];
      data['trash'] = [];
      final source = SampleWorkspaceSource(fixtureJson: jsonEncode(data));
      addTearDown(source.dispose);
      await expectLater(source.loadCatalog(), throwsFormatException);
    },
  );

  test(
    'the frozen recycle seed is absent from live metadata, restores above deletion version and resets',
    () async {
      final source = SampleWorkspaceSource();
      addTearDown(source.dispose);
      final entries = await source.queryRecycled();
      final old = entries.items.single;
      expect(old.record.name, '旧部署笔记');
      expect(old.directoryName, '自托管服务');
      expect(old.deletedAt, DateTime.utc(2026, 10, 20));
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(keyword: '旧部署笔记'),
        )).total,
        0,
      );
      expect(
        (await source.readRecycled(old.id)).detail.values['body'],
        '旧的容器部署步骤。',
      );
      await source.changeRecord(
        WorkspaceRecordChange(
          operationId: 'seed-restore',
          ref: old.record.ref,
          expectedVersion: old.version,
          expectedCatalogVersion: (await source.loadCatalog()).version,
          entryId: old.id,
          action: WorkspaceRecordAction.restoreRecycled,
        ),
      );
      expect((await source.readDetail(old.record.ref)).version, 3);
      expect((await source.loadSummary()).records, 32);
      source.reset();
      expect((await source.queryRecycled()).total, 1);
      expect((await source.loadSummary()).records, 31);
      await expectLater(
        source.readDetail(old.record.ref),
        failure('not_found'),
      );
    },
  );

  test(
    'fixture replacement cancels pending reads and resets edits, versions, catalog and navigation',
    () async {
      final source = SampleWorkspaceSource();
      final model = LibraryController(source);
      addTearDown(model.dispose);
      addTearDown(source.dispose);
      await model.load(model.query, keepSelection: azure);
      await model.openRelated(
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'blinko'),
      );
      expect(model.canGoBack, isTrue);
      final catalogVersion = (await source.loadCatalog()).version;
      source.setScenario(SampleWorkspaceScenario.waiting);
      final pending = source.loadSummary();
      final rejected = expectLater(pending, failure('cancelled'));
      await source.replaceFixture(buildWorkspaceStressFixture());
      await rejected;
      await model.resetView();
      expect(model.canGoBack, isFalse);
      expect(model.selection, azure);
      expect((await source.loadSummary()).records, 208);
      expect((await source.loadCatalog()).version, greaterThan(catalogVersion));
      source.reset();
      expect((await source.loadSummary()).records, 208);
      await source.replaceFixture(sampleWorkspaceJson);
      expect((await source.loadSummary()).records, 31);
      expect(await source.loadRevisions(azure), isEmpty);
    },
  );

  test(
    'cross-page related navigation locates the target and restores exact origin scope and scroll',
    () async {
      final source = SampleWorkspaceSource(
        fixtureJson: buildWorkspaceStressFixture(),
      );
      final model = LibraryController(source);
      addTearDown(model.dispose);
      addTearDown(source.dispose);
      const originQuery = WorkspaceQuery(
        sort: WorkspaceSort.name,
        limit: 5,
        offset: 15,
      );
      final page = await source.queryRecords(originQuery);
      await model.load(originQuery, keepSelection: page.items[2].ref);
      model.scrollOffset = 370;
      final origin = model.selection;
      final all = await source.queryRecords(
        const WorkspaceQuery(sort: WorkspaceSort.name, limit: 500),
      );
      final target = all.items[181].ref;
      await model.openRelated(target);
      expect(model.selection, target);
      expect(model.query.offset, 180);
      expect(model.results!.items.any((r) => r.ref == target), isTrue);
      await model.goBack();
      expect(model.query.offset, 15);
      expect(model.query.limit, 5);
      expect(model.query.sort, WorkspaceSort.name);
      expect(model.selection, origin);
      expect(model.scrollOffset, 370);
    },
  );

  test(
    'declared unused tags remain available without loading a record body; empty mutation does not revive seed trash',
    () async {
      final data = fixture(buildWorkspaceStressFixture());
      data['records'] = [(data['records'] as List).first];
      data['trash'] = [];
      final source = SampleWorkspaceSource(fixtureJson: jsonEncode(data));
      addTearDown(source.dispose);
      expect((await source.loadCatalog()).tags.length, 100);
      final empty = SampleWorkspaceSource();
      addTearDown(empty.dispose);
      await empty.loadCatalog();
      empty.setScenario(SampleWorkspaceScenario.empty);
      final dir = await empty.changeDirectory(
        WorkspaceDirectoryChange(
          operationId: 'empty-dir',
          expectedVersion: (await empty.loadCatalog()).version,
          action: WorkspaceDirectoryAction.create,
          name: '新的空目录',
        ),
      );
      expect(dir, isNotNull);
      expect((await empty.queryRecycled()).total, 0);
      expect((await empty.loadSummary()).records, 0);
    },
  );
}
