import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/proposal_reading.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

WorkspaceRecordSummary _record(String id, String name) =>
    WorkspaceRecordSummary(
      ref: WorkspaceRecordRef(WorkspaceRecordKind.information, id),
      name: name,
      description: '',
      type: const WorkspaceType('server', '服务器', 'server'),
      updatedAt: DateTime.utc(2026, 11, 2),
    );

class _Relations implements WorkspaceRelationSource {
  final calls = <Set<WorkspaceRecordRef>>[];
  final rows = [
    _record('old', '原部署服务器'),
    _record('new', '新部署服务器'),
    _record('doc', '维护说明'),
  ];
  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) async {
    final requested = refs.toSet();
    calls.add(requested);
    return rows.where((r) => requested.contains(r.ref)).toList();
  }

  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  ) async => WorkspaceResults(items: rows, total: rows.length, offset: 0);
}

void main() {
  testWidgets(
    'approval shows both target names and removed links, including targets present only before the update',
    (tester) async {
      final source = _Relations();
      final old = source.rows[0].ref,
          next = source.rows[1].ref,
          doc = source.rows[2].ref;
      final before = WorkspaceDetail(
        record: _record('item', '测试服务'),
        version: 1,
        definition: const {
          'relations': [
            {'key': 'hostedOn', 'label': '部署在'},
            {'key': 'docs', 'label': '维护文档'},
          ],
        },
        relations: {
          'hostedOn': [old],
          'docs': [doc],
        },
      );
      final after = WorkspaceProposalItemReview(
        itemId: 'item',
        name: '测试服务',
        description: '',
        values: const {},
        relations: {
          'hostedOn': [next],
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProposalRelationChanges(
                before: before,
                after: after,
                source: source,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('关联：部署在'), findsOneWidget);
      expect(find.text('原部署服务器'), findsOneWidget);
      expect(find.text('新部署服务器'), findsOneWidget);
      expect(find.text('关联：维护文档'), findsOneWidget);
      expect(find.text('维护说明'), findsOneWidget);
      expect(find.text('未关联'), findsOneWidget);
      expect(source.calls.single, {old, next, doc});
      expect(tester.takeException(), isNull);
    },
  );
}
