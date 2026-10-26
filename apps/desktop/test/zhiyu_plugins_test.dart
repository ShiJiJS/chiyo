import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/plugins_controller.dart';
import 'package:info_desktop/workspace/plugins_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

class _DeferredPlugins extends Fake implements WorkspacePluginSource {
  final reads = <Completer<WorkspacePluginCatalog>>[];
  @override
  Future<WorkspacePluginCatalog> load() {
    final c = Completer<WorkspacePluginCatalog>();
    reads.add(c);
    return c.future;
  }
}

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
  Future<void> tap(WidgetTester t, Finder target) async {
    await t.ensureVisible(target);
    await t.pumpAndSettle();
    await t.tap(target);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    final boundary = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('plugin-capture')),
    );
    await t.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<
    ({
      LibraryController library,
      PluginsController plugins,
      SampleWorkspaceSource source,
    })
  >
  start(WidgetTester t, {bool dark = false}) async {
    t.view.physicalSize = dark ? const Size(1280, 800) : const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = dark ? 2 : 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('plugin-capture'),
        child: PreviewWorkspace(),
      ),
    );
    await t.pumpAndSettle();
    if (dark) {
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-theme-dark')));
    }
    final library = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
    await tap(t, find.byKey(const ValueKey('workspace-nav-settings')));
    final plugins = t.widget<PluginsPage>(find.byType(PluginsPage)).controller;
    return (
      library: library,
      plugins: plugins,
      source: library.source as SampleWorkspaceSource,
    );
  }

  Future<void> choose(WidgetTester t, String filename) async {
    await tap(t, find.byKey(const ValueKey('plugin-install')));
    await tap(t, find.textContaining(filename).last);
  }

  Future<void> enter(WidgetTester t, String key, String value) async {
    final f = find.byKey(ValueKey(key));
    await t.ensureVisible(f);
    await t.enterText(f, value);
    await t.pumpAndSettle();
  }

  testWidgets(
    'settings install, shared external form, update, removal, generic editing and reinstall preserve the original snapshot',
    (t) async {
      final m = await start(t);
      expect(find.text('SSH 主机信任'), findsNothing);
      expect(find.text('插件设置'), findsNothing); // No empty capability pane.
      await capture(t, 'plugins-1440-light-overview');
      await choose(t, '域名管理-1.0.0.json');
      expect((await m.source.plugins.load()).packages, hasLength(3));
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      expect(m.plugins.selected!.id, 'local.domain');
      await tap(t, find.byKey(const ValueKey('plugin-tab-instructions')));
      expect(find.textContaining('注册商与 DNS 服务分别填写'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('plugin-tab-preview')));
      await tap(t, find.byKey(const ValueKey('plugin-create')));
      await enter(t, 'library-edit-name', '插件流程域名');
      await enter(t, 'library-edit-domain', 'plugin-flow.example');
      await tap(
        t,
        find.byKey(const ValueKey('library-relation-choose-pointsTo')),
      );
      await tap(
        t,
        find.byKey(
          const ValueKey('library-relation-option-pointsTo-information:azure'),
        ),
      );
      await tap(
        t,
        find.byKey(const ValueKey('library-relation-done-pointsTo')),
      );

      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(find.byType(LibraryPage), findsOneWidget);
      final original = m.library.detail!;
      expect(original.record.type.id, 'local.domain/domain');
      expect(original.values['domain'], 'plugin-flow.example');
      expect(original.relations['pointsTo'], [
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure'),
      ]);
      expect(original.definition['templateVersion'], '1.0.0');
      await tap(t, find.byKey(const ValueKey('workspace-nav-settings')));
      expect(m.plugins.selected!.id, 'local.domain');
      await choose(t, '域名管理-1.1.0.json');
      expect(find.text('新增字段：维护负责人'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('plugin-previous-definition')));
      expect(find.text('域名 · v1.0.0'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('plugin-previous-definition')));
      expect(find.text('域名 · v1.0.0'), findsNothing);

      await t.ensureVisible(
        find.descendant(
          of: find.byType(DesktopDialog),
          matching: find.text('域名管理'),
        ),
      );
      await t.pumpAndSettle();
      await capture(t, 'plugins-1440-light-update-diff');
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      expect(
        (await m.source.readDetail(original.record.ref)).definition,
        original.definition,
      );
      await tap(t, find.byKey(const ValueKey('plugin-remove')));
      expect(find.text('1项已有资料的内容、附件、关联与历史均保留。'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      expect(m.plugins.selected!.id, 'builtin.server');
      final title = t.getRect(
        find.byKey(const ValueKey('plugin-selected-title')),
      );
      final pane = t.getRect(find.byKey(const ValueKey('plugin-workspace')));
      expect(title.top, greaterThanOrEqualTo(pane.top));
      expect(title.bottom, lessThanOrEqualTo(pane.bottom));

      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      expect(find.text('模板插件未安装，按保留的字段显示。已有内容可继续编辑。'), findsOneWidget);
      expect(m.library.detail!.version, original.version);
      await m.source.saveRecord(
        WorkspaceEdit(
          operationId: 'legacy-shape',
          expectedVersion: 1,
          record: original.record,
          values: {
            '旧结构': {'原文': '保留原始形状'},
          },
        ),
      );
      await t.pumpAndSettle();
      expect(find.textContaining('"原文"'), findsOneWidget);
      await capture(t, 'plugins-1440-light-missing-record');
      await tap(t, find.text('编辑信息'));
      await enter(t, 'library-edit-domain', 'still-editable.example');
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(m.library.detail!.values['domain'], 'still-editable.example');
      expect(m.library.detail!.values['旧结构'], {'原文': '保留原始形状'});
      expect(m.library.detail!.definition, original.definition);
      expect(m.library.detail!.version, 3);
      await tap(t, find.byKey(const ValueKey('workspace-nav-settings')));
      await choose(t, '域名管理-1.0.0.json');
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      expect(
        find.byKey(const ValueKey('library-template-unavailable')),
        findsNothing,
      );
      expect(m.library.detail!.version, 3);
      expect(m.library.detail!.definition, original.definition);
    },
  );
  testWidgets(
    'invalid package path, failed install and explicit retry retain the review instead of installing early',
    (t) async {
      final m = await start(t);
      await choose(t, '字段格式错误.json');
      expect(
        find.textContaining(r'$.templates[0].fields[0].type'),
        findsOneWidget,
      );
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('plugin-change-submit')),
            )
            .onPressed,
        isNull,
      );
      await capture(t, 'plugins-1440-light-invalid');
      await tap(t, find.byKey(const ValueKey('plugin-repick')));
      await tap(t, find.textContaining('域名管理-1.0.0.json').last);
      m.source.nextSaveFailure = const WorkspaceFailure(
        'offline',
        '安装失败，预览已保留。',
      );
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      expect(find.text('安装失败，预览已保留。'), findsOneWidget);
      expect((await m.source.plugins.load()).packages, hasLength(3));
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      expect(find.byType(DesktopDialog), findsNothing);
      expect((await m.source.plugins.load()).packages, hasLength(4));
    },
  );
  testWidgets(
    'dark200 committed install and uncommitted disable reconcile before any new submission',
    (t) async {
      final m = await start(t, dark: true);
      await choose(t, '域名管理-1.0.0.json');
      m.source.loseNextPluginReply = true;
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('plugin-repick')))
            .onPressed,
        isNull,
      );
      m.source.setScenario(SampleWorkspaceScenario.failure);
      await tap(t, find.byKey(const ValueKey('plugin-reconcile')));
      expect(find.text('仍无法确认结果，请稍后核对。'), findsOneWidget);
      await capture(t, 'plugins-1280-dark-200-unknown');
      m.source.setScenario(SampleWorkspaceScenario.ready);
      await tap(t, find.byKey(const ValueKey('plugin-reconcile')));
      expect((await m.source.plugins.load()).packages, hasLength(4));
      await tap(t, find.byKey(const ValueKey('plugin-toggle')));
      m.source.nextSaveFailure = const WorkspaceFailure(
        'unknown_outcome',
        '未知',
      );
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      await tap(t, find.byKey(const ValueKey('plugin-reconcile')));
      expect(find.text('已确认尚未提交，可重新确认此操作。'), findsOneWidget);
      expect(m.plugins.selected!.enabled, isTrue);
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      expect(m.plugins.selected!.enabled, isFalse);
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('plugin-create')))
            .onPressed,
        isNull,
      );
      expect(
        (await m.source.loadCatalog()).creatableTypes.any(
          (t) => t.id == 'local.domain/domain',
        ),
        isFalse,
      );
      await capture(t, 'plugins-1280-dark-200-disabled');
      await t.ensureVisible(find.byKey(const ValueKey('plugin-create')));
      await t.pumpAndSettle();
      final button = t.getRect(find.byKey(const ValueKey('plugin-create')));
      expect(button.top, greaterThanOrEqualTo(0));
      expect(button.bottom, lessThanOrEqualTo(800));
      await capture(t, 'plugins-1280-dark-200-disabled-actions');
    },
  );
  testWidgets(
    'waiting and failed metadata refresh keep prior detail and retry retains selected package',
    (t) async {
      final m = await start(t);
      await tap(t, find.byKey(const ValueKey('plugin-select-builtin.profile')));
      m.source.setScenario(SampleWorkspaceScenario.waiting);
      final pending = m.plugins.load();
      await t.pumpAndSettle();
      expect(find.text('正在刷新插件…'), findsOneWidget);
      expect(m.plugins.selected!.id, 'builtin.profile');
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('plugin-create')))
            .onPressed,
        isNull,
      );
      m.source.setScenario(SampleWorkspaceScenario.ready);
      await pending;
      await t.pumpAndSettle();
      await tap(t, find.text('重新读取插件'));
      expect(m.plugins.selected!.id, 'builtin.profile');
      expect(m.plugins.failure, isNull);
      m.source.setScenario(SampleWorkspaceScenario.failure);
      await m.plugins.load();
      await t.pumpAndSettle();
      expect(m.plugins.selected!.id, 'builtin.profile');
      expect(m.plugins.failure, isNotNull);
      await tap(t, find.text('重新读取插件'));
      expect(m.plugins.failure, isNull);
      await tap(t, find.byKey(const ValueKey('plugin-filter')));
      await tap(t, find.text('已停用').last);
      expect(find.text('没有这个状态的插件。'), findsOneWidget);
    },
  );
  testWidgets(
    'cold plugin loading and failure never claim a confirmed zero; a real empty response does',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final source = _DeferredPlugins(),
          changes = StreamController<WorkspaceRecordRef?>.broadcast();
      final controller = PluginsController(source, changes.stream);
      addTearDown(() async {
        controller.dispose();
        await changes.close();
      });
      final pending = controller.load();
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: PluginsPage(
              controller: controller,
              onRetry: () => unawaited(controller.load()),
              onCreate: (_) {},
              onRecords: (_) {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('正在读取…'), findsOneWidget);
      expect(find.text('0个插件'), findsNothing);
      source.reads.first.completeError(
        const WorkspaceFailure('offline', '读取失败'),
      );
      await pending;
      await t.pumpAndSettle();
      expect(find.text('暂不可用'), findsOneWidget);
      expect(find.text('0个插件'), findsNothing);
      await tap(t, find.text('重新读取插件'));
      source.reads.last.complete(WorkspacePluginCatalog(1, []));
      await t.pumpAndSettle();
      expect(find.text('0个插件'), findsOneWidget);
      expect(find.text('还没有安装插件。'), findsOneWidget);
    },
  );
}
