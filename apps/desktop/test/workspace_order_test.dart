import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_fixture.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_order.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

WorkspaceRecordSummary summary(
  String id,
  String name, {
  WorkspaceRecordKind kind = WorkspaceRecordKind.information,
}) => WorkspaceRecordSummary(
  ref: WorkspaceRecordRef(kind, id),
  name: name,
  description: '',
  type: const WorkspaceType('note', '普通信息', 'file'),
  updatedAt: DateTime.utc(2026, 10, 28),
);

void main() {
  test('desktop Chinese names sort by locale, not Unicode code points', () {
    final records = [
      summary('z', 'Zoo'),
      summary('c', '长沙'),
      summary('a', 'Alpha'),
      summary('b', '北京'),
      summary('l', '阿里云'),
    ];
    sortWorkspaceSummaries(records, WorkspaceSort.name);
    // Each platform retains its native Chinese/Latin grouping; both collate
    // Chinese names by pronunciation rather than their Unicode code points.
    expect(
      records.map((r) => r.name),
      Platform.isWindows
          ? ['Alpha', 'Zoo', '阿里云', '北京', '长沙']
          : ['阿里云', '北京', '长沙', 'Alpha', 'Zoo'],
    );
  }, skip: !Platform.isMacOS && !Platform.isWindows);

  test(
    'canonical equivalents use typed-ID ties and remain stable on reuse',
    () {
      final records = [
        summary('same', 'é'),
        summary('same', 'e\u0301', kind: WorkspaceRecordKind.credential),
        summary('a', 'é'),
      ];
      for (var round = 0; round < 20; round++) {
        records.setAll(0, records.reversed.toList());
        sortWorkspaceSummaries(records, WorkspaceSort.name);
        expect(records.map((r) => r.ref.key), [
          'credential:same',
          'information:a',
          'information:same',
        ]);
      }
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );

  test(
    'UTF-16 names include NULs, supplementary characters and lexical digits',
    () {
      final records = [
        summary('supp-a', '𠮷乙'),
        summary('supp-z', '𠮷甲'),
        summary('a', '应用\u0000乙'),
        summary('z', '应用\u0000甲'),
        summary('2', '应用 2'),
        summary('10', '应用 10'),
      ];
      sortWorkspaceSummaries(records, WorkspaceSort.name);
      final ids = records.map((r) => r.ref.id).toList();
      // Inverse IDs ensure truncation cannot pass by falling back to ID order.
      expect(ids.indexOf('z'), lessThan(ids.indexOf('a')));
      expect(ids.indexOf('supp-z'), lessThan(ids.indexOf('supp-a')));
      expect(ids.indexOf('10'), lessThan(ids.indexOf('2')));
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );

  test('empty names collate before text and keep typed-ID ties', () {
    final records = [
      summary('text', '北京'),
      summary('same', ''),
      summary('same', '', kind: WorkspaceRecordKind.credential),
    ];
    sortWorkspaceSummaries(records, WorkspaceSort.name);
    expect(records.map((r) => r.ref.key), [
      'credential:same',
      'information:same',
      'information:text',
    ]);
  }, skip: !Platform.isMacOS && !Platform.isWindows);

  test('updated-date ties retain typed-ID order independently of locale', () {
    final records = [
      summary('same', '阿里云'),
      summary('same', 'Zoo', kind: WorkspaceRecordKind.credential),
      summary('a', '北京'),
    ];
    sortWorkspaceSummaries(records, WorkspaceSort.updated);
    expect(records.map((r) => r.ref.key), [
      'credential:same',
      'information:a',
      'information:same',
    ]);
  });

  test(
    'groups follow sorted first appearance and stay contiguous across pages',
    () async {
      final fixture = jsonDecode(sampleWorkspaceJson) as Map<String, dynamic>;
      final all = (fixture['records'] as List).cast<Map<String, dynamic>>();
      const ids = ['azure', 'blinko', 'aliyunkey', 'aliyun'];
      final dates = ['2026-10-10', '2026-10-12', '2026-10-11', '2026-10-09'];
      fixture['records'] = [
        for (var i = 0; i < ids.length; i++)
          {...all.singleWhere((r) => r['id'] == ids[i]), 'updatedAt': dates[i]},
      ];
      fixture['trash'] = [];
      final source = SampleWorkspaceSource(fixtureJson: jsonEncode(fixture));
      addTearDown(source.dispose);
      final first = await source.queryRecords(
        const WorkspaceQuery(grouping: WorkspaceGrouping.type, limit: 3),
      );
      final second = await source.queryRecords(
        const WorkspaceQuery(
          grouping: WorkspaceGrouping.type,
          offset: 3,
          limit: 3,
        ),
      );
      expect(first.groupCounts.keys, ['service', 'credential', 'server']);
      expect(first.groupCounts.values, [1, 1, 2]);
      expect(second.groupCounts, first.groupCounts);
      expect([...first.items, ...second.items].map((r) => r.ref.id), [
        'blinko',
        'aliyunkey',
        'azure',
        'aliyun',
      ]);
      expect(first.total, 4);
      expect(second.offset, 3);
    },
  );
}
