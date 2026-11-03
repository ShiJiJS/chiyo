import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/library_file.dart';
import 'package:info_desktop/workspace/proposal_reading.dart';
import 'package:info_desktop/workspace/proposal_reading_state.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  testWidgets(
    'returning to an item keeps the chosen original and page without retaining content',
    (t) async {
      final state = ProposalReadingState();
      final reads = <(int, int)>[];
      final attachment = WorkspaceProposalAttachment(
        key: 'resume',
        name: '简历',
        description: '',
        currentVersion: 1,
        versions: [
          for (final label in ['确认稿', '旧稿'])
            WorkspaceProposalOriginal(
              filename: '$label.txt',
              mediaType: 'text/plain',
              byteLength: 20,
              label: label,
              sourceNote: '',
            ),
        ],
      );
      Widget content() => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProposalAttachmentReading(
              attachment: attachment,
              readingState: state,
              readFile: (key, version, page) async {
                reads.add((version, page));
                return WorkspaceFilePreview(
                  file: WorkspaceFileVersion(
                    ref: WorkspaceFileRef('original-$version', version),
                    filename: 'original-$version.txt',
                    mediaType: 'text/plain',
                    byteLength: 20,
                    createdAt: DateTime.utc(2026),
                  ),
                  kind: WorkspaceFilePreviewKind.text,
                  page: page,
                  pageCount: 3,
                  text: '${version == 1 ? '确认稿' : '旧稿'}第${page + 1}页',
                );
              },
            ),
          ),
        ),
      );
      await t.pumpWidget(content());
      await t.pumpAndSettle();
      await t.tap(find.text('旧稿'));
      await t.pumpAndSettle();
      expect(find.text('旧稿第1页'), findsOneWidget);
      // Drive the shared library reader's paging command, then leave this item.
      t
          .widget<LibraryFilePreviewView>(find.byType(LibraryFilePreviewView))
          .onPage(1);
      await t.pumpAndSettle();
      expect(find.text('旧稿第2页'), findsOneWidget);
      await t.pumpWidget(const MaterialApp(home: Text('另一条资料')));
      await t.pumpAndSettle();
      await t.pumpWidget(content());
      await t.pumpAndSettle();
      expect(find.text('旧稿第2页'), findsOneWidget);
      expect(find.text('确认稿第1页'), findsNothing);
      expect(reads.last, (2, 1));
      expect(state.selectedOriginals, {'resume': 2});
      await t.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
