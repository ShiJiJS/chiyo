import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/proposal_content_preview.dart';
import 'package:info_desktop/workspace/proposal_reading.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  testWidgets(
    'preview coalesces slow reads and retains content until an actual read failure',
    (t) async {
      final source = SampleWorkspaceSource();
      final changes = StreamController<WorkspaceRecordRef?>.broadcast();
      final detail = await source.proposals.read('import');
      final catalog = await source.proposals.catalog();
      final item = detail.items.first;
      final reads = <Completer<WorkspaceProposalItem>>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProposalContentPreview(
                load: () {
                  final read = Completer<WorkspaceProposalItem>();
                  reads.add(read);
                  return read.future;
                },
                changes: changes.stream,
                catalog: catalog,
                relations: source.proposals.relations('import', item.id, 1),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        changes.add(null);
      }
      await t.pump();
      expect(reads, hasLength(1));
      reads.first.complete(item);
      await t.pump();
      expect(reads, hasLength(2));
      expect(find.byType(ProposalItemReading), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      reads.last.complete(item);
      await t.pumpAndSettle();
      expect(find.byType(ProposalItemReading), findsOneWidget);
      changes.add(null);
      await t.pump();
      expect(reads, hasLength(3));
      expect(find.byType(ProposalItemReading), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      reads.last.completeError(const WorkspaceFailure('unavailable', '合成读取失败'));
      await t.pumpAndSettle();
      expect(find.text('合成读取失败'), findsOneWidget);
      expect(find.byType(ProposalItemReading), findsNothing);
      await t.tap(find.text('重新读取内容'));
      await t.pump();
      reads.last.complete(item);
      await t.pumpAndSettle();
      expect(find.byType(ProposalItemReading), findsOneWidget);
      changes.add(null);
      await t.pump();
      changes.add(null);
      await t.pump();
      final count = reads.length;
      await t.pumpWidget(const SizedBox());
      reads.last.complete(item);
      await t.pump();
      expect(reads, hasLength(count), reason: 'No queued reads after unmount');
      expect(t.takeException(), isNull);
      await changes.close();
      source.dispose();
    },
  );
}
