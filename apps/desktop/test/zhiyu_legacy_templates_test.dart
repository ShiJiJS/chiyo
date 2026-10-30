import 'support/workspace_fixtures.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/legacy_templates_controller.dart';
import 'package:info_desktop/workspace/legacy_templates_panel.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/plugins_controller.dart';
import 'package:info_desktop/workspace/plugins_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

class _WaitingLegacy extends Fake implements WorkspaceLegacyTemplateSource {
  final reads = <Completer<List<WorkspaceLegacyTemplate>>>[];
  @override
  Future<List<WorkspaceLegacyTemplate>> load() {
    final c = Completer<List<WorkspaceLegacyTemplate>>();
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
  Future<void> tap(WidgetTester t, Finder f) async {
    if (await prepareFixtureAction(t, f)) return;
    await t.ensureVisible(f);
    await t.pumpAndSettle();
    await t.tap(f);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> enter(WidgetTester t, String key, String value) async {
    final f = find.byKey(ValueKey(key));
    await t.ensureVisible(f);
    await t.enterText(f, value);
    await t.pumpAndSettle();
  }

  Future<void> ready(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 200; i++) {
      await t.pumpAndSettle();
      if (done()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    fail('Expected owner UI result did not finish reading.');
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    final boundary = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('legacy-capture')),
    );
    await t.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1),
          data = await image.toByteData(format: ui.ImageByteFormat.png);
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
      LegacyTemplatesController legacy,
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
        key: ValueKey('legacy-capture'),
        child: PreviewWorkspace(inputsBuilder: fixtureInputs),
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
    final page = t.widget<PluginsPage>(find.byType(PluginsPage));
    await tap(t, find.byKey(const ValueKey('legacy-menu')));
    return (
      library: library,
      plugins: page.controller,
      legacy: page.legacy!,
      source: library.source as SampleWorkspaceSource,
    );
  }

  String field(WorkspaceLegacyTemplate t, String label) =>
      (t.definition['fields'] as List).singleWhere(
            (f) => f['label'] == label,
          )['key']
          as String;
  testWidgets(
    'legacy metadata enters the common editor and creates an independent generic record without changing the source template',
    (t) async {
      final m = await start(t), template = m.legacy.selected!;
      expect(find.text('2个旧版模板'), findsOneWidget);
      await capture(t, 'legacy-1440-light-library');
      await tap(t, find.byKey(const ValueKey('legacy-create')));
      await enter(t, 'library-edit-name', '旧版录入的资料');
      final url = field(template, '访问入口'), note = field(template, '维护说明');
      await enter(t, 'library-edit-$url', 'https://legacy.example');
      await enter(t, 'library-edit-$note', '用途和维护记录');
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(find.byType(DesktopDialog), findsNothing);
      final created = m.library.detail!;
      expect(created.record.type.id, 'generic');
      expect(created.values[url], 'https://legacy.example');
      expect(
        created.definition['legacyDefinitionIds'],
        template.definition['legacyDefinitionIds'],
      );
      expect(find.text('沿用旧版模板第1版的录入结构；字段内容由这份资料独立保存。'), findsOneWidget);
      m.source.reviseLegacyTemplate(template.id);
      await t.pumpAndSettle();
      expect(m.library.detail!.definition, created.definition);
      await tap(t, find.byKey(const ValueKey('workspace-nav-settings')));
      expect(m.plugins.showingLegacy, true);
      expect(m.legacy.selected!.id, template.id);
      expect(find.text('旧版录入辅助 · 第2版 · 2个字段'), findsOneWidget);
    },
  );
  testWidgets(
    'explicit conversion previews real declarations and source mapping, then installs without migrating an existing record',
    (t) async {
      final m = await start(t),
          template = m.legacy.selected!,
          original = await m.source.readDetail(
            const WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure'),
          );
      await tap(t, find.byKey(const ValueKey('legacy-convert')));
      expect(find.textContaining('来自旧版模板第1版'), findsOneWidget);
      expect((await m.source.plugins.load()).packages, hasLength(3));
      await capture(t, 'legacy-1440-light-conversion-review');
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      await ready(
        t,
        () =>
            m.plugins.selected?.id == template.packageId &&
            !m.plugins.showingLegacy,
      );
      expect(m.plugins.selected!.legacySource!['templateId'], template.id);
      expect(
        (await m.source.readDetail(original.record.ref)).definition,
        original.definition,
      );
      expect(
        (await m.source.readDetail(original.record.ref)).version,
        original.version,
      );
      await tap(t, find.byKey(const ValueKey('legacy-menu')));
      expect(find.text('查看已转换插件'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('legacy-convert')));
      await ready(t, () => !m.plugins.showingLegacy);
      expect(find.byType(DesktopDialog), findsNothing);
      expect(m.plugins.selected!.id, template.packageId);
    },
  );
  testWidgets(
    'dark200 legacy attachments use host selection and shared file versions; incompatible conversion stays explicit',
    (t) async {
      final m = await start(t, dark: true);
      await tap(t, find.byKey(const ValueKey('legacy-select-legacy-handover')));
      final template = m.legacy.selected!,
          key = field(template, '交接附件'),
          note = field(template, '交接说明');
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('legacy-convert')))
            .onPressed,
        isNull,
      );
      await t.ensureVisible(find.text('当前声明包格式不支持普通附件字段，不能转换此模板；旧版录入仍可继续使用。'));
      await t.pumpAndSettle();
      await capture(t, 'legacy-1280-dark-200-file-boundary');
      await tap(t, find.byKey(const ValueKey('legacy-create')));
      await enter(t, 'library-edit-name', '文件交接资料');
      await enter(t, 'library-edit-$note', '普通附件交接');
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(find.text('请通过宿主选择每个普通附件，不能用正文替代文件。'), findsOneWidget);
      await tap(t, find.byKey(ValueKey('legacy-file-$key')));
      await ready(
        t,
        () => find
            .byKey(const ValueKey('library-file-choice-image'))
            .evaluate()
            .isNotEmpty,
      );
      await tap(t, find.byKey(const ValueKey('library-file-choice-image')));
      await capture(t, 'legacy-1280-dark-200-file-form');
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      await ready(t, () => find.byType(DesktopDialog).evaluate().isEmpty);
      expect(m.library.detail!.values[note], '普通附件交接');
      expect(
        (await m.source.loadFileHistory(
          m.library.detail!.record.ref,
          key,
        )).versions,
        hasLength(1),
      );
      expect(m.library.detail!.record.type.id, 'generic');
    },
  );
  testWidgets(
    'conversion conflict and lost reply preserve review and reconcile exact installation; authoring guide is reachable and selectable',
    (t) async {
      final m = await start(t), template = m.legacy.selected!;
      await tap(t, find.byKey(const ValueKey('legacy-convert')));
      m.source.reviseLegacyTemplate(template.id);
      await t.pumpAndSettle();
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      expect(find.text('旧版模板已变化，请重新预览转换结果。'), findsOneWidget);
      expect((await m.source.plugins.load()).packages, hasLength(3));
      await tap(t, find.byKey(const ValueKey('plugin-repick')));
      m.source.loseNextPluginReply = true;
      await tap(t, find.byKey(const ValueKey('plugin-change-submit')));
      expect(find.byKey(const ValueKey('plugin-reconcile')), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('plugin-reconcile')));
      await ready(
        t,
        () =>
            !m.plugins.showingLegacy &&
            m.plugins.selected?.id == template.packageId,
      );
      expect(m.plugins.selected!.version, '1.2.0');
      await tap(t, find.byKey(const ValueKey('plugin-authoring-guide')));
      expect(find.byType(SelectableText), findsWidgets);
      expect(find.textContaining('生成后调用只读校验'), findsOneWidget);
      await t.ensureVisible(
        find.byKey(const ValueKey('plugin-authoring-example')),
      );
      await t.pumpAndSettle();
      await capture(t, 'legacy-1440-light-authoring-guide');
      await tap(t, find.byKey(const ValueKey('plugin-authoring-close')));
      expect(find.byType(DesktopDialog), findsNothing);
    },
  );
  testWidgets(
    'legacy waiting and failure do not claim an empty list; retry to real empty remains distinct',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = _WaitingLegacy(),
          changes = StreamController<WorkspaceRecordRef?>.broadcast(),
          s = SampleWorkspaceSource(),
          model = LegacyTemplatesController(f, changes.stream);
      addTearDown(() async {
        model.dispose();
        s.dispose();
        await changes.close();
      });
      final first = model.load();
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: LegacyTemplatesPanel(
              controller: model,
              plugins: s.plugins,
              onConverted: (_) {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('0个旧版模板'), findsNothing);
      expect(find.text('尚未读取'), findsOneWidget);
      f.reads[0].completeError(
        const WorkspaceFailure('unavailable', '旧版模板读取失败'),
      );
      await first;
      await t.pumpAndSettle();
      expect(find.text('旧版模板读取失败'), findsOneWidget);
      expect(find.text('还没有旧版模板。'), findsNothing);
      await tap(t, find.byKey(const ValueKey('legacy-retry')));
      f.reads[1].complete([]);
      await t.pumpAndSettle();
      expect(find.text('0个旧版模板'), findsOneWidget);
      expect(find.text('还没有旧版模板。'), findsOneWidget);
    },
  );
}
