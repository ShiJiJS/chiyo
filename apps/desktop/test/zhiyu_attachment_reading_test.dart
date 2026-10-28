import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/prototype_icons.dart';
import 'package:info_desktop/desktop_scroll.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/library_file.dart';
import 'package:info_desktop/workspace/library_widgets.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_desktop/workspace/library_detail.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  const output = String.fromEnvironment('UI_ATTACHMENT_EVIDENCE_DIR');
  setUpAll(() async {
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
        testWidgets('attachment reading $size dark=$dark scale=$scale', (
          t,
        ) async {
          t.view.physicalSize = size;
          t.view.devicePixelRatio = 1;
          t.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
          Finder key(String k) => find.byKey(ValueKey(k));
          Future<void> tap(Finder f) async {
            await t.ensureVisible(f);
            await t.tap(f, kind: ui.PointerDeviceKind.mouse);
            await t.pumpAndSettle();
            expect(t.takeException(), isNull);
          }

          await t.pumpWidget(
            const RepaintBoundary(
              key: ValueKey('attachment-capture'),
              child: DesktopScrollbarScope(
                style: DesktopScrollbarStyle.overlay,
                child: PreviewWorkspace(),
              ),
            ),
          );
          await t.pumpAndSettle();
          if (dark) {
            await tap(key('preview-guide'));
            await tap(key('preview-theme-dark'));
          }
          final model = t
              .widget<LibraryPage>(find.byType(LibraryPage))
              .controller;
          Future<void> open(String query, String ref) async {
            await tap(key('library-directory-all'));
            await t.enterText(key('library-search'), query);
            await t.pumpAndSettle();
            if (key('library-record-$ref').evaluate().isEmpty) {
              await t.scrollUntilVisible(
                key('library-record-$ref'),
                150,
                scrollable: find
                    .descendant(
                      of: key('library-results-scroll'),
                      matching: find.byType(Scrollable),
                    )
                    .first,
              );
            }
            await tap(key('library-record-$ref'));
          }

          Map<String, double> rect(Finder f) {
            final r = t.getRect(f);
            return {
              'x': r.left,
              'y': r.top,
              'width': r.width,
              'height': r.height,
            };
          }

          Future<void> capture(String state, Map<String, Object> boxes) async {
            if (output.isEmpty) return;
            await t.runAsync(() async {
              final boundary = t.renderObject<RenderRepaintBoundary>(
                key('attachment-capture'),
              );
              final im = await boundary.toImage(pixelRatio: 1);
              final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
              final prefix =
                  '$output/${dark ? 'dark' : 'light'}-${size.width.toInt()}-${(scale * 100).toInt()}-$state';
              await File(
                '$prefix.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              im.dispose();
              final scroll = t
                  .state<ScrollableState>(
                    find
                        .descendant(
                          of: key('library-detail-scroll'),
                          matching: find.byType(Scrollable),
                        )
                        .first,
                  )
                  .position;
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
                  'scrollTop': scroll.pixels,
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

          await open('服务端开发简历', 'information:resume');
          for (
            var frame = 0;
            frame < 40 &&
                find
                    .byWidgetPredicate((w) => w is RawImage && w.image != null)
                    .evaluate()
                    .isEmpty;
            frame++
          ) {
            await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await t.pump();
          }
          expect(
            find.byWidgetPredicate((w) => w is RawImage && w.image != null),
            findsOneWidget,
          );
          final detail = find.byType(LibraryDetail);
          expect(
            find.descendant(of: detail, matching: find.text('概览')),
            findsNothing,
          );
          expect(key('library-file-stage'), findsOneWidget);
          final source = model.source as SampleWorkspaceSource;
          const resume = WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            'resume',
          );
          final metadata = await source.loadFileHistory(resume, 'file');
          expect(find.text(metadata.current.filename), findsOneWidget);
          await capture('resume', {
            'detail-title': rect(key('library-detail-title')),
            'file-stage': rect(key('library-file-stage')),
          });
          final image = find.descendant(
            of: key('library-file-stage'),
            matching: find.byType(Image),
          );
          final width = t.getSize(image).width;
          final horizontal = find.descendant(
            of: find.byType(LibraryFilePreviewView),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is SingleChildScrollView &&
                  w.scrollDirection == Axis.horizontal,
            ),
          );
          expect(horizontal, findsNothing);
          await tap(key('library-file-zoom-in'));
          expect(t.getSize(image).width, closeTo(width * 1.5, .001));
          expect(horizontal, findsOneWidget);
          await tap(key('library-file-zoom-out'));
          expect(horizontal, findsNothing);
          expect(
            (await source.loadFileHistory(resume, 'file')).current.ref,
            metadata.current.ref,
          );
          await open('Azure SSH', 'credential:sshkey');
          expect(
            find.descendant(of: detail, matching: find.text('概览')),
            findsNothing,
          );
          expect(key('credential-mask'), findsOneWidget);
          final boxes = <String, Object>{
            'detail-title': rect(key('library-detail-title')),
          };
          for (final k in [
            'credential-summary',
            'credential-summary-format',
            'credential-status',
          ]) {
            boxes[k == 'credential-summary-format' ? 'credential-format' : k] =
                rect(key(k));
          }
          final icon = find
              .descendant(
                of: key('credential-summary'),
                matching: find.byType(PrototypeIcon),
              )
              .first;
          boxes['credential-icon'] = rect(icon);
          await capture('sshkey', boxes);
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
          await t.pumpAndSettle();
        });
      }
    }
  }
  for (final disabled in [false, true]) {
    testWidgets(
      'file template fallback retains extra fields disabled=$disabled',
      (t) async {
        final source = SampleWorkspaceSource();
        addTearDown(source.dispose);
        final original = await source.readDetail(
          const WorkspaceRecordRef(WorkspaceRecordKind.information, 'resume'),
        );
        final definition = disabled
            ? original.definition
            : {
                ...original.definition,
                'fields': [
                  ...original.definition['fields'] as List,
                  {
                    'key': 'annotation',
                    'label': 'Additional note',
                    'type': 'text',
                  },
                ],
                'sections': [
                  ...original.definition['sections'] as List,
                  {
                    'kind': 'fields',
                    'title': 'Additional data',
                    'keys': ['annotation'],
                  },
                ],
              };
        final detail = WorkspaceDetail(
          record: original.record,
          version: original.version,
          templateState: disabled
              ? WorkspaceTemplateState.disabled
              : WorkspaceTemplateState.available,
          definition: definition,
          values: {
            ...original.values,
            'annotation': 'Extra content remains readable',
          },
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
        expect(find.text('概览'), findsOneWidget);
        expect(find.text('Extra content remains readable'), findsOneWidget);
        if (disabled) {
          expect(
            find.byKey(const ValueKey('library-template-unavailable')),
            findsOneWidget,
          );
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();
      },
    );
  }
}
