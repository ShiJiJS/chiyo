import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/library_history_dialog.dart';
import 'package:info_desktop/workspace/library_recycle.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

// NAS timestamps are UTC. In China this is the next calendar day, matching the
// real Windows report; other local zones must show their own date and time.
final savedAt = DateTime.utc(2026, 11, 11, 22, 18);
const ref = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');

String localLabel(DateTime value) {
  final local = value.toLocal();
  String pair(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${pair(local.month)}-${pair(local.day)} '
      '${pair(local.hour)}:${pair(local.minute)}';
}

void main() {
  late SampleWorkspaceSource source;
  setUp(() => source = SampleWorkspaceSource(now: () => savedAt));
  tearDown(() => source.dispose());

  testWidgets('history list displays a UTC archive in the device time zone', (
    tester,
  ) async {
    final original = await source.readDetail(ref);
    await source.saveRecord(
      WorkspaceEdit(
        operationId: 'local-time-history',
        expectedVersion: original.version,
        record: original.record,
        values: {'host': 'synthetic.example'},
      ),
    );
    final revision = (await source.loadRevisions(ref)).single;
    expect(revision.archivedAt.isUtc, isTrue);
    expect(revision.archivedAt, savedAt);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () => showLibraryHistory(context, source, ref),
                child: const Text('History'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(
      find.text('v1 · ${original.record.name}\n${localLabel(savedAt)}'),
      findsOneWidget,
    );
    expect((await source.loadRevisions(ref)).single.archivedAt, savedAt);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recycle list uses the local calendar day of the UTC deletion', (
    tester,
  ) async {
    final original = await source.readDetail(ref);
    await source.changeRecord(
      WorkspaceRecordChange(
        operationId: 'local-time-recycle',
        ref: ref,
        expectedVersion: original.version,
        action: WorkspaceRecordAction.recycle,
      ),
    );
    final entry = (await source.queryRecycled()).items.singleWhere(
      (e) => e.record.ref == ref,
    );
    expect(entry.deletedAt.isUtc, isTrue);
    expect(entry.deletedAt, savedAt);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryRecyclePage(
            source: source,
            onBack: () {},
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('回收于 ${localLabel(savedAt).substring(0, 10)}'),
      findsOneWidget,
    );
    expect(
      (await source.queryRecycled()).items
          .singleWhere((e) => e.record.ref == ref)
          .deletedAt,
      savedAt,
    );
    expect(tester.takeException(), isNull);
  });
}
