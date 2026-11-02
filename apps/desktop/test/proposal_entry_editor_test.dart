import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/proposal_editor.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Relations implements WorkspaceRelationSource {
  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) async => [];
  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery q,
  ) async => WorkspaceResults(items: [], total: 0, offset: 0);
}

void main() {
  testWidgets(
    'real nested entry leaf starts with the proposed value and saves without inventing another field',
    (t) async {
      t.view.physicalSize = const Size(1440, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final record = WorkspaceRecordSummary(
        ref: const WorkspaceRecordRef(
          WorkspaceRecordKind.information,
          'profile-1',
        ),
        name: '个人档案',
        description: '',
        type: const WorkspaceType('profile', '个人档案', 'user'),
        updatedAt: DateTime.utc(2026, 11, 2),
      );
      WorkspaceDetail detail(String body) => WorkspaceDetail(
        record: record,
        version: 1,
        definition: const {
          'fields': [
            {'key': 'education', 'label': '教育经历', 'type': 'entries'},
          ],
          'relations': [],
        },
        values: {
          'education': [
            {
              'entryId': 'entry-1',
              'fieldIds': {
                'title': 'title-id',
                'period': 'period-id',
                'detail': 'detail-id',
              },
              'title': '示例大学',
              'period': '2020–2024',
              'detail': body,
            },
          ],
        },
      );
      final item = WorkspaceProposalItem(
        id: 'profile-1',
        proposed: detail('AI 提议说明'),
        before: detail('原说明'),
        beforeState: WorkspaceProposalBeforeState.available,
        changes: [
          WorkspaceProposalFieldChange(
            intent: WorkspaceProposalFieldIntent.correct,
            key: 'education',
            entryId: 'entry-1',
            leaf: 'detail',
            fieldId: 'detail-id',
            label: '经历说明',
            before: '原说明',
            after: 'AI 提议说明',
            beforeAvailable: true,
          ),
        ],
      );
      WorkspaceProposalItemReview? saved;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => ProposalItemEditor(
                    item: item,
                    review: WorkspaceProposalItemReview.fromItem(item),
                    catalog: WorkspaceCatalog(
                      directories: [],
                      tags: [],
                      types: [record.type],
                    ),
                    relations: _Relations(),
                    onSave: (review) {
                      saved = review;
                      return true;
                    },
                  ),
                ),
                child: const Text('编辑提案'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('编辑提案'));
      await t.pumpAndSettle();
      expect(find.text('AI 提议说明'), findsOneWidget);
      final field = find.byKey(
        const ValueKey('proposal-edit-education:entry-1:detail'),
      );
      await t.enterText(field, '主人核对的经历说明');
      await t.tap(find.byKey(const ValueKey('proposal-edit-keep')));
      await t.pumpAndSettle();
      expect(saved!.values.keys, ['education']);
      final row = (saved!.values['education'] as List).single as Map;
      expect(row['detail'], '主人核对的经历说明');
      expect(row['title'], '示例大学');
      expect((row['fieldIds'] as Map)['detail'], 'detail-id');
      expect(t.takeException(), isNull);
    },
  );
}
