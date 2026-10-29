import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_button.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/ui_palette.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    final fonts = await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await Directory(evidence).create(recursive: true);
    await File('$evidence/fonts.json').writeAsString(jsonEncode(fonts));
  });
  for (final brightness in Brightness.values) {
    for (final kind in [
      DesktopButtonKind.outline,
      DesktopButtonKind.primary,
      DesktopButtonKind.quiet,
      DesktopButtonKind.menu,
    ]) {
      testWidgets(
        '${brightness.name} ${kind.name} keyboard focus preserves the border and follows the external CSS outline',
        (t) async {
          t.view.physicalSize = const Size(320, 200);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          final strategy = FocusManager.instance.highlightStrategy;
          addTearDown(() => FocusManager.instance.highlightStrategy = strategy);
          FocusManager.instance.highlightStrategy =
              FocusHighlightStrategy.alwaysTraditional;
          final focus = FocusNode();
          addTearDown(focus.dispose);
          final boundary = GlobalKey();
          await t.pumpWidget(
            MaterialApp(
              theme: zhiyuTheme(brightness),
              home: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 160,
                      height: 48,
                      child: DesktopButton(
                        kind: kind,
                        focusNode: focus,
                        onPressed: () {},
                        child: const Text('操作'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          final button = find.byType(DesktopButton);
          final rect = t.getRect(button);
          final colors = UiPalette.of(t.element(button));
          Future<List<Color>> pixels(String name) async {
            return (await t.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage(pixelRatio: 1);
              try {
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                );
                if (evidence.isNotEmpty) {
                  final png = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  await Directory(evidence).create(recursive: true);
                  await File(
                    '$evidence/${brightness.name}-${kind.name}-$name.png',
                  ).writeAsBytes(png!.buffer.asUint8List());
                }
                return [-4, -2, 0].map((dy) {
                  final offset =
                      ((rect.top.toInt() + dy) * image.width +
                          rect.center.dx.toInt()) *
                      4;
                  final b = bytes!.buffer.asUint8List();
                  return Color.fromARGB(
                    b[offset + 3],
                    b[offset],
                    b[offset + 1],
                    b[offset + 2],
                  );
                }).toList();
              } finally {
                image.dispose();
              }
            }))!;
          }

          final normal = await pixels('normal');
          expect(normal.first, colors.canvas);
          focus.requestFocus();
          await t.pumpAndSettle();
          final focused = await pixels('focused');
          expect(
            t.getRect(button),
            rect,
            reason: 'Focus must not resize the hit area.',
          );
          expect(
            focused[1],
            colors.canvas,
            reason: 'The 3px CSS outline gap must stay transparent.',
          );
          if (kind == DesktopButtonKind.menu) {
            expect(
              focused[0],
              colors.canvas,
              reason: 'Floating-menu focus explicitly has outline:none.',
            );
            expect(focused[2], colors.selected);
          } else {
            expect(
              focused[0],
              colors.accent,
              reason:
                  'The 2px outline belongs outside the button, after a 3px gap.',
            );
            expect(
              focused[2],
              normal[2],
              reason: 'Keyboard focus must not replace the original border.',
            );
          }
          FocusManager.instance.highlightStrategy =
              FocusHighlightStrategy.alwaysTouch;
          await t.pumpAndSettle();
          expect((await pixels('non-keyboard')).first, colors.canvas);
          expect(
            focus.hasFocus,
            true,
            reason: 'Changing highlight mode does not move focus.',
          );
        },
      );
    }
  }

  for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'selected navigation keyboard outline stays visible at $size dark=$dark scale=$scale',
          (t) async {
            t.view.physicalSize = size;
            t.view.devicePixelRatio = 1;
            t.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(t.view.resetPhysicalSize);
            addTearDown(t.view.resetDevicePixelRatio);
            addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
            final strategy = FocusManager.instance.highlightStrategy;
            addTearDown(
              () => FocusManager.instance.highlightStrategy = strategy,
            );
            FocusManager.instance.highlightStrategy =
                FocusHighlightStrategy.alwaysTraditional;
            final boundary = GlobalKey();
            await t.pumpWidget(
              RepaintBoundary(key: boundary, child: const PreviewWorkspace()),
            );
            await t.pumpAndSettle();
            if (dark) {
              await t.tap(find.byKey(const ValueKey('preview-guide')));
              await t.pumpAndSettle();
              await t.tap(find.byKey(const ValueKey('preview-theme-dark')));
              await t.pumpAndSettle();
            }
            final nav = find.byKey(const ValueKey('workspace-nav-library'));
            final rect = t.getRect(nav);
            final color = UiPalette.of(t.element(nav)).accent;
            Focus.of(
              t.element(find.descendant(of: nav, matching: find.text('信息库'))),
            ).requestFocus();
            await t.pumpAndSettle();
            expect(t.getRect(nav), rect);
            final pixel = await t.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage(pixelRatio: 1);
              try {
                final data = (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!.buffer.asUint8List();
                final offset =
                    ((rect.top.toInt() - 4) * image.width +
                        rect.center.dx.toInt()) *
                    4;
                if (evidence.isNotEmpty) {
                  final png = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  await File(
                    '$evidence/nav-${size.width.toInt()}-${dark ? 'dark' : 'light'}-${scale.toInt()}.png',
                  ).writeAsBytes(png!.buffer.asUint8List());
                }
                return Color.fromARGB(
                  data[offset + 3],
                  data[offset],
                  data[offset + 1],
                  data[offset + 2],
                );
              } finally {
                image.dispose();
              }
            });
            expect(
              pixel,
              color,
              reason:
                  'Selection must not hide the keyboard outline in the actual shell.',
            );
          },
        );
      }
    }
  }

  testWidgets(
    'disabling the focused action removes its outline and keeps the legacy border behavior',
    (t) async {
      final strategy = FocusManager.instance.highlightStrategy;
      addTearDown(() => FocusManager.instance.highlightStrategy = strategy);
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var calls = 0;
      Widget scene(bool enabled, bool round09) => MaterialApp(
        theme: round09 ? zhiyuTheme(Brightness.light) : ThemeData(),
        home: Scaffold(
          body: Center(
            child: DesktopButton(
              focusNode: focus,
              onPressed: enabled ? () => calls++ : null,
              child: const Text('动作'),
            ),
          ),
        ),
      );
      await t.pumpWidget(scene(true, true));
      await t.pumpAndSettle();
      focus.requestFocus();
      await t.pumpAndSettle();
      await t.pumpWidget(scene(false, true));
      await t.pumpAndSettle();
      expect(focus.hasFocus, false);
      await t.tap(find.text('动作'));
      expect(calls, 0);
      await t.pumpWidget(scene(true, false));
      await t.pumpAndSettle();
      focus.requestFocus();
      await t.pumpAndSettle();
      final material = t.widget<TextButton>(find.byType(TextButton));
      final shape =
          material.style!.shape!.resolve({WidgetState.focused})!
              as RoundedRectangleBorder;
      expect(
        shape.side.width,
        2,
        reason: 'Round09 outline geometry must not replace legacy styling.',
      );
    },
  );
}
