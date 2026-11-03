import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/library_detail.dart';
import 'package:info_desktop/workspace/library_document.dart';
import 'package:info_desktop/workspace/library_widgets.dart';
import 'package:info_desktop/workspace/proposal_reading.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/template_record_content.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  testWidgets(
    'a custom plugin presents the same fields and Markdown in library and proposal, including changed definitions',
    (t) async {
      t.view.physicalSize = const Size(1440, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final source = SampleWorkspaceSource();
      addTearDown(source.dispose);
      final catalog = await source.loadCatalog();
      for (final label in ['设备编号', '设备标识']) {
        final detail = WorkspaceDetail(
          record: WorkspaceRecordSummary(
            ref: const WorkspaceRecordRef(
              WorkspaceRecordKind.information,
              'plugin-custom',
            ),
            name: '合成设备',
            description: '设备维护资料',
            type: const WorkspaceType(
              'custom-maintenance',
              '设备维护单',
              'document',
            ),
            updatedAt: DateTime.utc(2026, 11, 3),
          ),
          version: 1,
          definition: {
            'id': 'custom-maintenance',
            'fields': [
              {'key': 'serial', 'label': label, 'type': 'text'},
              {'key': 'notes', 'label': '维护记录', 'type': 'multiline'},
              {'key': 'format', 'label': '记录格式', 'type': 'text'},
            ],
            'sections': [
              {
                'kind': 'fields',
                'title': '设备身份',
                'keys': ['serial'],
              },
              {
                'kind': 'text',
                'title': '维护记录',
                'key': 'notes',
                'formatKey': 'format',
              },
            ],
          },
          values: {
            'serial': 'SYNTHETIC-DEVICE-42',
            'notes': '# 同源正文\n\n**需要加粗**',
            'format': 'markdown',
          },
        );
        final item = WorkspaceProposalItem(id: 'candidate', proposed: detail);
        for (final proposal in [false, true]) {
          await t.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: proposal
                      ? ProposalItemReading(
                          item: item,
                          review: WorkspaceProposalItemReview.fromItem(item),
                          catalog: catalog,
                          relations: source,
                          onRecord: (_) {},
                        )
                      : LibraryDetail(
                          detail: detail,
                          source: source,
                          metrics: const LibraryMetrics(1440),
                          revision: 1,
                          onOpen: (_) {},
                          onEdit: null,
                          onSettings: () {},
                          onTag: (_) {},
                          onExpand: () {},
                        ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          expect(find.byType(TemplateRecordContent), findsOneWidget);
          expect(find.text('设备维护单'), findsOneWidget);
          expect(find.text(label), findsOneWidget);
          expect(find.text('SYNTHETIC-DEVICE-42'), findsOneWidget);
          final document = t.widget<LibraryDocument>(
            find.byType(LibraryDocument),
          );
          expect(document.format, 'markdown');
          expect(document.body, '# 同源正文\n\n**需要加粗**');
          expect(t.takeException(), isNull);
        }
        final modification = WorkspaceProposalItem(
          id: 'changed-candidate',
          proposed: detail,
          beforeState: WorkspaceProposalBeforeState.available,
          before: WorkspaceDetail(
            record: detail.record,
            version: 1,
            definition: detail.definition,
            values: {
              ...detail.values,
              'serial': 'SYNTHETIC-OLD',
              'notes': '# 修改前的正文',
            },
          ),
        );
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ProposalItemComparison(
                  item: modification,
                  review: WorkspaceProposalItemReview.fromItem(modification),
                  catalog: catalog,
                  relations: source,
                  onRecord: (_) {},
                  enabled: true,
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.byType(TemplateRecordContent), findsNWidgets(2));
        expect(find.text('修改前'), findsOneWidget);
        expect(find.text('修改后'), findsOneWidget);
        expect(find.text('$label · 已修改'), findsOneWidget);
        final documents = t
            .widgetList<LibraryDocument>(find.byType(LibraryDocument))
            .toList();
        expect(documents.map((d) => d.format), ['markdown', 'markdown']);
        expect(documents.map((d) => d.body), [
          '# 修改前的正文',
          '# 同源正文\n\n**需要加粗**',
        ]);
        expect(t.takeException(), isNull);
      }
    },
  );
}
