import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/desktop_interaction_host.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    await Directory(evidence).create(recursive: true);
    await File(
      '$evidence/fonts.json',
    ).writeAsString(jsonEncode(await loadDesktopFonts()));
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final dark in [false, true]) {
    for (final large in [false, true]) {
      testWidgets(
        'Round09 ordinary selector uses the shared focus and anchored menu dark=$dark large=$large',
        (t) async {
          final shadows = debugDisableShadows;
          if (evidence.isNotEmpty) debugDisableShadows = false;
          try {
            t.view.physicalSize = large
                ? const Size(1280, 800)
                : const Size(1440, 900);
            t.view.devicePixelRatio = 1;
            t.platformDispatcher.textScaleFactorTestValue = large ? 2 : 1;
            addTearDown(t.view.resetPhysicalSize);
            addTearDown(t.view.resetDevicePixelRatio);
            addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
            var changes = 0;
            final boundary = GlobalKey();
            await t.pumpWidget(
              MaterialApp(
                theme: zhiyuTheme(dark ? Brightness.dark : Brightness.light),
                builder: (_, child) => RepaintBoundary(
                  key: boundary,
                  child: DesktopInteractionHost(child: child!),
                ),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: const EdgeInsets.all(30),
                      child: SizedBox(
                        width: 190,
                        child: DesktopSelect<int>(
                          value: 30,
                          items: const [
                            DropdownMenuItem(
                              value: 5,
                              enabled: false,
                              child: Text('5 分钟'),
                            ),
                            DropdownMenuItem(value: 15, child: Text('15 分钟')),
                            DropdownMenuItem(value: 30, child: Text('30 分钟')),
                          ],
                          onChanged: (_) => changes++,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await t.pumpAndSettle();
            Future<void> capture(String state) async {
              if (evidence.isEmpty) return;
              await t.runAsync(() async {
                final frame =
                    await (boundary.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary)
                        .toImage(pixelRatio: 1);
                final bytes = await frame.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '$evidence/select-${dark ? 'dark' : 'light'}-${large ? 200 : 100}-$state.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                frame.dispose();
              });
            }

            await t.sendKeyEvent(LogicalKeyboardKey.tab);
            await t.pumpAndSettle();
            await capture('focus');
            final trigger = t.getRect(find.byType(DesktopSelect<int>));
            // Use S5's existing 2px geometry target. Flutter paints the border
            // inside its hit area and rounds the text line to physical pixels.
            expect(trigger.height, closeTo(large ? 60.8 : 38.4, 2));
            await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await t.pumpAndSettle();
            final surface = find.byWidgetPredicate(
              (w) =>
                  w is Material &&
                  w.shape is RoundedRectangleBorder &&
                  w.clipBehavior == Clip.antiAlias,
            );
            final popup = t.getRect(surface);
            expect(
              popup.width,
              230,
              reason: 'Frozen positionMenu uses a 230px minimum.',
            );
            expect(popup.bottom, closeTo(trigger.top - 6, .01));
            expect(popup.right, closeTo(trigger.right, .01));
            await capture('open');
            await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await t.pumpAndSettle();
            await t.sendKeyEvent(LogicalKeyboardKey.enter);
            await t.pumpAndSettle();
            expect(
              changes,
              1,
              reason: 'Direction navigation skips the disabled option.',
            );
            final launcher = find.descendant(
              of: find.byType(DesktopSelect<int>),
              matching: find.byType(DesktopButton),
            );
            expect(
              launcher,
              findsOneWidget,
              reason:
                  'Round09 selectors share button focus, feedback and pointer modality.',
            );
            expect(
              t.widget<DesktopButton>(launcher).focusNode!.hasPrimaryFocus,
              isTrue,
            );
            await t.sendKeyEvent(LogicalKeyboardKey.enter);
            await t.pumpAndSettle();
            await t.sendKeyEvent(LogicalKeyboardKey.escape);
            await t.pumpAndSettle();
            expect(surface, findsNothing);
            expect(changes, 1);
            expect(t.takeException(), isNull);
          } finally {
            debugDisableShadows = shadows;
          }
        },
      );
    }
  }
}
