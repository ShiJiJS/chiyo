import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/grant_history_controller.dart';
import 'package:info_desktop/workspace/grant_history_page.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/library_file.dart';
import 'package:info_desktop/workspace/library_history_dialog.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'workspace_approvals_test.dart' show decision;

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await Directory(evidence).create(recursive: true);
  });
  GrantHistoryController model(WidgetTester t) =>
      t.widget<GrantHistoryPage>(find.byType(GrantHistoryPage)).controller;
  Future<void> ready(WidgetTester t) async {
    for (var i = 0; i < 200; i++) {
      await t.pump();
      final pages = find.byType(GrantHistoryPage);
      if (pages.evaluate().isNotEmpty) {
        final m = model(t);
        if (!m.loading &&
            !m.reading &&
            !m.decision.loading &&
            !m.decision.reading &&
            !m.decision.busy) {
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          return;
        }
      } else {
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        return;
      }
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    fail('History UI did not finish reading');
  }

  Future<void> tap(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.pumpAndSettle();
    await t.tap(f);
    await ready(t);
  }

  Future<SampleWorkspaceSource> start(
    WidgetTester t, {
    bool dark = false,
    double width = 1440,
    double? scale,
  }) async {
    t.view.physicalSize = Size(width, width == 1440 ? 900 : 800);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = scale ?? (dark ? 2 : 1);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('history-capture'),
        child: PreviewWorkspace(),
      ),
    );
    await t.pumpAndSettle();
    final s =
        t.widget<LibraryPage>(find.byType(LibraryPage)).controller.source
            as SampleWorkspaceSource;
    if (dark) {
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-theme-dark')));
    }
    return s;
  }

  Future<void> history(WidgetTester t) =>
      tap(t, find.byKey(const ValueKey('workspace-nav-history')));
  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    final b = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('history-capture')),
    );
    await t.runAsync(() async {
      final im = await b.toImage(pixelRatio: 1);
      final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      im.dispose();
    });
  }

  for (final width in [1440.0, 1280.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'R12 history title and detail rail match reference at $width dark=$dark',
        (t) async {
          await start(t, dark: dark, width: width, scale: 1);
          await history(t);
          final pane = find.byType(GrantHistoryPage);
          final title = find.descendant(of: pane, matching: find.text('授权历史'));
          expect(t.getTopLeft(title).dy, closeTo(96, 2));
          final detail = t.getRect(
            find.byKey(const ValueKey('grant-history-detail-scroll')),
          );
          // The scroll viewport excludes the detail pane's 1px left border.
          expect(detail.width + 1, width == 1440 ? 365 : 335);
          expect(detail.top, 66);
          await capture(
            t,
            'matrix-history-${width.toInt()}-${dark ? 'dark' : 'light'}',
          );
          expect(t.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'actual approval links to identical grant history; typed record round trip retains filters, page and reading position',
    (t) async {
      final s = await start(t);
      await tap(t, find.byKey(const ValueKey('workspace-nav-approvals')));
      await tap(t, find.byKey(const ValueKey('approval-approve')));
      final approval = t
          .widget<ApprovalsPage>(find.byType(ApprovalsPage))
          .controller;
      expect(approval.detail!.request.state, WorkspaceApprovalState.approved);
      await tap(t, find.text('查看授权历史'));
      final m = model(t);
      expect(m.selection, 'request:server');
      expect(
        m.detail!.scopes.map((x) => x.id).toSet(),
        approval.detail!.approved,
      );
      await capture(t, 'history-1440-light-approved');
      m.limit = 1;
      await t.enterText(
        find.byKey(const ValueKey('grant-history-search')),
        '代理',
      );
      await ready(t);
      final selection = m.selection, query = m.keyword, offset = m.offset;
      final ref = m.detail!.targets
          .firstWhere((x) => x.record.kind == WorkspaceRecordKind.information)
          .record;
      await tap(t, find.byKey(ValueKey('grant-current-${ref.key}')));
      expect(find.byType(LibraryPage), findsOneWidget);
      final scroll = m.detailScroll;
      await tap(t, find.byKey(const ValueKey('workspace-back')));
      expect(model(t), same(m));
      expect(m.selection, selection);
      expect(m.keyword, query);
      expect(m.offset, offset);
      expect(m.detailScroll, scroll);
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.approved,
      );
    },
  );

  testWidgets(
    'unknown revoke locks root navigation and original receipt readback updates the same approval without replay',
    (t) async {
      final s = await start(t);
      await s.approvals.change(decision(await s.approvals.read('server')));
      await history(t);
      final m = model(t);
      await m.open('request:server');
      await ready(t);
      s.loseNextApprovalReply = true;
      await tap(t, find.byKey(const ValueKey('grant-revoke')));
      expect(m.frozen, true);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('workspace-nav-library')),
            )
            .onPressed,
        isNull,
      );
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('preview-guide')))
            .onPressed,
        isNull,
      );
      await capture(t, 'history-1440-light-revoke-unknown');
      await tap(t, find.byKey(const ValueKey('grant-reconcile')));
      expect(m.frozen, false);
      expect(m.detail!.summary.state, WorkspaceGrantState.revoked);
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.revoked,
      );
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('workspace-nav-library')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'explicit historical snapshot shows exact old content and clears mounted body after purge',
    (t) async {
      final s = await start(t);
      final request = await s.approvals.read('server');
      final field = request.scopes.firstWhere(
        (x) => x.kind == WorkspaceApprovalScopeKind.field,
      );
      await s.approvals.change(decision(request, selected: [field.id]));
      final original = await s.readDetail(field.record);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'history-ui-edit',
          expectedVersion: original.version,
          record: original.record.copyWith(name: '更新后的服务器'),
          values: {'host': 'updated.example'},
        ),
      );
      await history(t);
      await model(t).open('request:server');
      await ready(t);
      await tap(t, find.byKey(ValueKey('grant-snapshot-${field.record.key}')));
      for (
        var i = 0;
        i < 100 && find.byType(LibrarySnapshotView).evaluate().isEmpty;
        i++
      ) {
        await t.pump();
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
      }
      expect(
        t
            .widget<LibrarySnapshotView>(find.byType(LibrarySnapshotView))
            .archive
            .detail
            .values,
        original.values,
      );
      final current = await s.readDetail(field.record);
      final deletion = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'history-ui-recycle',
          ref: field.record,
          expectedVersion: current.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'history-ui-purge',
          ref: field.record,
          expectedVersion: deletion.version,
          entryId: deletion.entryId,
          action: WorkspaceRecordAction.purge,
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(LibrarySnapshotView), findsNothing);
      expect(find.textContaining('不会替换为当前或同名内容'), findsOneWidget);
      await tap(t, find.text('关闭').last);
      expect(model(t).detail!.targets.single.snapshotAvailable, false);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(ValueKey('grant-current-${field.record.key}')),
            )
            .onPressed,
        isNull,
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'history opens its pinned ordinary attachment through the real preview widget',
    (t) async {
      final s = await start(t);
      final request = await s.approvals.read('resume');
      final file = request.scopes.singleWhere(
        (x) => x.kind == WorkspaceApprovalScopeKind.file,
      );
      await s.approvals.change(
        decision(request, selected: [file.id], files: {file.id: 1}),
      );
      await history(t);
      await model(t).open('request:resume');
      await ready(t);
      await tap(t, find.byKey(ValueKey('grant-file-${file.id}')));
      for (
        var i = 0;
        i < 200 && find.byType(LibraryFilePreviewView).evaluate().isEmpty;
        i++
      ) {
        await t.pump();
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
      }
      final preview = t
          .widget<LibraryFilePreviewView>(find.byType(LibraryFilePreviewView))
          .preview;
      expect(preview.file.ref.version, 1);
      expect(
        preview.file.ref,
        file.fileVersions.singleWhere((x) => x.ref.version == 1).ref,
      );
      await t.pumpAndSettle();
      for (
        var i = 0;
        i < 200 &&
            find
                .byWidgetPredicate((w) => w is RawImage && w.image != null)
                .evaluate()
                .isEmpty;
        i++
      ) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await t.pump();
      }
      expect(
        find.byWidgetPredicate((w) => w is RawImage && w.image != null),
        findsOneWidget,
      );
      await capture(t, 'history-1440-light-pinned-file');
      await tap(t, find.text('关闭').last);
      expect(model(t).frozen, false);
    },
  );

  testWidgets(
    'actual guide switches empty, waiting and failure states and history retry recovers',
    (t) async {
      await start(t);
      await history(t);
      final m = model(t);
      Future<void> scenario(String label) async {
        await tap(t, find.byKey(const ValueKey('preview-guide')));
        await t.ensureVisible(find.text(label));
        await t.tap(find.text(label));
        if (label == '持续等待') {
          await t.pump(const Duration(milliseconds: 500));
        } else {
          await t.pumpAndSettle();
        }
      }

      await scenario('空资料');
      expect(m.results!.total, 0);
      expect(find.text('没有匹配的授权记录。'), findsOneWidget);
      await scenario('读取失败');
      expect(m.readFailure, isNotNull);
      await tap(t, find.byKey(const ValueKey('grant-retry')));
      expect(m.readFailure, isNull);
      expect(m.results!.total, greaterThan(0));
      await scenario('持续等待');
      expect(m.loading, true);
      // The modal's full exit, rather than its first closing frame, releases
      // the guide trigger. Waiting spinners deliberately never settle.
      final guide = find.byKey(const ValueKey('preview-guide'));
      for (
        var i = 0;
        i < 100 && t.widget<DesktopButton>(guide).onPressed == null;
        i++
      ) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(t.widget<DesktopButton>(guide).onPressed, isNotNull);
      await t.tap(guide);
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      await t.ensureVisible(find.text('正常资料'));
      await t.tap(find.text('正常资料'));
      await ready(t);
      expect(m.loading, false);
      expect(m.results!.total, greaterThan(0));
    },
  );

  testWidgets(
    'dark200 and narrow history keep readable controls, scrolling and current execution facts',
    (t) async {
      final s = await start(t, dark: true, width: 1280);
      await s.approvals.change(decision(await s.approvals.read('server')));
      s.demonstrateApprovalExecutions('server');
      await history(t);
      final m = model(t);
      await m.open('request:server');
      await ready(t);
      await capture(t, 'history-1280-dark200-grant');
      await tap(t, find.byKey(const ValueKey('grant-filter-ended')));
      expect(m.detail!.legacyNotice, isNotNull);
      await capture(t, 'history-1280-dark200-legacy');
      await t.enterText(
        find.byKey(const ValueKey('grant-history-search')),
        '不存在的合成历史',
      );
      await ready(t);
      expect(m.results!.total, 0);
      expect(find.text('没有匹配的授权记录。'), findsOneWidget);
      t.view.physicalSize = const Size(900, 800);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );
}
