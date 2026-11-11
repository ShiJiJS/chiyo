import 'support/workspace_fixtures.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/ui_palette.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
void main() {
  setUpAll(() async {
    if (Platform.isMacOS || Platform.isWindows) await loadDesktopFonts();
  });
  Future<LibraryController> start(WidgetTester t, Size size, bool dark) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('fidelity-root'),
        child: PreviewWorkspace(inputsBuilder: fixtureInputs),
      ),
    );
    await t.pumpAndSettle();
    if (dark) {
      await fixtureTap(t, find.byKey(const ValueKey('preview-guide')));
      await t.pumpAndSettle();
      await fixtureTap(t, find.byKey(const ValueKey('preview-theme-dark')));
      await t.pumpAndSettle();
    }
    final model = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
    await model.select(azure);
    await t.pumpAndSettle();
    return model;
  }

  Finder row() =>
      find.byKey(const ValueKey('library-record-information:azure'));
  Finder inside(String text) =>
      find.descendant(of: row(), matching: find.text(text));
  for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'sidebar storage note and recycle stay reachable at $size dark=$dark scale=$scale',
          (t) async {
            t.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
            final model = await start(t, size, dark);
            final footer = find.byKey(const ValueKey('library-side-footer'));
            final recycle = find.byKey(const ValueKey('library-open-recycle'));
            final note = find.byKey(
              const ValueKey('library-local-storage-note'),
            );
            final rail = t.getRect(
              find.byKey(const ValueKey('library-directory-pane')),
            );
            final bounds = t.getRect(footer), text = t.getRect(note);
            expect(bounds.left, rail.left);
            expect(bounds.right, closeTo(rail.right - 1, 1));
            expect(bounds.bottom, size.height);
            expect(bounds.contains(text.topLeft), isTrue);
            expect(bounds.contains(text.bottomRight), isTrue);
            expect(text.top, greaterThan(t.getRect(recycle).bottom));
            expect(recycle.hitTestable(), findsOneWidget);
            expect(note.hitTestable(), findsOneWidget);
            expect(t.widget<Text>(note).maxLines, isNull);
            const output = String.fromEnvironment('UI_EVIDENCE_DIR');
            if (output.isNotEmpty && scale == 2) {
              final boundary = t.renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey('fidelity-root')),
              );
              await t.runAsync(() async {
                final frame = await boundary.toImage(pixelRatio: 1);
                final bytes = await frame.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  '$output/footer-${size.width.toInt()}-${dark ? 'dark' : 'light'}-200.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                frame.dispose();
              });
            }
            await t.tap(recycle);
            await t.pumpAndSettle();
            await t.tap(find.byKey(const ValueKey('library-recycle-back')));
            await t.pumpAndSettle();
            expect(model.selection, azure);
            expect(note, findsOneWidget);
            expect(t.takeException(), isNull);
          },
          skip: !Platform.isMacOS && !Platform.isWindows,
        );
      }
    }
  }
  for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
    for (final dark in [false, true]) {
      testWidgets(
        'CSS row box/labels and end-aligned 230px menu at ${size.width}, dark=$dark',
        (t) async {
          final model = await start(t, size, dark);
          // Approved native prototype uses a compact row with one summary line.
          // The reference capture must record its actual gutter and viewport;
          // this row/menu check is not a full-page fidelity claim.
          expect(t.getRect(row()).height, closeTo(126, 2));
          final palette = UiPalette.of(t.element(row()));
          final button = t.widget<TextButton>(
            find.descendant(of: row(), matching: find.byType(TextButton)),
          );
          final shape =
              button.style!.shape!.resolve({})! as RoundedRectangleBorder;
          expect(
            shape.borderRadius.resolve(TextDirection.ltr).topLeft,
            const Radius.circular(8),
          );
          expect(shape.side.color, palette.line);
          final tag = t.widget<Text>(inside('日本'));
          expect(tag.style!.fontSize, 12);
          expect(tag.style!.color, palette.muted);
          final tagContainer = find
              .ancestor(of: inside('日本'), matching: find.byType(Container))
              .first;
          expect(
            (t.widget<Container>(tagContainer).decoration! as BoxDecoration)
                .color,
            palette.paper,
          );
          final anchor = find.byKey(const ValueKey('library-type-filter'));
          final anchorRect = t.getRect(anchor);
          await t.tap(anchor);
          await t.pumpAndSettle();
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
          expect(popup, findsOneWidget);
          final bounds = t.getRect(popup);
          expect(bounds.width, closeTo(230, 2));
          expect(bounds.height, closeTo(332.75, 2));
          expect(bounds.right, closeTo(anchorRect.right, 2));
          final option = find.text('服务器信息').last;
          final mouse = await t.createGesture(kind: ui.PointerDeviceKind.mouse);
          addTearDown(mouse.removePointer);
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(t.getCenter(option));
          await t.pumpAndSettle();
          final hovered = find
              .ancestor(of: option, matching: find.byType(AnimatedContainer))
              .first;
          final surface = find
              .descendant(of: hovered, matching: find.byType(DecoratedBox))
              .first;
          expect(
            (t.widget<DecoratedBox>(surface).decoration as BoxDecoration).color,
            dark ? const Color(0xff393147) : const Color(0xffede8f5),
          );

          await t.sendKeyEvent(LogicalKeyboardKey.escape);
          await t.pumpAndSettle();
          expect(popup, findsNothing);
          expect(model.query.typeId, isNull);
          BorderSide borderOf(Finder control) {
            final button = t.widget<TextButton>(
              find.descendant(of: control, matching: find.byType(TextButton)),
            );
            return (button.style!.shape!.resolve({})! as RoundedRectangleBorder)
                .side;
          }

          final japan = model.detail!.record.tags.first;
          final detailTag = find.byKey(
            ValueKey('library-detail-tag-${japan.id}'),
          );
          final editTags = find.byKey(
            const ValueKey('library-detail-edit-tags'),
          );
          expect(
            t.getRect(detailTag).height,
            closeTo(t.getRect(editTags).height, .1),
          );
          expect(
            t.getRect(detailTag).top,
            closeTo(t.getRect(editTags).top, .1),
          );
          expect(t.getRect(detailTag).width, closeTo(40, 1));
          await t.tap(anchor);
          await t.pumpAndSettle();
          await t.tap(find.text('服务器信息').last);
          await t.pumpAndSettle();
          final tagFilter = find.byKey(const ValueKey('library-tag-filter'));
          await t.tap(tagFilter);
          await t.pumpAndSettle();
          await t.tap(find.text('生产环境').last);
          await t.pumpAndSettle();
          await t.enterText(find.byKey(const ValueKey('library-search')), '日本');
          await t.pumpAndSettle();
          expect(model.results!.total, 1);
          expect(borderOf(anchor).color, palette.accent);
          expect(borderOf(tagFilter).color, palette.accent);
          await t.tap(anchor);
          await t.pumpAndSettle();
          await t.tap(find.text('全部类型').last);
          await t.pumpAndSettle();
          await t.tap(tagFilter);
          await t.pumpAndSettle();
          await t.tap(find.text('全部标签').last);
          await t.pumpAndSettle();
          expect(model.query.typeId, isNull);
          expect(model.query.tagId, isNull);
          expect(model.query.keyword, '日本');
          expect(borderOf(anchor).color, palette.line);
          expect(borderOf(tagFilter).color, palette.line);
          await t.tap(detailTag);
          await t.pumpAndSettle();
          expect(model.query.tagId, japan.id);
          final sideTag = find.byKey(
            ValueKey('library-sidebar-tag-${japan.id}'),
          );
          expect(borderOf(sideTag).color, palette.accent);
          expect(t.getRect(sideTag).height, closeTo(26, 1));
          await t.tap(sideTag);
          await t.pumpAndSettle();
          expect(model.query.tagId, isNull);
          expect(t.takeException(), isNull);
        },
        skip: !Platform.isMacOS && !Platform.isWindows,
      );
    }
  }
  testWidgets(
    'long summary clamps to one visible line; empty purpose leaves CSS metadata gap',
    (t) async {
      final model = await start(t, const Size(1280, 800), false);
      final current = model.detail!;
      final description = List.filled(30, '维护用途与连接事实。').join();
      await model.source.saveRecord(
        WorkspaceEdit(
          operationId: 'long-purpose',
          expectedVersion: current.version,
          record: current.record.copyWith(description: description),
          values: {},
        ),
      );
      await t.pumpAndSettle();
      expect(t.getRect(inside(description)).height, inInclusiveRange(20, 24));
      final long = await model.source.readDetail(azure);
      await model.source.saveRecord(
        WorkspaceEdit(
          operationId: 'empty-purpose',
          expectedVersion: long.version,
          record: long.record.copyWith(description: ''),
          values: {},
        ),
      );
      await t.pumpAndSettle();
      final name = t.getRect(inside(current.record.name)),
          type = t.getRect(inside(current.record.type.name));
      expect(type.top - name.bottom, closeTo(8, 1));
      expect(t.takeException(), isNull);
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );
}
