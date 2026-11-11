import 'support/workspace_fixtures.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/ui_palette.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const _azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
const _blinko = WorkspaceRecordRef(WorkspaceRecordKind.information, 'blinko');

void main() {
  const output = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (!Platform.isMacOS && !Platform.isWindows) return;
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
        testWidgets('library R02–R04 $size dark=$dark scale=$scale', (t) async {
          t.view.physicalSize = size;
          t.view.devicePixelRatio = 1;
          t.platformDispatcher.textScaleFactorTestValue = scale;
          final originalShadows = debugDisableShadows;
          debugDisableShadows = false;
          try {
            addTearDown(t.view.resetPhysicalSize);
            addTearDown(t.view.resetDevicePixelRatio);
            addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
            Finder key(String value) => find.byKey(ValueKey(value));
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

            Future<void> choose(String control, String label) async {
              await tap(key(control));
              await tap(find.text(label).last);
            }

            await t.pumpWidget(
              const RepaintBoundary(
                key: ValueKey('library-workflow-capture'),
                child: PreviewWorkspace(inputsBuilder: fixtureInputs),
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
            final palette = UiPalette.of(
              t.element(key('library-search-frame')),
            );
            BoxDecoration frame() =>
                t.widget<Container>(key('library-search-frame')).decoration!
                    as BoxDecoration;
            Color frameColor() => (frame().border! as Border).top.color;
            final prefix =
                '$output/${dark ? 'dark' : 'light'}-${size.width.toInt()}-${(scale * 100).toInt()}';
            Map<String, double> box(Finder target) {
              final r = t.getRect(target);
              return {
                'x': r.left,
                'y': r.top,
                'width': r.width,
                'height': r.height,
              };
            }

            Future<void> capture(String state) async {
              if (output.isEmpty) return;
              final boxes = <String, Object>{};
              for (final name in [
                'library-search-frame',
                'library-group',
                'library-sort',
                'library-results-pane',
                'library-results-footer',
                'library-detail-toolbar',
                'library-detail-create',
                'library-clear-filters',
                'library-detail-title',
                'library-back',
                'library-host-identity',
                'library-field-url-label',
                'library-field-url-value',
                'library-field-purpose-label',
                'library-field-purpose-value',
                'library-field-auth-label',
                'library-field-auth-value',
                'library-relation-frame-information:https',
                'library-relation-frame-information:sshguide',
                'library-relation-frame-credential:sshkey',
              ]) {
                final target = key(name);
                if (target.evaluate().length == 1) boxes[name] = box(target);
              }
              for (final name in [
                'library-results-empty',
                'library-detail-empty',
              ]) {
                final target = key(name);
                if (target.evaluate().length != 1) continue;
                boxes[name] = box(target);
                for (final part in ['title', 'description']) {
                  boxes['$name-$part'] = box(
                    find.descendant(
                      of: target,
                      matching: key('library-empty-$part'),
                    ),
                  );
                }
              }
              final groups = <Object>[];
              for (final group
                  in model.results?.groupCounts.keys ?? <String>[]) {
                final label = key('library-group-label-$group');
                final count = key('library-group-count-$group');
                if (label.evaluate().length != 1 ||
                    count.evaluate().length != 1) {
                  continue;
                }
                groups.add({
                  'key': group,
                  'label': t.widget<Text>(label).data,
                  'count': t.widget<Text>(count).data,
                  'labelBox': box(label),
                  'countBox': box(count),
                });
              }
              final popup = find.byWidgetPredicate(
                (w) =>
                    w is Material &&
                    w.clipBehavior == Clip.antiAlias &&
                    w.shape is RoundedRectangleBorder &&
                    (w.shape! as RoundedRectangleBorder).borderRadius
                            .resolve(TextDirection.ltr)
                            .topLeft ==
                        const Radius.circular(8),
              );
              expect(popup.evaluate().length, lessThanOrEqualTo(1));
              if (popup.evaluate().isNotEmpty) boxes['popup'] = box(popup);
              final metadata = {
                'state': state,
                'viewport': {
                  'width': size.width,
                  'height': size.height,
                  'dpr': 1,
                },
                'theme': dark ? 'dark' : 'light',
                'textScale': scale,
                'query': {
                  'directory': model.query.directoryId,
                  'keyword': model.query.keyword,
                  'type': model.query.typeId,
                  'tag': model.query.tagId,
                  'tagName': model.catalog?.tags
                      .where((tag) => tag.id == model.query.tagId)
                      .firstOrNull
                      ?.name,
                  'grouping': model.query.grouping.name,
                  'sort': model.query.sort.name,
                  'offset': model.query.offset,
                  'limit': model.query.limit,
                },
                'groupCounts': model.results?.groupCounts,
                'groupLabels': {
                  for (final record
                      in model.results?.items ?? <WorkspaceRecordSummary>[])
                    record.type.id: record.type.name,
                },
                if (state == 'R03-type-menu')
                  'popupLabels': t
                      .widget<DesktopSelect<String?>>(
                        key('library-type-filter'),
                      )
                      .items
                      .map((item) => (item.child as Text).data)
                      .toList(),
                'groups': groups,
                'total': model.results?.total,
                'selection': model.selection?.key,
                'order': model.results?.items.map((r) => r.ref.key).toList(),
                'canGoBack': model.canGoBack,
                'scrollOffset': model.scrollOffset,
                'searchFocused': key('library-search').evaluate().isNotEmpty
                    ? t
                          .widget<TextField>(key('library-search'))
                          .focusNode!
                          .hasFocus
                    : null,
                'boxes': boxes,
                'scope':
                    'Actual synthetic Widget flow, mouse-kind/keyboard injection; not OS input',
              };
              await t.runAsync(() async {
                final boundary = t.renderObject<RenderRepaintBoundary>(
                  key('library-workflow-capture'),
                );
                final image = await boundary.toImage(pixelRatio: 1);
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '$prefix-$state.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
                await File('$prefix-$state.json').writeAsString(
                  const JsonEncoder.withIndent('  ').convert(metadata),
                );
              });
            }

            expect(frameColor(), palette.line);
            await tap(key('library-directory-all'));
            await choose('library-type-filter', '服务器信息');
            await choose('library-tag-filter', '生产环境');
            await t.enterText(key('library-search'), '日本');
            await t.pumpAndSettle();
            expect(model.results!.total, 1);
            expect(model.selection, _azure);
            expect(frameColor(), palette.accent);
            expect(frame().boxShadow!.single.spreadRadius, 2);
            expect(frame().boxShadow!.single.color, palette.selected);
            await capture('R02-hit-focus');
            await t.sendKeyEvent(LogicalKeyboardKey.tab);
            await t.pumpAndSettle();
            expect(frameColor(), palette.line);
            expect(model.query.keyword, '日本');
            await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
            await t.sendKeyEvent(LogicalKeyboardKey.tab);
            await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
            await t.pumpAndSettle();
            expect(frameColor(), palette.accent);
            await t.enterText(key('library-search'), '没有匹配的测试词');
            await t.pumpAndSettle();
            expect(model.results!.total, 0);
            expect(model.selection, isNull);
            expect(key('library-detail-title'), findsNothing);
            expect(key('library-results-empty'), findsOneWidget);
            expect(key('library-detail-empty'), findsOneWidget);
            await capture('R02-empty');
            await tap(key('library-clear-filters'));
            expect(model.query.keyword, '');
            expect(model.query.typeId, isNull);
            expect(model.query.tagId, isNull);
            expect(model.query.directoryId, isNull);
            expect(model.results!.total, 31);
            expect(frameColor(), palette.line);
            if (scale == 2) {
              expect(t.takeException(), isNull);
              await t.pumpWidget(const SizedBox());
              return;
            }
            await tap(key('library-record-information:azure'));
            await capture('R02-cleared');
            await tap(key('library-type-filter'));
            await capture('R03-type-menu');
            await tap(find.text('全部类型').last);
            await tap(key('library-group'));
            await capture('R03-group-menu');
            await tap(find.text('按类型').last);
            expect(model.query.grouping, WorkspaceGrouping.type);
            expect(model.results!.total, 31);
            await capture('R03-grouped');
            await tap(key('library-sort'));
            await capture('R03-sort-menu');
            await tap(find.text('按名称').last);
            expect(model.query.sort, WorkspaceSort.name);
            expect(model.results!.total, 31);
            await capture('R03-name');
            await choose('library-group', '不分组');
            await capture('R03-name-ungrouped');
            await choose('library-sort', '最近更新优先');
            await tap(key('library-directory-selfhost'));
            await tap(key('library-record-information:azure'));
            await t.drag(key('library-results-scroll'), const Offset(0, -120));
            await t.pumpAndSettle();
            final originScroll = model.scrollOffset;
            expect(originScroll, greaterThan(0));
            await tap(find.text('关联资料').first);
            await capture('R04-relations');
            await tap(key('library-relation-information:blinko'));
            expect(model.selection, _blinko);
            expect(model.canGoBack, isTrue);
            await capture('R04-service');
            await tap(key('library-back'));
            expect(model.selection, _azure);
            expect(model.query.directoryId, 'selfhost');
            expect(model.scrollOffset, closeTo(originScroll, 1));
            await capture('R04-return');
            await tap(key('library-host-identity'));
            expect(find.byType(DesktopDialog), findsOneWidget);
            expect(find.text('tokyo.beichen.example:2222'), findsWidgets);
            await capture('R04-host');
            await tap(key('host-close'));
            await tap(key('workspace-nav-library'));
            expect(model.selection, _azure);
            expect(model.query.directoryId, 'selfhost');
            expect(model.canGoBack, isFalse);
            await capture('R04-host-return');
            expect(t.takeException(), isNull);
            await t.pumpWidget(const SizedBox());
          } finally {
            debugDisableShadows = originalShadows;
          }
        }, skip: !Platform.isMacOS && !Platform.isWindows);
      }
    }
  }
}
