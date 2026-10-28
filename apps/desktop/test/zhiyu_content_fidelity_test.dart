import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/desktop_scroll.dart';
import 'package:info_desktop/workspace/library_entries.dart';
import 'package:info_desktop/workspace/library_document.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/library_detail.dart';
import 'package:info_desktop/workspace/library_widgets.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/workspace_entries.dart';

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
          'R05/R06 reading and raw access $size dark=$dark scale=$scale',
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
              Finder key(String id) => find.byKey(ValueKey(id));
              Future<void> tap(Finder target) async {
                if (target.hitTestable().evaluate().isEmpty) {
                  await t.ensureVisible(target);
                }
                await t.pumpAndSettle();
                await t.tap(target, kind: ui.PointerDeviceKind.mouse);
                await t.pumpAndSettle();
                expect(t.takeException(), isNull);
              }

              ScrollPosition scroll() => t
                  .state<ScrollableState>(
                    find
                        .descendant(
                          of: key('library-detail-scroll'),
                          matching: find.byType(Scrollable),
                        )
                        .first,
                  )
                  .position;
              Map<String, double> rect(Finder f) {
                final r = t.getRect(f);
                return {
                  'x': r.left,
                  'y': r.top,
                  'width': r.width,
                  'height': r.height,
                };
              }

              Future<void> capture(
                String state,
                Map<String, Object> boxes,
              ) async {
                if (output.isEmpty) return;
                final prefix =
                    '$output/${dark ? 'dark' : 'light'}-${size.width.toInt()}-${(scale * 100).toInt()}-$state';
                final model = t
                    .widget<LibraryPage>(find.byType(LibraryPage))
                    .controller;
                await t.runAsync(() async {
                  final image = await t
                      .renderObject<RenderRepaintBoundary>(
                        key('content-fidelity-capture'),
                      )
                      .toImage(pixelRatio: 1);
                  final bytes = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  await File(
                    '$prefix.png',
                  ).writeAsBytes(bytes!.buffer.asUint8List());
                  image.dispose();
                  await File('$prefix.json').writeAsString(
                    jsonEncode({
                      'viewport': {
                        'width': size.width,
                        'height': size.height,
                        'dpr': 1,
                      },
                      'theme': dark ? 'dark' : 'light',
                      'textScale': scale,
                      'selection': model.selection!.key,
                      'query': model.query.keyword,
                      'scrollTop': scroll().pixels,
                      'scrollbarWidth':
                          t.getSize(key('library-detail-scroll')).width -
                          (RenderAbstractViewport.of(
                                    t.renderObject(key('library-detail-title')),
                                  )
                                  as RenderBox)
                              .size
                              .width,
                      'boxes': boxes,
                    }),
                  );
                });
              }

              await t.pumpWidget(
                const RepaintBoundary(
                  key: ValueKey('content-fidelity-capture'),
                  child: DesktopScrollbarScope(
                    style: bool.fromEnvironment('UI_OVERLAY_SCROLLBARS')
                        ? DesktopScrollbarStyle.overlay
                        : DesktopScrollbarStyle.legacy,
                    child: PreviewWorkspace(),
                  ),
                ),
              );
              await t.pumpAndSettle();
              if (dark) {
                await tap(key('preview-guide'));
                await tap(key('preview-theme-dark'));
              }
              await tap(key('library-directory-all'));
              await t.enterText(key('library-search'), '个人档案');
              await t.pumpAndSettle();
              await tap(key('library-record-information:profile'));
              final model = t
                  .widget<LibraryPage>(find.byType(LibraryPage))
                  .controller;
              Map<String, Object> profileBoxes() {
                final boxes = <String, Object>{
                  'detail-title': rect(key('library-detail-title')),
                };
                for (final field in ['name', 'email', 'direction', 'city']) {
                  for (final part in ['label', 'value']) {
                    boxes['field-$field-$part'] = rect(
                      key('library-field-$field-$part'),
                    );
                  }
                }
                for (final field in ['education', 'experience']) {
                  final timeline = key('library-timeline-$field');
                  expect(
                    t.widget<LibraryEntryTimeline>(timeline).value,
                    model.detail!.values[field],
                  );
                  final entries = WorkspaceRepeatedEntry.read(
                    model.detail!.values[field],
                  );
                  boxes['section-$field'] = rect(
                    find.text(field == 'education' ? '教育经历' : '工作经历'),
                  );
                  for (final (index, entry) in entries.indexed) {
                    final scope = find.descendant(
                      of: timeline,
                      matching: key('library-timeline-${entry.id}'),
                    );
                    boxes['$field-$index'] = rect(scope);
                    for (final part in ['period', 'title', 'detail', 'dot']) {
                      boxes['$field-$index-$part'] = rect(
                        find.descendant(
                          of: scope,
                          matching: key('library-timeline-${entry.id}-$part'),
                        ),
                      );
                    }
                  }
                }
                return boxes;
              }

              await capture('R05-top', profileBoxes());
              scroll().jumpTo(300);
              await t.pumpAndSettle();
              expect(scroll().pixels, 300);
              await capture('R05-timeline', profileBoxes());
              await tap(key('library-directory-all'));
              await t.enterText(key('library-search'), 'HTTPS');
              await t.pumpAndSettle();
              if (key('library-record-information:https').evaluate().isEmpty) {
                await t.scrollUntilVisible(
                  key('library-record-information:https'),
                  150,
                  scrollable: find
                      .descendant(
                        of: key('library-results-scroll'),
                        matching: find.byType(Scrollable),
                      )
                      .first,
                );
              }
              await tap(key('library-record-information:https'));
              Finder text(String value) => find.byWidgetPredicate(
                (w) =>
                    w is SelectableText &&
                    (w.data ?? w.textSpan?.toPlainText()) == value,
              );
              final headings = ['用途与适用范围', '访问入口', '维护步骤'];
              final boxes = <String, Object>{
                'detail-title': rect(key('library-detail-title')),
                'document': rect(key('library-document-body')),
              };
              for (var i = 0; i < headings.length; i++) {
                boxes['document-heading-$i'] = rect(text(headings[i]));
              }
              await capture('R06-document', boxes);
              await tap(key('library-document-raw'));
              expect(key('library-document-text'), findsOneWidget);
              expect(
                t.widget<SelectableText>(key('library-document-text')).data,
                model.detail!.values['body'],
              );
              await tap(key('library-document-raw'));
              expect(text(headings.first), findsOneWidget);
              expect(model.detail!.version, 1);
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
    'wide Markdown table keeps horizontal access and fitting table has no empty scroll lane',
    (t) async {
      t.view.physicalSize = const Size(400, 600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: LibraryDocument(
                format: 'markdown',
                body:
                    '| 第一列 | 第二列 | 第三列 |\n| --- | --- | --- |\n| 首项 | 中间项 | 末项 |',
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final horizontal = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      expect(horizontal, findsOneWidget);
      await t.drag(horizontal, const Offset(-180, 0));
      await t.pumpAndSettle();
      final position = t
          .state<ScrollableState>(
            find
                .descendant(of: horizontal, matching: find.byType(Scrollable))
                .first,
          )
          .position;
      expect(position.pixels, greaterThan(0));
      expect(position.extentAfter, lessThan(1));
      t.view.physicalSize = const Size(900, 600);
      await t.pumpAndSettle();
      expect(horizontal, findsNothing);
      expect(find.byType(Table), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('nested Markdown paragraphs keep their reading separation', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        theme: zhiyuTheme(Brightness.light),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: LibraryDocument(format: 'markdown', body: '> 引文甲\n>\n> 引文乙'),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    Finder text(String value) => find.byWidgetPredicate(
      (w) =>
          w is SelectableText && (w.data ?? w.textSpan?.toPlainText()) == value,
    );
    final first = t.getRect(text('引文甲'));
    final second = t.getRect(text('引文乙'));
    expect(second.top - first.bottom, greaterThanOrEqualTo(10));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'unavailable document snapshot retains raw fields without disconnected reading tools',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final source = SampleWorkspaceSource();
      final original = await source.readDetail(
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'https'),
      );
      final detail = WorkspaceDetail(
        record: original.record,
        version: original.version,
        templateState: WorkspaceTemplateState.disabled,
        definition: original.definition,
        values: original.values,
        relations: original.relations,
        fieldIds: original.fieldIds,
        fieldOverrides: original.fieldOverrides,
        retainedFields: original.retainedFields,
        retainedRelations: original.retainedRelations,
      );
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: LibraryDetail(
                detail: detail,
                source: source,
                metrics: const LibraryMetrics(1440),
                revision: 0,
                onOpen: (_) {},
                onEdit: () {},
                onSettings: () {},
                onTag: (_) {},
                onExpand: () {},
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(LibraryDocumentTools), findsNothing);
      expect(find.byType(LibraryDocument), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is SelectableText && w.data == original.values['body'],
        ),
        findsOneWidget,
      );
      expect(find.textContaining('模板插件已停用'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
