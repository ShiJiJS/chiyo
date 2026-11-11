import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/sync_conflicts_dialog.dart';
import 'package:info_desktop/workspace/workspace_sync.dart';

class _Choices implements WorkspaceSyncReview {
  _Choices(this.review);
  final Map<String, Object?> review;
  bool fail = true, done = false;
  final calls = <(bool, String)>[];
  @override
  Future<List<Map<String, Object?>>> reviewConflicts() async =>
      done ? [] : [review];
  @override
  Future<void> resolveConflict(
    Map<String, Object?> reviewed,
    bool useIncoming,
    String operationId,
  ) async {
    calls.add((useIncoming, operationId));
    if (fail) throw StateError('synthetic lost response');
    done = true;
  }
}

Map<String, Object?> _candidate(String id, String name, String body) => {
  'information': core.informationToJson(
    core.InformationItem(id, name, '合成资料', 2, [
      core.InformationField(
        '$id-field',
        '正文',
        '',
        body,
        2,
        kind: core.FieldKind.textNote,
      ),
    ]),
  ),
};
void main() {
  for (final remote in [false, true]) {
    testWidgets(
      'whole group uses plugin reading, correct labels and stable retry remote=$remote',
      (t) async {
        t.view.physicalSize = const Size(1440, 1000);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final sync = _Choices({
          'cursor': 1,
          'token': 'a' * 64,
          'remote': remote,
          'items': [
            {
              'key': {'kind': 'information', 'id': 'a'},
              'local': _candidate('a', '合成甲', '本机甲正文'),
              'incoming': _candidate('a', '合成甲', '另一份甲正文'),
            },
            {
              'key': {'kind': 'information', 'id': 'b'},
              'local': _candidate('b', '合成乙', '本机乙正文'),
              'incoming': _candidate('b', '合成乙', '另一份乙正文'),
            },
          ],
        });
        final source = SampleWorkspaceSource();
        await t.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSyncConflicts(context, sync, source),
                child: const Text('处理冲突'),
              ),
            ),
          ),
        );
        await t.tap(find.text('处理冲突'));
        await t.pumpAndSettle();
        expect(find.text('本机甲正文'), findsOneWidget);
        expect(find.text('另一份甲正文'), findsOneWidget);
        await t.tap(find.widgetWithText(ChoiceChip, '合成乙'));
        await t.pumpAndSettle();
        expect(find.text('本机乙正文'), findsOneWidget);
        expect(find.text('本机甲正文'), findsNothing);
        await t.tap(find.text(remote ? '使用服务器内容' : '使用本机内容'));
        await t.pumpAndSettle();
        expect(sync.calls.single.$1, false);
        expect(find.text('重试原选择'), findsOneWidget);
        sync.fail = false;
        await t.tap(find.text('重试原选择'));
        await t.pumpAndSettle();
        expect(sync.calls, hasLength(2));
        expect(sync.calls[0], sync.calls[1]);
        expect(find.text('没有需要处理的同步冲突。'), findsOneWidget);
        expect(t.takeException(), isNull);
      },
    );
  }
}
