import 'support/workspace_fixtures.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/runtime_controller.dart';
import 'package:info_desktop/workspace/runtime_page.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/settings_controller.dart';
import 'package:info_desktop/workspace/settings_page.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_app.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

class _DeferredRuntime extends Fake implements WorkspaceRuntimeSource {
  final reads = <Completer<WorkspaceRuntimeStatus>>[];
  @override
  Future<WorkspaceRuntimeStatus> status() {
    final c = Completer<WorkspaceRuntimeStatus>();
    reads.add(c);
    return c.future;
  }
}

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
    await settleFixture(t);
    expect(t.takeException(), isNull);
  }

  Future<void> until(WidgetTester t, bool Function() condition) async {
    for (var i = 0; i < 300; i++) {
      await t.pump(const Duration(milliseconds: 20));
      if (condition()) {
        await ready(t);
        return;
      }
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    fail('Runtime fixture did not become ready');
  }

  Future<void> tap(WidgetTester t, String key, {bool pending = false}) async {
    if (await prepareFixtureAction(t, find.byKey(ValueKey(key)))) return;
    final f = find.byKey(ValueKey(key));
    if ((key == 'runtime-materials' || key == 'runtime-attachments') &&
        f.evaluate().isEmpty) {
      final advanced = find.byKey(const ValueKey('runtime-maintenance'));
      await t.ensureVisible(advanced);
      await t.tap(advanced);
      await t.pumpAndSettle();
    }
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
            find.byKey(const ValueKey('runtime-capture')),
          ),
          i = await b.toImage(pixelRatio: 1),
          bytes = await i.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      i.dispose();
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
        key: ValueKey('runtime-capture'),
        child: PreviewWorkspace(inputsBuilder: fixtureInputs),
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
    await tap(t, 'preview-runtime-maintenance', pending: true);
    await until(
      t,
      () =>
          find.byType(WorkspaceRuntimePage).evaluate().isNotEmpty &&
          !t
              .widget<WorkspaceRuntimePage>(find.byType(WorkspaceRuntimePage))
              .controller
              .loading,
    );
    return s;
  }

  WorkspaceRuntimeController model(WidgetTester t) => t
      .widget<WorkspaceRuntimePage>(find.byType(WorkspaceRuntimePage))
      .controller;
  Future<void> fault(WidgetTester t, String key) async {
    await tap(t, 'preview-guide');
    await tap(t, key);
  }

  testWidgets(
    'cold runtime state and read failure do not claim an available service or enable mutation',
    (t) async {
      final s = SampleWorkspaceSource(),
          source = _DeferredRuntime(),
          m = WorkspaceRuntimeController(source, const Stream.empty()),
          p = WorkspaceSettingsController(
            s.settings,
            const Stream.empty(),
            onTheme: (_) {},
          );
      addTearDown(m.dispose);
      addTearDown(p.dispose);
      addTearDown(s.dispose);
      await p.load();
      final pending = m.load();
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: WorkspaceRuntimePage(
              controller: m,
              preferences: p,
              onRequest: (_) {},
            ),
          ),
        ),
      );
      await t.pump();
      expect(find.text('本机服务运行中'), findsNothing);
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('runtime-quit')))
            .onPressed,
        isNull,
      );
      source.reads.first.completeError(
        const WorkspaceFailure('offline', '运行状态读取失败'),
      );
      await pending;
      await ready(t);
      expect(find.text('运行状态读取失败'), findsOneWidget);
      final retry = m.load();
      source.reads.last.complete(await s.runtime.status());
      await retry;
      await ready(t);
      expect(find.text('本机服务运行中'), findsOneWidget);
      await tap(t, 'runtime-materials');
      expect(
        find.byKey(const ValueKey('runtime-maintenance-empty')),
        findsOneWidget,
      );
      await tap(t, 'runtime-maintenance-close');
    },
  );
  testWidgets(
    'settings material flow retains unconfirmed processes, retries ended materials and routes to exact original request',
    (t) async {
      final s = await start(t), m = model(t);
      await capture(t, 'runtime-1440-light-overview');
      await tap(t, 'runtime-materials');
      await tap(t, 'runtime-maintenance-check');
      expect(m.result!.released, 0);
      expect(m.result!.retained, 2);
      await capture(
        t,
        'runtime-1440-light-materials-retained',
        focus: 'runtime-maintenance-result',
      );
      await tap(t, 'runtime-maintenance-close');
      await fault(t, 'preview-runtime-cleanup-ready');
      await tap(t, 'runtime-materials');
      await tap(t, 'runtime-maintenance-check');
      expect(m.result!.released, 1);
      expect(m.result!.retained, 1);
      final unknown = m.value!.materials.singleWhere(
        (e) => e.state == WorkspaceExecutionState.unknown,
      );
      expect(unknown.processEnded, false);
      await tap(t, 'runtime-material-request-${unknown.operationId}');
      expect(find.byType(ApprovalsPage), findsOneWidget);
      expect(
        t
            .widget<ApprovalsPage>(find.byType(ApprovalsPage))
            .controller
            .detail!
            .request
            .id,
        'server',
      );
      expect(
        (await s.runtime.status()).materials
            .singleWhere((e) => e.operationId == unknown.operationId)
            .processEnded,
        false,
      );
    },
  );
  testWidgets(
    'dark 200% attachment maintenance shows failure, pending identity and explicit cleanup without deleting original files',
    (t) async {
      final s = await start(t, dark: true),
          m = model(t),
          before = await s.readDetail(
            const WorkspaceRecordRef(WorkspaceRecordKind.information, 'resume'),
          );
      await tap(t, 'runtime-attachments');
      s.runtime.nextMaintenanceFailure = const WorkspaceFailure(
        'identity_unavailable',
        '登记身份暂时无法核查',
      );
      await tap(t, 'runtime-maintenance-check');
      expect(m.failure!.code, 'identity_unavailable');
      await capture(
        t,
        'runtime-1280-dark200-attachments-failure',
        focus: 'runtime-maintenance-error',
      );
      await tap(t, 'runtime-maintenance-check');
      expect(m.result!.retained, 2);
      s.runtime.allowCleanup();
      await ready(t);
      await tap(t, 'runtime-maintenance-check');
      expect(m.result!.released, 1);
      expect(m.result!.retained, 1);
      await capture(
        t,
        'runtime-1280-dark200-attachments-result',
        focus: 'runtime-maintenance-result',
      );
      expect((await s.readDetail(before.record.ref)).values, before.values);
      await tap(t, 'runtime-copy-request-copy-active');
      expect(
        t
            .widget<ApprovalsPage>(find.byType(ApprovalsPage))
            .controller
            .detail!
            .request
            .id,
        'resume',
      );
    },
  );
  testWidgets(
    'background save failure preserves choice; close with background disabled requires cancellable quit confirmation',
    (t) async {
      final s = await start(t), m = model(t);
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '偏好保存失败');
      await tap(t, 'runtime-background');
      final p = t
          .widget<WorkspaceSettingsPage>(find.byType(WorkspaceSettingsPage))
          .controller;
      expect(p.draft!.background, false);
      expect((await s.settings.read()).background, true);
      await tap(t, 'runtime-background-retry');
      expect((await s.settings.read()).background, false);
      await tap(t, 'runtime-close-window');
      expect(
        find.byKey(const ValueKey('runtime-quit-confirm')),
        findsOneWidget,
      );
      await capture(t, 'runtime-1440-light-quit-review');
      // Invalidate on a changed runtime fact. A clock refresh before any
      // expiry does not itself change the confirmed shutdown scope.
      s.runtime.setAvailability(menuBar: false);
      await ready(t);
      expect(find.byKey(const ValueKey('runtime-quit-confirm')), findsNothing);
      await tap(t, 'runtime-quit-preview-retry');
      expect(
        find.byKey(const ValueKey('runtime-quit-confirm')),
        findsOneWidget,
      );
      await tap(t, 'runtime-quit-cancel');
      expect(m.value!.serviceAvailable, true);
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.approved,
      );
      await p.setBackground(true);
      await ready(t);
      await tap(t, 'runtime-close-window');
      expect(m.failure!.code, 'menu_bar_unavailable');
      expect(m.value!.windowHidden, false);
    },
  );
  testWidgets(
    'save-failed quit retains readable data, ends grants and retries to preview stop without terminating the renderer',
    (t) async {
      final s = await start(t), m = model(t);
      await fault(t, 'preview-runtime-saveFailed');
      await tap(t, 'runtime-quit');
      await tap(t, 'runtime-quit-confirm');
      expect(m.value!.phase, WorkspaceRuntimePhase.saveFailed);
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.sessionEnded,
      );
      await capture(
        t,
        'runtime-1440-light-save-failed',
        focus: 'runtime-quit-result',
      );
      await tap(t, 'runtime-quit-cancel');
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('settings-section-appearance')),
            )
            .onPressed,
        isNull,
      );
      expect(
        (await s.readDetail(
          const WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure'),
        )).record.name,
        isNotEmpty,
      );
      await tap(t, 'runtime-quit');
      await tap(t, 'runtime-quit-confirm');
      await tap(t, 'runtime-quit-cancel');
      expect(
        find.byKey(const ValueKey('preview-runtime-resume')),
        findsNothing,
      );
      expect(m.value!.phase, WorkspaceRuntimePhase.stopped);
      await capture(t, 'runtime-1440-light-stopped');
      await tap(t, 'preview-runtime-resume');
      expect(find.byType(WorkspaceRuntimePage), findsOneWidget);
      expect(m.value!.phase, WorkspaceRuntimePhase.running);
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.sessionEnded,
      );
    },
  );
  testWidgets(
    'unknown quit locks escape and navigation; verified termination failure retries only exit and keeps preview closable',
    (t) async {
      final s = await start(t, dark: true), m = model(t);
      s.runtime.nextQuitPhase = WorkspaceRuntimePhase.terminationFailed;
      await tap(t, 'runtime-quit');
      s.runtime.loseNextReply = true;
      await tap(t, 'runtime-quit-confirm');
      expect(m.uncertain, true);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('runtime-quit-cancel')),
            )
            .onPressed,
        isNull,
      );
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await ready(t);
      expect(
        find.byKey(const ValueKey('runtime-quit-reconcile')),
        findsOneWidget,
      );
      final app = t.widget<ZhiyuApp>(find.byType(ZhiyuApp));
      app.controller.navigate(WorkspacePage.library);
      await ready(t);
      expect(app.controller.location.page, WorkspacePage.settings);
      await capture(
        t,
        'runtime-1280-dark200-quit-unknown',
        focus: 'runtime-quit-error',
      );
      await tap(t, 'runtime-quit-reconcile');
      expect(m.value!.phase, WorkspaceRuntimePhase.terminationFailed);
      await tap(t, 'runtime-quit-cancel');
      await capture(t, 'runtime-1280-dark200-termination-failed');
      await tap(t, 'runtime-finish-exit');
      expect(m.value!.phase, WorkspaceRuntimePhase.stopped);
      await tap(t, 'preview-runtime-resume');
      expect(find.byType(WorkspaceRuntimePage), findsOneWidget);
    },
  );
}
