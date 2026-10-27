import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

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
  Future<void> ready(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 200; i++) {
      await t.pump();
      if (done()) {
        await t.pumpAndSettle();
        return;
      }
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    fail('Approval UI did not finish reading.');
  }

  ApprovalsController model(WidgetTester t) =>
      t.widget<ApprovalsPage>(find.byType(ApprovalsPage)).controller;
  Future<void> tap(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.pumpAndSettle();
    await t.tap(f);
    await t.pump();
    if (find.byType(ApprovalsPage).evaluate().isNotEmpty) {
      await ready(
        t,
        () => !model(t).busy && !model(t).loading && !model(t).reading,
      );
    } else {
      await t.pumpAndSettle();
    }
    expect(t.takeException(), isNull);
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    final b = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('approvals-capture')),
    );
    await t.runAsync(() async {
      final im = await b.toImage(pixelRatio: 1),
          bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      im.dispose();
    });
  }

  Future<SampleWorkspaceSource> start(
    WidgetTester t, {
    bool dark = false,
  }) async {
    t.view.physicalSize = dark ? const Size(1280, 800) : const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = dark ? 2 : 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('approvals-capture'),
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
    await tap(t, find.byKey(const ValueKey('workspace-nav-approvals')));
    return s;
  }

  testWidgets(
    'inbox paginates/searches, reviews partial field selection, records a decision and revokes that exact result',
    (t) async {
      final s = await start(t), m = model(t);
      m.limit = 2;
      await m.load();
      await t.pumpAndSettle();
      expect(m.results!.total, 5);
      expect(find.byKey(const ValueKey('approval-next')), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('approval-next')));
      expect(m.offset, 2);
      await tap(t, find.byKey(const ValueKey('approval-prev')));
      await tap(t, find.byKey(const ValueKey('approval-field-ttl')));
      await tap(t, find.text('1 小时').last);
      await tap(t, find.byKey(const ValueKey('approval-credential-ttl')));
      await tap(t, find.text('30 分钟').last);
      expect(m.draft!.fieldMinutes, 60);
      expect(m.draft!.credentialMinutes, 30);
      final d = m.detail!,
          wanted = d.scopes.firstWhere((x) => x.fieldKey == 'host');
      for (final x in d.scopes.where((x) => x.requested && x.id != wanted.id)) {
        await tap(t, find.byKey(ValueKey('approval-scope-${x.id}')));
      }
      expect(m.draft!.selected, {wanted.id});
      final scroll = t.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('approval-detail-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scroll.position.jumpTo(0);
      await t.pumpAndSettle();
      await capture(t, 'approval-1440-light-server-review');
      await tap(t, find.byKey(const ValueKey('approval-approve')));
      expect(m.detail!.request.state, WorkspaceApprovalState.approved);
      expect(m.detail!.approved, {wanted.id});
      expect(m.detailScroll, 0);
      expect(
        m.detail!.fieldExpiresAt,
        m.detail!.decidedAt!.add(const Duration(hours: 1)),
      );
      expect(m.detail!.credentialExpiresAt, isNull);
      expect((await s.loadSummary()).pending, 4);
      await capture(t, 'approval-1440-light-decided');
      await tap(t, find.byKey(const ValueKey('approval-revoke')));
      expect(m.detail!.request.state, WorkspaceApprovalState.revoked);
      await t.enterText(find.byKey(const ValueKey('approval-search')), '招聘');
      await ready(t, () => !m.loading && !m.reading);
      expect(m.results!.items.single.id, 'resume');
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.revoked,
      );
    },
  );
  testWidgets(
    'credential detail and submitted request reach the same approval identity and read back its decision',
    (t) async {
      final s = await start(t);
      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      await t.enterText(
        find.byKey(const ValueKey('library-search')),
        'Azure SSH 私钥',
      );
      await t.pumpAndSettle();
      await tap(
        t,
        find.byKey(const ValueKey('library-record-credential:sshkey')),
      );
      await tap(
        t,
        find.byKey(const ValueKey('credential-open-request-server')),
      );
      expect(model(t).selection, 'server');
      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      await tap(t, find.byKey(const ValueKey('credential-use')));
      await t.enterText(
        find.byKey(const ValueKey('credential-request-purpose')),
        '核对审批入口关联',
      );
      await tap(t, find.byKey(const ValueKey('credential-request-submit')));
      final request = (await s.credentials.requests()).singleWhere(
        (r) => r.purpose == '核对审批入口关联',
      );
      await tap(
        t,
        find.byKey(const ValueKey('credential-request-open-approval')),
      );
      final m = model(t);
      expect(m.selection, request.approvalId);
      expect(m.detail!.credential!.id, request.id);
      await tap(t, find.byKey(const ValueKey('approval-approve')));
      expect(m.detail!.request.state, WorkspaceApprovalState.approved);
      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      await tap(
        t,
        find.byKey(ValueKey('credential-open-request-${request.id}')),
      );
      expect(model(t).selection, request.approvalId);
      expect(model(t).detail!.request.state, WorkspaceApprovalState.approved);
      final reread = (await s.credentials.requests()).singleWhere(
        (r) => r.id == request.id,
      );
      expect(reread.state, WorkspaceCredentialRequestState.approved);
      expect(
        (await s.credentials.history(request.ref)).last.operations,
        isEmpty,
      );
    },
  );
  testWidgets(
    'dark200 file version and grouped entry leaves use real controls; approval pins only the selected identities',
    (t) async {
      final s = await start(t, dark: true), m = model(t);
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('approval-select-resume')),
        150,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('approval-inbox-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tap(t, find.byKey(const ValueKey('approval-select-resume')));
      final file = m.detail!.scopes.singleWhere(
            (x) => x.kind == WorkspaceApprovalScopeKind.file,
          ),
          entry = m.detail!.scopes.firstWhere((x) => x.entryId != null);
      await tap(t, find.byKey(ValueKey('approval-expand-${entry.entryId}')));
      await tap(t, find.byKey(ValueKey('approval-scope-${entry.id}')));
      final selector = find.byKey(ValueKey('approval-file-${file.id}'));
      await tap(t, selector);
      await tap(t, find.textContaining('v1 ·').last);
      expect(m.draft!.files[file.id], 1);
      expect(m.draft!.selected, contains(entry.id));
      await t.ensureVisible(selector);
      await t.pumpAndSettle();
      await capture(t, 'approval-1280-dark-200-file-scope');
      await tap(t, find.byKey(const ValueKey('approval-approve')));
      expect(m.detail!.approved, contains(entry.id));
      expect(m.detail!.fileVersions[file.id], 1);
      expect((await s.approvals.read('resume')).fileVersions[file.id], 1);
    },
  );
  testWidgets(
    'env and focus plans have contextual tips; focus approval remains disabled and rejection is real',
    (t) async {
      await start(t);
      final m = model(t);
      await tap(t, find.byKey(const ValueKey('approval-select-token')));
      expect(find.textContaining('GH_TOKEN →'), findsOneWidget);
      expect(find.textContaining('/usr/bin/gh'), findsOneWidget);
      await t.ensureVisible(find.textContaining('GH_TOKEN →'));
      await t.pumpAndSettle();
      await capture(t, 'approval-1440-light-env');
      await tap(t, find.byKey(const ValueKey('approval-tip')));
      expect(find.textContaining('首个命令不是'), findsOneWidget);
      await tap(t, find.text('明白了'));
      await tap(t, find.byKey(const ValueKey('approval-select-fill')));
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('approval-approve')),
            )
            .onPressed,
        isNull,
      );
      await t.ensureVisible(find.byKey(const ValueKey('approval-deny')));
      await t.pumpAndSettle();
      await capture(t, 'approval-1440-light-focus-unavailable');
      await tap(t, find.byKey(const ValueKey('approval-deny')));
      expect(m.detail!.request.state, WorkspaceApprovalState.denied);
    },
  );
  testWidgets(
    'lost decision reply freezes shell, chooser and exact draft through a failed lookup, then reads back without replay',
    (t) async {
      final s = await start(t),
          m = model(t),
          selection = Set.of(model(t).draft!.selected);
      s.loseNextApprovalReply = true;
      await tap(t, find.byKey(const ValueKey('approval-approve')));
      expect(m.uncertain, true);
      expect(m.draft!.selected, selection);
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
      await capture(t, 'approval-1440-light-unknown');
      s.setScenario(SampleWorkspaceScenario.failure);
      await tap(t, find.byKey(const ValueKey('approval-reconcile')));
      expect(m.uncertain, true);
      expect(m.draft!.selected, selection);
      s.setScenario(SampleWorkspaceScenario.ready);
      await tap(t, find.byKey(const ValueKey('approval-reconcile')));
      expect(m.uncertain, false);
      expect(m.detail!.approved, selection);
      expect(
        (await s.credentials.history(
          const WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey'),
        )).last.operations,
        isEmpty,
      );
      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      expect(find.byType(LibraryPage), findsOneWidget);
    },
  );
  testWidgets(
    'conflicting scope review keeps draft, requires explicit reread and does not silently approve changed content',
    (t) async {
      final s = await start(t),
          m = model(t),
          selection = Set.of(model(t).draft!.selected);
      const ref = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
      final old = await s.readDetail(ref);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'other-owner-edit',
          expectedVersion: old.version,
          record: old.record,
          values: const {'host': 'changed.example'},
        ),
      );
      await ready(t, () => !m.loading && !m.reading);
      expect(m.needsReview, true);
      expect(m.draft!.selected, selection);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('approval-approve')),
            )
            .onPressed,
        isNull,
      );
      await tap(t, find.byKey(const ValueKey('approval-review-current')));
      expect(m.needsReview, false);
      expect(m.draft!.selected, selection);
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.pending,
      );
      await tap(t, find.byKey(const ValueKey('approval-approve')));
      expect(m.detail!.request.state, WorkspaceApprovalState.approved);
    },
  );
}
