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
import 'package:info_desktop/prototype_icons.dart';
import 'package:info_desktop/desktop_scroll.dart';
import 'package:info_desktop/ui_palette.dart';
import 'package:info_desktop/workspace/library_create_dialog.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/plugins_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

Finder key(String value) => find.byKey(ValueKey(value));
Future<void> tap(WidgetTester t, Finder target) async {
  if (await prepareFixtureAction(t, target)) return;
  if (target.hitTestable().evaluate().isEmpty) await t.ensureVisible(target);
  await t.pumpAndSettle();
  await t.tap(target, kind: ui.PointerDeviceKind.mouse);
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
}

class Metadata implements WorkspacePluginSource {
  Future<WorkspacePluginCatalog> Function() read = () async =>
      WorkspacePluginCatalog(1, []);
  @override
  Future<WorkspacePluginCatalog> load() => read();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const output = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (!Platform.isMacOS) return;
    final fonts = await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    if (output.isNotEmpty) {
      await Directory(output).create(recursive: true);
      await File('$output/fonts.json').writeAsString(jsonEncode(fonts));
    }
  });
  for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'chooser descriptions, destinations and scaling $size dark=$dark scale=$scale',
          (t) async {
            t.view.physicalSize = size;
            t.view.devicePixelRatio = 1;
            t.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(t.view.resetPhysicalSize);
            addTearDown(t.view.resetDevicePixelRatio);
            addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
            final shadows = debugDisableShadows;
            debugDisableShadows = false;
            try {
              await t.pumpWidget(
                const RepaintBoundary(
                  key: ValueKey('chooser-capture'),
                  child: PreviewWorkspace(inputsBuilder: fixtureInputs),
                ),
              );
              await t.pumpAndSettle();
              if (dark) {
                await tap(t, key('preview-guide'));
                await tap(t, key('preview-theme-dark'));
              }
              final model = t
                  .widget<LibraryPage>(find.byType(LibraryPage))
                  .controller;
              final originalCount = (await model.source.loadSummary()).records;
              for (final id in [
                'library-detail-expand',
                'library-record-actions',
              ]) {
                final icon = find.descendant(
                  of: key(id),
                  matching: find.byType(PrototypeIcon),
                );
                expect(t.getSize(icon), const Size(19, 19));
                expect(t.getSize(key(id)), const Size(36, 36));
              }
              expect(find.byTooltip('资料操作'), findsOneWidget);

              await tap(t, key('library-create'));
              expect(find.text('保存到 自托管服务'), findsNothing);
              final palette = UiPalette.of(
                t.element(find.byType(LibraryCreateDialog)),
              );
              Color? renderedColor(String label) => t
                  .renderObject<RenderParagraph>(find.text(label))
                  .text
                  .style!
                  .color;
              expect(renderedColor('设置 · 插件'), palette.muted);
              expect(
                t
                    .renderObject<RenderParagraph>(find.text('添加资料').last)
                    .text
                    .style!
                    .fontWeight,
                FontWeight.w700,
              );
              expect(find.text('连接参数、维护文档与登录凭据，一处查找。'), findsOneWidget);
              expect(key('library-new-type-resume'), findsNothing);
              expect(find.text('普通文件'), findsOneWidget);
              final core = ['generic', 'document', 'file', 'credential'];
              expect(
                t.getTopLeft(key('library-new-type-generic')).dy,
                t.getTopLeft(key('library-new-type-document')).dy,
              );
              expect(
                t.getTopLeft(key('library-new-type-file')).dy,
                greaterThan(t.getTopLeft(key('library-new-type-generic')).dy),
              );
              if (output.isNotEmpty) {
                final boxes = <String, Object>{};
                for (final id in [
                  'desktop-dialog-close',
                  'library-create-intro',
                  ...[
                    'server',
                    'service',
                    'profile',
                    ...core,
                  ].map((id) => 'library-new-type-$id'),
                  'library-create-open-plugins',
                ]) {
                  final r = t.getRect(key(id));
                  boxes[id] = {
                    'x': r.left,
                    'y': r.top,
                    'width': r.width,
                    'height': r.height,
                  };
                }
                final surface = find
                    .descendant(
                      of: find.byType(DesktopDialog),
                      matching: find.byType(Container),
                    )
                    .first;
                final r = t.getRect(surface);
                boxes['surface'] = {
                  'x': r.left,
                  'y': r.top,
                  'width': r.width,
                  'height': r.height,
                };
                final prefix =
                    '$output/${dark ? 'dark' : 'light'}-${size.width.toInt()}-${(scale * 100).toInt()}-chooser';
                await t.runAsync(() async {
                  final image = await t
                      .renderObject<RenderRepaintBoundary>(
                        key('chooser-capture'),
                      )
                      .toImage(pixelRatio: 1);
                  final data = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  await File(
                    '$prefix.png',
                  ).writeAsBytes(data!.buffer.asUint8List());
                  image.dispose();
                  await File('$prefix.json').writeAsString(
                    jsonEncode({
                      'viewport': {'width': size.width, 'height': size.height},
                      'theme': dark ? 'dark' : 'light',
                      'textScale': scale,
                      'boxes': boxes,
                    }),
                  );
                });
              }
              // The actual footer closes its modal before deferred navigation.
              await tap(t, key('library-create-open-plugins'));
              expect(find.byType(DesktopDialog), findsNothing);
              expect(find.byType(PluginsPage), findsOneWidget);
              expect((await model.source.loadSummary()).records, originalCount);
              await tap(t, key('workspace-nav-library'));
              // A type choice still opens the real form, without a second chooser.
              await tap(t, key('library-create'));
              await tap(t, key('library-new-type-generic'));
              expect(find.byType(LibraryCreateDialog), findsNothing);
              expect(key('library-edit-name'), findsOneWidget);
              await t.sendKeyEvent(LogicalKeyboardKey.escape);
              await t.pumpAndSettle();
              expect((await model.source.loadSummary()).records, originalCount);
              expect(t.takeException(), isNull);
              await t.pumpWidget(const SizedBox());
            } finally {
              debugDisableShadows = shadows;
            }
          },
          skip: !Platform.isMacOS,
        );
      }
    }
  }
  testWidgets(
    'metadata wait, failure and retry retain custom and core choices',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final metadata = Metadata();
      final pending = Completer<WorkspacePluginCatalog>();
      metadata.read = () => pending.future;
      const custom = WorkspaceType('acme/custom', '自定义资料', 'plugin');
      final catalog = WorkspaceCatalog(
        directories: [],
        tags: [],
        types: [custom, const WorkspaceType('generic', '通用信息', 'file')],
      );
      LibraryCreateChoice? result;
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          scrollBehavior: const DesktopScrollBehavior(scrollbarGutter: 9),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDesktopDialog<LibraryCreateChoice>(
                    context,
                    builder: (_) => LibraryCreateDialog(
                      catalog: catalog,
                      plugins: metadata,
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      expect(find.text('正在读取模板说明…'), findsOneWidget);
      expect(key('library-new-type-acme/custom'), findsOneWidget);
      expect(key('library-new-type-generic'), findsOneWidget);
      pending.completeError(const WorkspaceFailure('offline', '合成读取失败'));
      await t.pumpAndSettle();
      expect(find.text('模板说明暂不可用，仍可选择内容形式。'), findsOneWidget);
      metadata.read = () async => WorkspacePluginCatalog(2, [
        WorkspacePlugin(
          id: 'acme',
          name: 'Acme',
          version: '1',
          author: 'test',
          description: '来自包元数据的说明',
          digest: 'test',
          origin: 'test',
          templates: [
            WorkspacePluginTemplate(id: 'custom', type: custom, definition: {}),
          ],
        ),
      ]);
      await tap(t, key('library-create-retry'));
      expect(find.text('来自包元数据的说明'), findsOneWidget);
      expect(key('library-create-retry'), findsNothing);
      await tap(t, key('library-new-type-acme/custom'));
      expect((result! as LibraryCreateTemplate).type.id, 'acme/custom');
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'relation hover emphasizes only name and keyboard follows target',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(const PreviewWorkspace(inputsBuilder: fixtureInputs));
      await t.pumpAndSettle();
      await tap(t, find.text('关联资料').first);
      const ref = 'information:blinko';
      final row = key('library-relation-$ref');
      if (row.hitTestable().evaluate().isEmpty) await t.ensureVisible(row);
      await t.pumpAndSettle();
      final palette = UiPalette.of(t.element(row));
      final text = key('library-relation-name-$ref');
      Color? color() => t.renderObject<RenderParagraph>(text).text.style!.color;
      final surface = find
          .descendant(of: row, matching: find.byType(AnimatedContainer))
          .first;
      Color? background() =>
          (t.widget<AnimatedContainer>(surface).decoration! as BoxDecoration)
              .color;
      expect(color(), palette.ink);
      expect(background()!.a, 0);
      final pointer = TestGesture(
        dispatcher: t.sendEventToBinding,
        device: 77,
        pointer: 77,
        kind: ui.PointerDeviceKind.mouse,
      );
      await pointer.addPointer(location: Offset.zero);
      await pointer.moveTo(t.getCenter(row));
      await t.pumpAndSettle();
      expect(color(), palette.accent);
      expect(background()!.a, 0);
      expect(
        t.getSize(key('library-relation-chevron-$ref')),
        const Size(15, 19),
      );
      await pointer.moveTo(Offset.zero);
      await t.pumpAndSettle();
      expect(color(), palette.ink);
      Focus.of(t.element(text)).requestFocus();
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      final model = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
      expect(model.selection!.id, 'blinko');
      expect(model.canGoBack, isTrue);
      await pointer.removePointer();
      await t.pumpWidget(const SizedBox());
    },
  );
}
