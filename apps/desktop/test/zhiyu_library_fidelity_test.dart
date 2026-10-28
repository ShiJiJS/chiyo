import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
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
    if (Platform.isMacOS) await loadDesktopFonts();
  });
  Future<LibraryController> start(WidgetTester t, Size size, bool dark) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(const PreviewWorkspace());
    await t.pumpAndSettle();
    if (dark) {
      await t.tap(find.byKey(const ValueKey('preview-guide')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('preview-theme-dark')));
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
      testWidgets(
        'CSS row box/labels and end-aligned 230px menu at ${size.width}, dark=$dark',
        (t) async {
          final model = await start(t, size, dark);
          // Measured 11px-gutter reference: 155.78125px, two summary lines.
          // The reference capture must record its actual gutter and viewport;
          // this row/menu check is not a full-page fidelity claim.
          expect(t.getRect(row()).height, closeTo(155.78125, 2));
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
          expect(t.takeException(), isNull);
        },
        skip: !Platform.isMacOS,
      );
    }
  }
  testWidgets(
    'long summary clamps to two visible lines; empty purpose leaves CSS metadata gap',
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
      expect(t.getRect(inside(description)).height, inInclusiveRange(40, 46));
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
    skip: !Platform.isMacOS,
  );
}
