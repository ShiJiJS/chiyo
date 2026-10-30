import 'support/workspace_fixtures.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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
                if (await prepareFixtureAction(t, target)) return;
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
                    child: PreviewWorkspace(inputsBuilder: fixtureInputs),
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
              boxes['document-paragraph-0'] = rect(
                key('library-document-block-1'),
              );
              boxes['document-paragraph-1'] = rect(
                key('library-document-block-7'),
              );
              boxes['document-table'] = rect(key('library-document-block-3'));
              final table = t.widget<Table>(
                find.descendant(
                  of: key('library-document-block-3'),
                  matching: find.byType(Table),
                ),
              );
              for (var r = 0; r < table.children.length; r++) {
                for (var c = 0; c < table.children[r].children.length; c++) {
                  boxes['document-table-cell-$r-$c'] = rect(
                    find.byWidget(table.children[r].children[c]),
                  );
                }
              }
              boxes['document-code'] = rect(key('library-document-block-6'));
              boxes['document-list'] = rect(key('library-document-block-5'));
              final items = find.descendant(
                of: key('library-document-block-5'),
                matching: find.byType(Expanded),
              );
              expect(items, findsNWidgets(3));
              for (var i = 0; i < 3; i++) {
                boxes['document-list-item-$i'] = rect(items.at(i));
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
                    '| 第一列 | 第二列 | 第三列 |\n| --- | --- | --- |\n| firstcolumnunbreakablevalue | middlecolumnunbreakablevalue | lastcolumnunbreakablevalue |',
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
      await t.drag(horizontal, const Offset(-700, 0));
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
    'fractional multiline leading keeps full-size selectable text and complete copying',
    (t) async {
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        if (call.method == 'Clipboard.getData') return {'text': copied};
        if (call.method == 'Clipboard.hasStrings') {
          return {'value': copied?.isNotEmpty ?? false};
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: const Scaffold(
            body: SizedBox(
              width: 500,
              child: LibraryDocument(
                format: 'markdown',
                body: 'alpha  \nbeta\n\nfinal',
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final block = find.byKey(const ValueKey('library-document-block-0'));
      final next = find.byKey(const ValueKey('library-document-block-1'));
      expect(t.getSize(block).height, closeTo(54.6, .001));
      expect(
        t.getTopLeft(next).dy - t.getBottomLeft(block).dy,
        closeTo(10, .001),
      );
      final text = find.descendant(
        of: block,
        matching: find.byType(SelectableText),
      );
      expect(t.widget<SelectableText>(text).style!.fontSize, 14);
      await t.tap(text);
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyA);
      await t.sendKeyEvent(LogicalKeyboardKey.keyC);
      await t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await t.pump();
      expect(copied, 'alpha\nbeta');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
  testWidgets(
    'wrapped table cells share a row and wide code remains horizontally readable',
    (t) async {
      final code = '${List.filled(12, 'long_code_value').join('_')}_END';
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 240,
                child: LibraryDocument(
                  format: 'markdown',
                  body:
                      '| Left | Right |\n| --- | --- |\n| Several words wrapping over multiple lines inside this cell | Short |\n\n```\n$code\n```',
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final table = t.widget<Table>(find.byType(Table));
      final left = t.getRect(find.byWidget(table.children[1].children[0]));
      final right = t.getRect(find.byWidget(table.children[1].children[1]));
      expect(left.height, greaterThan(50));
      expect(left.height, right.height);
      expect(left.bottom, right.bottom);
      final horizontal = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      expect(horizontal, findsOneWidget);
      await t.ensureVisible(horizontal);
      await t.sendEventToBinding(
        PointerScrollEvent(
          position: t.getCenter(horizontal),
          scrollDelta: const Offset(3000, 0),
          kind: ui.PointerDeviceKind.mouse,
        ),
      );
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
      final text = find.descendant(
        of: horizontal,
        matching: find.byType(SelectableText),
      );
      expect(t.widget<SelectableText>(text).textSpan!.toPlainText(), code);
      expect(t.widget<SelectableText>(text).style!.fontSize, 13);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
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
