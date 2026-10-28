import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/agents_controller.dart';
import 'package:info_desktop/workspace/agents_page.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'workspace_agents_test.dart' show AgentPort;

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    final fonts = await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await Directory(evidence).create(recursive: true);
    await File('$evidence/fonts.json').writeAsString(jsonEncode(fonts));
  });
  Future<void> ready(WidgetTester t) async {
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> tap(WidgetTester t, String key, {bool pending = false}) async {
    final f = find.byKey(ValueKey(key));
    await t.ensureVisible(f);
    await t.pump();
    await t.tap(f);
    if (pending) {
      await t.pump();
    } else {
      await ready(t);
    }
  }

  Future<void> capture(WidgetTester t, String name, {String? focus}) async {
    if (evidence.isEmpty) return;
    if (focus != null) {
      await t.ensureVisible(find.byKey(ValueKey(focus)));
      await ready(t);
    }
    await t.runAsync(() async {
      final b = t.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('agents-capture')),
          ),
          i = await b.toImage(pixelRatio: 1),
          bytes = await i.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      i.dispose();
    });
  }

  WorkspaceAgentsController model(WidgetTester t) => t
      .widget<WorkspaceAgentsPage>(find.byType(WorkspaceAgentsPage))
      .controller;
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
        key: ValueKey('agents-capture'),
        child: PreviewWorkspace(),
      ),
    );
    await ready(t);
    final s =
        t.widget<LibraryPage>(find.byType(LibraryPage)).controller.source
            as SampleWorkspaceSource;
    await tap(t, 'preview-guide');
    if (dark) {
      await tap(t, 'preview-theme-dark');
      await tap(t, 'preview-guide');
    }
    await tap(t, 'preview-agents-ready');
    return s;
  }

  testWidgets(
    'normal settings connection has zero grants and routes to exact request only after modal closes',
    (t) async {
      final s = await start(t), m = model(t);
      expect(m.available, true);
      expect(m.value!.connection, WorkspaceAgentConnection.ready);
      expect(m.value!.session.activeGrants, 0);
      await capture(t, 'agents-1440-light-overview');
      await tap(t, 'agents-session');
      expect(m.session!.requests.length, 5);
      await capture(t, 'agents-1440-light-session');
      final id = m.session!.requests.first.id;
      await tap(t, 'agents-request-$id');
      expect(find.byType(ApprovalsPage), findsOneWidget);
      expect(
        t
            .widget<ApprovalsPage>(find.byType(ApprovalsPage))
            .controller
            .detail!
            .request
            .id,
        id,
      );
      expect(
        (await s.approvals.read(id)).request.state,
        WorkspaceApprovalState.pending,
      );
    },
  );
  testWidgets(
    'changed command diagnostic stays untrusted, failure retries and help performs no installation',
    (t) async {
      final s = await start(t), m = model(t);
      await s.agents.setScenario(SampleAgentScenario.changedCommand);
      await ready(t);
      await tap(t, 'agents-diagnostics');
      expect(m.report!.hooksReady, false);
      expect(find.byType(SelectableText), findsNWidgets(3));
      expect(find.textContaining('定义已变更'), findsNWidgets(3));
      await capture(t, 'agents-1440-light-command-changed');
      s.agents.nextDiagnosticFailure = const WorkspaceFailure(
        'offline',
        '诊断暂不可读',
      );
      await tap(t, 'agents-detail-retry');
      expect(m.report, isNull);
      expect(find.text('诊断暂不可读'), findsOneWidget);
      await capture(t, 'agents-1440-light-diagnostic-error');
      await tap(t, 'agents-detail-retry');
      expect(m.report, isNotNull);
      await tap(t, 'agents-flow-close');
      final before = await s.agents.read();
      await tap(t, 'agents-setup');
      await capture(t, 'agents-1440-light-setup');
      await tap(t, 'agents-flow-close');
      await tap(t, 'agents-rules');
      await capture(t, 'agents-1440-light-rules');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await ready(t);
      expect((await s.agents.read()).fingerprint, before.fingerprint);
      expect(m.view, isNull);
    },
  );
  testWidgets(
    'dark 200% missing tools, mismatch and root end never expose guessed or active grants',
    (t) async {
      final s = await start(t, dark: true), m = model(t);
      await s.agents.setScenario(SampleAgentScenario.missingSkill);
      await ready(t);
      expect(m.value!.connection, WorkspaceAgentConnection.toolsMissing);
      await capture(t, 'agents-1280-dark200-tools');
      await tap(t, 'agents-diagnostics');
      await capture(t, 'agents-1280-dark200-diagnostics');
      await capture(
        t,
        'agents-1280-dark200-hook-end',
        focus: 'agents-hook-SessionEnd',
      );
      await tap(t, 'agents-flow-close');
      await s.agents.setScenario(SampleAgentScenario.bindingMismatch);
      await ready(t);
      await tap(t, 'agents-session');
      expect(m.session!.requests, isEmpty);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('agents-request-'),
        ),
        findsNothing,
      );
      await capture(t, 'agents-1280-dark200-mismatch');
      await s.agents.setScenario(SampleAgentScenario.ended);
      await ready(t);
      expect(m.session!.session.state, WorkspaceAgentSessionState.ended);
      expect(m.session!.session.activeGrants, 0);
      expect(m.session!.session.pendingRequests, 0);
      await capture(t, 'agents-1280-dark200-ended', focus: 'agents-flow-close');
      await tap(t, 'agents-flow-close');
      await s.agents.setScenario(SampleAgentScenario.freshSession);
      await ready(t);
      await tap(t, 'agents-session');
      expect(m.session!.requests, isEmpty);
      expect(m.session!.session.activeGrants, 0);
      await tap(t, 'agents-flow-close');
    },
  );
  testWidgets(
    'current chat requests paginate canonical identities and reset safely on association change',
    (t) async {
      final s = await start(t), m = model(t);
      await s.agents.setScenario(SampleAgentScenario.freshSession);
      const ref = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
      for (var i = 0; i < 7; i++) {
        final d = await s.credentials.read(ref),
            session = (await s.credentials.sessions()).first,
            receiver = (await s.credentials.receivers(ref)).first;
        await s.credentials.requestUse(
          WorkspaceCredentialUseDraft(
            operationId: workspaceOperationId(),
            ref: ref,
            expectedRecordVersion: d.recordVersion,
            expectedMaterialVersion: d.materialVersion,
            useGeneration: d.useGeneration,
            purpose: '分页申请 $i',
            receiverId: receiver.id,
            sessionId: session.id,
          ),
        );
      }
      await ready(t);
      await tap(t, 'agents-session');
      final ids = m.session!.requests.map((r) => r.id).toList();
      expect(ids.length, 7);
      await tap(t, 'agents-session-next');
      expect(
        find.byKey(ValueKey('agents-request-${ids.last}')),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('agents-request-${ids.first}')), findsNothing);
      await s.agents.setScenario(SampleAgentScenario.noAssociation);
      await ready(t);
      expect(m.session!.requests, isEmpty);
      expect(find.byKey(const ValueKey('agents-session-next')), findsNothing);
      await tap(t, 'agents-flow-close');
    },
  );
  testWidgets(
    'cold failed reading never claims connected; read-only diagnostic waiting can close and ignores late result',
    (t) async {
      final s = SampleWorkspaceSource(),
          p = AgentPort(s.agents),
          m = WorkspaceAgentsController(p, const Stream.empty()),
          read = Completer<WorkspaceAgentOverview>();
      addTearDown(m.dispose);
      addTearDown(s.dispose);
      p.readOverride = () => read.future;
      final loading = m.load();
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: WorkspaceAgentsPage(
              controller: m,
              onRequest: (_) {
                fail('No request may be guessed');
              },
            ),
          ),
        ),
      );
      await t.pump();
      expect(find.text('已连接'), findsNothing);
      read.completeError(const WorkspaceFailure('offline', '接入读取失败'));
      await loading;
      await ready(t);
      expect(find.text('暂不可用'), findsOneWidget);
      await tap(t, 'agents-setup');
      await tap(t, 'agents-flow-close');
      await tap(t, 'agents-rules');
      await tap(t, 'agents-flow-close');
      p.readOverride = null;
      await tap(t, 'agents-refresh');
      final late = Completer<WorkspaceAgentOverview>();
      p.diagnosticOverride = () => late.future;
      await tap(t, 'agents-diagnostics', pending: true);
      await t.pump(const Duration(milliseconds: 300));
      expect(m.detailBusy, true);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await ready(t);
      expect(m.view, isNull);
      late.complete(await s.agents.read());
      await ready(t);
      expect(m.report, isNull);
      await tap(t, 'agents-session');
      expect(m.session!.requests.length, 5);
      await tap(t, 'agents-flow-close');
    },
  );
}
