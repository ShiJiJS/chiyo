import 'support/workspace_fixtures.dart';
import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/settings_page.dart';
import 'package:info_desktop/workspace/settings_controller.dart';
import 'package:info_desktop/workspace/classification_controller.dart';
import 'package:info_desktop/workspace/backup_controller.dart';
import 'package:info_desktop/workspace/runtime_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/plugins_controller.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

class _DeferredSettings extends Fake implements WorkspaceSettingsSource {
  final reads = <Completer<WorkspacePreferences>>[];
  @override
  Future<WorkspacePreferences> read() {
    final c = Completer<WorkspacePreferences>();
    reads.add(c);
    return c.future;
  }
}

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');

  testWidgets(
    'cold settings notification reading and failure never present an unconfirmed off switch',
    (t) async {
      final source = _DeferredSettings(),
          settings = WorkspaceSettingsController(
            source,
            const Stream.empty(),
            onTheme: (_) {},
          ),
          sample = SampleWorkspaceSource(),
          plugins = PluginsController(sample.plugins, const Stream.empty());
      final classifications = ClassificationController(sample);
      final backups = BackupController(sample.backups, sample.changes);
      addTearDown(backups.dispose);
      final runtime = WorkspaceRuntimeController(
        sample.runtime,
        sample.changes,
      );
      addTearDown(runtime.dispose);
      addTearDown(classifications.dispose);
      addTearDown(settings.dispose);
      addTearDown(plugins.dispose);
      addTearDown(sample.dispose);
      settings.select(WorkspaceSettingsSection.notifications);
      final pending = settings.load();
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: WorkspaceSettingsPage(
              controller: settings,
              plugins: plugins,
              classifications: classifications,
              backups: backups,
              runtime: runtime,
              backupPicker: (_) async => null,
              onLibrary: () {},
              pluginBuilder: (_) => const SizedBox(),
              onRequest: (_) {},
            ),
          ),
        ),
      );
      await t.pump();
      expect(
        find.byKey(const ValueKey('settings-notifications')),
        findsNothing,
      );
      expect(find.text('正在读取…'), findsOneWidget);
      source.reads.first.completeError(
        const WorkspaceFailure('offline', '设置读取失败'),
      );
      await pending;
      await t.pumpAndSettle();
      expect(find.text('暂不可用'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-notifications')),
        findsNothing,
      );
      final retry = settings.load();
      source.reads.last.complete(
        const WorkspacePreferences(notifications: false),
      );
      await retry;
      await t.pumpAndSettle();
      expect(
        t
            .widget<DesktopToggle>(
              find.byKey(const ValueKey('settings-notifications')),
            )
            .value,
        false,
      );
    },
  );
  setUpAll(() async {
    if (evidence.isEmpty) return;
    await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await Directory(evidence).create(recursive: true);
  });
  WorkspaceSettingsController model(WidgetTester t) => t
      .widget<WorkspaceSettingsPage>(find.byType(WorkspaceSettingsPage))
      .controller;
  Future<void> ready(WidgetTester t) async {
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> tap(WidgetTester t, Finder f) async {
    if (await prepareFixtureAction(t, f)) return;
    await t.ensureVisible(f);
    await t.pumpAndSettle();
    await t.tap(f);
    await ready(t);
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
        key: ValueKey('settings-capture'),
        child: PreviewWorkspace(inputsBuilder: fixtureInputs),
      ),
    );
    await ready(t);
    final s =
        t.widget<LibraryPage>(find.byType(LibraryPage)).controller.source
            as SampleWorkspaceSource;
    if (dark) {
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-theme-dark')));
    }
    await tap(t, find.byKey(const ValueKey('workspace-nav-settings')));
    return s;
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    await t.runAsync(() async {
      final b = t.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('settings-capture')),
          ),
          image = await b.toImage(pixelRatio: 1),
          data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> select(WidgetTester t, String key, String label) async {
    await tap(t, find.byKey(ValueKey(key)));
    await capture(t, 'settings-menu-$key-${t.view.physicalSize.width.toInt()}');
    await tap(t, find.text(label).last);
  }

  testWidgets(
    'settings theme and notification preferences save in one session source across navigation and the existing guide',
    (t) async {
      final s = await start(t);
      expect(model(t).section, WorkspaceSettingsSection.appearance);
      await capture(t, 'settings-1440-light-appearance');
      await tap(t, find.byKey(const ValueKey('settings-theme-dark')));
      expect((await s.settings.read()).theme, WorkspaceTheme.dark);
      expect(
        Theme.of(t.element(find.byType(WorkspaceSettingsPage))).brightness,
        Brightness.dark,
      );
      await tap(
        t,
        find.byKey(const ValueKey('settings-section-notifications')),
      );
      await tap(t, find.byKey(const ValueKey('settings-notifications')));
      expect((await s.settings.read()).notifications, false);
      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      await tap(t, find.byKey(const ValueKey('workspace-nav-settings')));
      expect(model(t).section, WorkspaceSettingsSection.notifications);
      expect(
        t
            .widget<DesktopToggle>(
              find.byKey(const ValueKey('settings-notifications')),
            )
            .value,
        false,
      );
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-theme-light')));
      expect((await s.settings.read()).theme, WorkspaceTheme.light);
      expect((await s.settings.read()).notifications, false);
    },
  );

  testWidgets(
    'failed settings save retains selection and unknown save locks root navigation until only its original receipt is read',
    (t) async {
      final s = await start(t);
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '设置暂时无法保存，选择保留。');
      await tap(t, find.byKey(const ValueKey('settings-theme-dark')));
      expect(model(t).writeFailure!.code, 'disk_full');
      expect(model(t).draft!.theme, WorkspaceTheme.dark);
      expect(
        Theme.of(t.element(find.byType(WorkspaceSettingsPage))).brightness,
        Brightness.light,
      );
      await capture(t, 'settings-1440-light-save-failure');
      s.settings.loseNextReply = true;
      await tap(t, find.byKey(const ValueKey('settings-save')));
      expect(model(t).frozen, true);
      expect(find.byKey(const ValueKey('preview-guide')), findsNothing);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('settings-section-plugins')),
            )
            .onPressed,
        isNull,
      );
      await tap(t, find.byKey(const ValueKey('settings-reconcile')));
      expect(model(t).frozen, false);
      expect((await s.settings.read()).version, 2);
      expect(model(t).dirty, false);
      expect(
        Theme.of(t.element(find.byType(WorkspaceSettingsPage))).brightness,
        Brightness.dark,
      );
    },
  );

  testWidgets(
    'notification preview opens the exact unapproved request after the modal finishes and never sends an OS notification',
    (t) async {
      final s = await start(t);
      await tap(
        t,
        find.byKey(const ValueKey('settings-section-notifications')),
      );
      await tap(t, find.byKey(const ValueKey('settings-notification-preview')));
      expect(find.textContaining('有新的访问请求'), findsOneWidget);
      await capture(t, 'settings-1440-light-notification-preview');
      await tap(t, find.byKey(const ValueKey('settings-notification-open')));
      expect(find.byType(ApprovalsPage), findsOneWidget);
      final m = t.widget<ApprovalsPage>(find.byType(ApprovalsPage)).controller;
      expect(m.detail!.request.state, WorkspaceApprovalState.pending);
      expect((await s.loadSummary()).pending, 5);
      expect((await s.settings.read()).version, 1);
    },
  );

  testWidgets(
    'dark200 settings read failure retains values and recovers; empty notification metadata has no request destination',
    (t) async {
      final s = await start(t, dark: true);
      await t.ensureVisible(find.byKey(const ValueKey('settings-theme-dark')));
      await ready(t);
      await capture(t, 'settings-1280-dark200-appearance');
      await tap(
        t,
        find.byKey(const ValueKey('settings-section-notifications')),
      );
      await capture(t, 'settings-1280-dark200-notifications');
      s.setScenario(SampleWorkspaceScenario.failure);
      await model(t).load();
      await ready(t);
      expect(model(t).readFailure, isNotNull);
      expect(model(t).value!.theme, WorkspaceTheme.dark);
      s.setScenario(SampleWorkspaceScenario.ready);
      await tap(t, find.byKey(const ValueKey('settings-read-retry')));
      expect(model(t).readFailure, isNull);
      s.setScenario(SampleWorkspaceScenario.empty);
      await tap(t, find.byKey(const ValueKey('settings-notification-preview')));
      expect(find.textContaining('暂无待处理申请'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-notification-open')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'retention preview read failure never permits cleanup and explicit retry reads a fresh scope',
    (t) async {
      final s = await start(t);
      await tap(t, find.byKey(const ValueKey('settings-section-records')));
      await select(t, 'settings-retention-days', '90 天');
      s.setScenario(SampleWorkspaceScenario.failure);
      await tap(t, find.byKey(const ValueKey('settings-records-save')));
      expect(model(t).retentionFailure, isNotNull);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('settings-retention-confirm')),
            )
            .onPressed,
        isNull,
      );
      await capture(t, 'settings-1440-light-retention-read-failure');
      s.setScenario(SampleWorkspaceScenario.ready);
      await tap(t, find.byKey(const ValueKey('settings-retention-retry')));
      expect(model(t).retentionFailure, isNull);
      expect(model(t).retentionPreview!.grants, 0);
      await tap(t, find.byKey(const ValueKey('settings-retention-confirm')));
      expect((await s.settings.read()).retentionDays, 90);
    },
  );

  testWidgets(
    'records settings save from the shared sidebar and cancellation never clears history',
    (t) async {
      final s = await start(t);
      await tap(t, find.byKey(const ValueKey('settings-section-records')));
      await select(t, 'settings-request-minutes', '30 分钟');
      expect((await s.settings.read()).requestMinutes, 120);
      await tap(t, find.byKey(const ValueKey('settings-records-save')));
      expect((await s.settings.read()).requestMinutes, 30);
      s.advanceApprovalClock(const Duration(days: 60));
      await ready(t);
      final total = (await s.grantHistory.query(
        const WorkspaceGrantQuery(),
      )).total;
      await select(t, 'settings-retention-days', '30 天');
      await capture(t, 'settings-1440-light-records');
      await tap(t, find.byKey(const ValueKey('settings-records-save')));
      expect(find.text('核对记录清理范围'), findsOneWidget);
      expect(find.textContaining('条操作结果。'), findsOneWidget);
      await capture(t, 'settings-1440-light-retention-review');
      await tap(t, find.byKey(const ValueKey('settings-retention-cancel')));
      expect((await s.settings.read()).retentionDays, 180);
      expect(model(t).draft!.retentionDays, 30);
      expect(
        (await s.grantHistory.query(const WorkspaceGrantQuery())).total,
        total,
      );
      await tap(t, find.byKey(const ValueKey('settings-records-save')));
      await tap(t, find.byKey(const ValueKey('settings-retention-confirm')));
      expect((await s.settings.read()).retentionDays, 30);
      expect(
        (await s.grantHistory.query(const WorkspaceGrantQuery())).total,
        0,
      );
      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      await tap(t, find.byKey(const ValueKey('workspace-nav-settings')));
      expect(model(t).draft!.requestMinutes, 30);
      expect(model(t).draft!.retentionDays, 30);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'keyboard cancellation returns to the retention launcher dark=$dark',
      (t) async {
        final s = await start(t, dark: dark);
        await tap(t, find.byKey(const ValueKey('settings-section-records')));
        s.advanceApprovalClock(const Duration(days: 60));
        await ready(t);
        await select(t, 'settings-retention-days', '30 天');
        final launcher = find.byKey(const ValueKey('settings-records-save'));
        await t.ensureVisible(launcher);
        final focus = Focus.of(
          t.element(find.descendant(of: launcher, matching: find.byType(Text))),
        );
        focus.requestFocus();
        await ready(t);
        expect(focus.hasPrimaryFocus, isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await ready(t);
        expect(find.text('核对记录清理范围'), findsOneWidget);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await ready(t);
        expect(find.byType(DesktopDialog), findsNothing);
        expect(model(t).draft!.retentionDays, 30);
        expect((await s.settings.read()).retentionDays, 180);
        expect(focus.hasPrimaryFocus, isTrue);
        // Returning to the launcher must allow reopening without a pointer.
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await ready(t);
        expect(find.text('核对记录清理范围'), findsOneWidget);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await ready(t);
      },
    );
  }

  testWidgets(
    'dark200 records confirmation preserves draft after a save failure and reconciles an unknown cleanup without replay',
    (t) async {
      final s = await start(t, dark: true);
      await tap(t, find.byKey(const ValueKey('settings-section-records')));
      s.advanceApprovalClock(const Duration(days: 60));
      await ready(t);
      await select(t, 'settings-retention-days', '30 天');
      await t.ensureVisible(
        find.byKey(const ValueKey('settings-records-save')),
      );
      await ready(t);
      await capture(t, 'settings-1280-dark200-records');
      await tap(t, find.byKey(const ValueKey('settings-records-save')));
      await capture(t, 'settings-1280-dark200-retention-review');
      s.nextSaveFailure = const WorkspaceFailure(
        'disk_full',
        '无法保存记录设置，选择已保留。',
      );
      await tap(t, find.byKey(const ValueKey('settings-retention-confirm')));
      expect(model(t).writeFailure!.code, 'disk_full');
      expect((await s.settings.read()).retentionDays, 180);
      expect(model(t).draft!.retentionDays, 30);
      await tap(t, find.byKey(const ValueKey('settings-records-save')));
      s.settings.loseNextReply = true;
      await tap(t, find.byKey(const ValueKey('settings-retention-confirm')));
      expect(model(t).uncertain, true);
      await tap(t, find.byKey(const ValueKey('settings-reconcile')));
      expect(model(t).uncertain, false);
      expect((await s.settings.read()).retentionDays, 30);
    },
  );
}
