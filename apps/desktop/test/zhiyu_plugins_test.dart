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
    await tap(t, find.byKey(const ValueKey('settings-section-plugins')));
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
    'server identity deep link selects the exact host and shares readback with settings and library',
    (t) async {
      final m = await start(t);
      await tap(t, find.byKey(const ValueKey('plugin-select-builtin.profile')));
      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      expect(find.text('主机身份 · 已确认'), findsOneWidget);
      final before = m.library.query;
      await tap(t, find.byKey(const ValueKey('library-host-identity')));
      expect(m.plugins.selected!.id, 'builtin.server');
      expect(m.plugins.tab, PluginTab.settings);
      expect(find.byType(DesktopDialog), findsOneWidget);
      expect(find.text('tokyo.beichen.example:2222'), findsWidgets);
      await capture(t, 'hosts-1440-light-confirmed');
      await tap(t, find.byKey(const ValueKey('host-revoke')));
      expect(
        (await m.source.hosts.read(
          const WorkspaceHostTarget.record(
            WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure'),
          ),
        )).state,
        WorkspaceHostState.revoked,
      );
      await tap(t, find.byKey(const ValueKey('host-close')));
      expect(find.text('SSH 主机信任'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('host-state-information:azure')),
        findsOneWidget,
      );
      await capture(t, 'hosts-1440-light-settings');
      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      expect(m.library.detail!.record.ref.id, 'azure');
      expect(m.library.query, before);
      expect(find.text('主机身份 · 已撤销'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('workspace-nav-settings')));
      expect(
        find.byType(DesktopDialog),
        findsNothing,
      ); // Consumed route, no repeated popup.
      await tap(t, find.byKey(const ValueKey('host-open-information:aliyun')));
      await tap(t, find.byKey(const ValueKey('host-confirm')));
      expect(find.text('已确认'), findsWidgets);
      await tap(t, find.byKey(const ValueKey('host-view-record')));
      expect(m.library.detail!.record.ref.id, 'aliyun');
      expect(find.text('主机身份 · 已确认'), findsOneWidget);
    },
  );

  testWidgets(
    'dark200 host changes warn, missing fingerprints block confirmation and disabled plugin retains revocation',
    (t) async {
      final m = await start(t, dark: true);
      const target = WorkspaceHostTarget.record(
        WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure'),
      );
      final original = await m.source.hosts.read(target);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(
        t,
        find.byKey(const ValueKey('preview-host-fingerprintChanged')),
      );
      await tap(t, find.byKey(const ValueKey('plugin-tab-settings')));
      await tap(t, find.byKey(const ValueKey('host-open-information:azure')));
      expect(find.text('指纹已变化'), findsWidgets);
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('host-confirm')))
            .onPressed,
        isNull,
      );
      await t.ensureVisible(find.text('当前 ED25519 指纹'));
      await t.pumpAndSettle();
      await capture(t, 'hosts-1280-dark-200-changed');
      await tap(t, find.byKey(const ValueKey('host-acknowledge-change')));
      await tap(t, find.byKey(const ValueKey('host-confirm')));
      expect(
        (await m.source.hosts.read(target)).state,
        WorkspaceHostState.trusted,
      );
      await tap(t, find.byKey(const ValueKey('host-close')));
      await tap(t, find.byKey(const ValueKey('plugin-toggle')));
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      await tap(t, find.byKey(const ValueKey('host-open-information:azure')));
      await tap(t, find.byKey(const ValueKey('host-revoke')));
      expect(
        (await m.source.hosts.read(target)).state,
        WorkspaceHostState.revoked,
      );
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('host-confirm')))
            .onPressed,
        isNull,
      );
      await capture(t, 'hosts-1280-dark-200-disabled-revoked');
      await tap(t, find.byKey(const ValueKey('host-close')));
      m.source.observeHost(original.endpoint!, null);
      await t.pumpAndSettle();
      await tap(t, find.byKey(const ValueKey('host-open-information:azure')));
      expect(find.text('尚未取得指纹，不能确认主机。'), findsOneWidget);
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('host-confirm')))
            .onPressed,
        isNull,
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'host save failure, stale review and unknown reply retain exact intent and reconcile without replay',
    (t) async {
      final m = await start(t);
      await tap(t, find.byKey(const ValueKey('plugin-tab-settings')));
      await tap(t, find.byKey(const ValueKey('host-open-information:aliyun')));
      m.source.nextSaveFailure = const WorkspaceFailure('offline', '合成主机保存失败');
      await tap(t, find.byKey(const ValueKey('host-confirm')));
      expect(find.text('合成主机保存失败'), findsOneWidget);
      final d = await m.source.readDetail(
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun'),
      );
      await m.source.saveRecord(
        WorkspaceEdit(
          operationId: 'while-reviewing',
          expectedVersion: d.version,
          record: d.record.copyWith(name: '已更新的杭州服务器'),
          values: const {},
        ),
      );
      await t.pumpAndSettle();
      await tap(t, find.byKey(const ValueKey('host-confirm')));
      expect(find.text('主机或插件已变化，请重新读取并核对。'), findsOneWidget);
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('host-confirm')))
            .onPressed,
        isNull,
      );
      await tap(t, find.byKey(const ValueKey('host-refresh')));
      expect(find.text('已更新的杭州服务器'), findsWidgets);
      m.source.loseNextHostReply = true;
      await tap(t, find.byKey(const ValueKey('host-confirm')));
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('host-close')))
            .onPressed,
        isNull,
      );
      await tap(t, find.byKey(const ValueKey('desktop-dialog-close')));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(DesktopDialog), findsOneWidget);
      m.source.setScenario(SampleWorkspaceScenario.failure);
      await tap(t, find.byKey(const ValueKey('host-reconcile')));
      expect(find.text('仍无法确认结果，请稍后核对。'), findsOneWidget);
      await capture(t, 'hosts-1440-light-unknown');
      m.source.setScenario(SampleWorkspaceScenario.ready);
      await tap(t, find.byKey(const ValueKey('host-reconcile')));
      expect(find.byKey(const ValueKey('host-reconcile')), findsNothing);
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('host-confirm')))
            .onPressed,
        isNull,
      );
      await tap(t, find.byKey(const ValueKey('host-close')));
      expect(find.text('已确认'), findsWidgets);
    },
  );

  testWidgets(
    'host panel distinguishes waiting, failed read, retry and true empty states',
    (t) async {
      final m = await start(t);
      m.source.setScenario(SampleWorkspaceScenario.waiting);
      await tap(t, find.byKey(const ValueKey('plugin-tab-settings')));
      expect(find.text('正在读取主机身份…'), findsOneWidget);
      m.source.setScenario(SampleWorkspaceScenario.failure);
      await t.pumpAndSettle();
      expect(find.text('主机身份暂不可用。'), findsOneWidget);
      expect(find.text('还没有服务器或保留的主机身份。'), findsNothing);
      m.source.setScenario(SampleWorkspaceScenario.ready);
      await tap(t, find.byKey(const ValueKey('hosts-retry')));
      expect(
        find.byKey(const ValueKey('host-open-information:azure')),
        findsOneWidget,
      );
      m.source.setScenario(SampleWorkspaceScenario.empty);
      await m.plugins.load();
      await t.pumpAndSettle();
      expect(find.text('还没有服务器或保留的主机身份。'), findsOneWidget);
    },
  );
  testWidgets(
    'closing a waiting host read ignores the cancelled result without reopening the dialog',
    (t) async {
      final m = await start(t);
      await tap(t, find.byKey(const ValueKey('plugin-tab-settings')));
      await tap(t, find.byKey(const ValueKey('host-open-information:azure')));
      m.source.setScenario(SampleWorkspaceScenario.waiting);
      await tap(t, find.byKey(const ValueKey('host-refresh')));
      expect(find.text('正在读取主机身份…'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('host-close')));
      m.source.setScenario(SampleWorkspaceScenario.ready);
      await t.pumpAndSettle();
      expect(find.byType(DesktopDialog), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'settings install, shared external form, update, removal, generic editing and reinstall preserve the original snapshot',
    (t) async {
      final m = await start(t);
      expect(find.text('SSH 主机信任'), findsNothing);
      expect(find.text('插件设置'), findsOneWidget); // Registered server pane.
      await capture(t, 'plugins-1440-light-overview');
      await choose(t, '域名管理-1.0.0.json');
      expect((await m.source.plugins.load()).packages, hasLength(3));
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      expect(m.plugins.selected!.id, 'local.domain');
      expect(find.text('插件设置'), findsNothing); // No external capability pane.
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
