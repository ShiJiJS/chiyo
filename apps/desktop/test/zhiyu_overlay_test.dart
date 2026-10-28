import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

class _Stripes extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    for (var x = 0.0; x < size.width; x += 4) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 2, size.height),
        Paint()..color = Colors.black,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _Stripes oldDelegate) => false;
}

void main() {
  const capture = ValueKey('overlay-capture');
  const content = ValueKey('overlay-sharp-content');
  const output = String.fromEnvironment('UI_MOTION_EVIDENCE_DIR');
  final measurements = <String, Object>{};
  tearDownAll(() async {
    if (output.isEmpty) return;
    final file = File('$output/overlay-render.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'scope':
            'Actual Flutter rendering with deterministic Widget clock; not native OS input or normal-speed video',
        'measurements': measurements,
      }),
    );
  });
  Future<int> contrast(WidgetTester t, Rect region) async {
    return (await t.runAsync(() async {
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byKey(capture),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      var low = 255, high = 0;
      for (var x = region.left.toInt(); x < region.right; x++) {
        final red = data!.getUint8((region.top.toInt() * image.width + x) * 4);
        if (red < low) low = red;
        if (red > high) high = red;
      }
      image.dispose();
      return high - low;
    }))!;
  }

  for (final dark in [false, true]) {
    for (final reduced in [false, true]) {
      testWidgets(
        'barrier blurs background, keeps popup sharp, closes immediately dark=$dark reduced=$reduced',
        (t) async {
          t.view.physicalSize = const Size(400, 300);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          final focus = FocusNode();
          addTearDown(focus.dispose);
          var completed = 0;
          await t.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                theme: zhiyuTheme(dark ? Brightness.dark : Brightness.light),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: reduced),
                  child: child!,
                ),
                home: Scaffold(
                  body: Stack(
                    children: [
                      Positioned.fill(child: CustomPaint(painter: _Stripes())),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Builder(
                          builder: (context) => DesktopButton(
                            focusNode: focus,
                            onPressed: () async {
                              await showDesktopDialog<void>(
                                context,
                                builder: (_) => Focus(
                                  autofocus: true,
                                  child: Center(
                                    child: SizedBox(
                                      width: 120,
                                      height: 100,
                                      child: CustomPaint(
                                        key: content,
                                        painter: _Stripes(),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                              completed++;
                            },
                            child: const Text('打开'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          const background = Rect.fromLTWH(20, 20, 64, 1);
          const foreground = Rect.fromLTWH(160, 150, 64, 1);
          final original = await contrast(t, background);
          expect(original, 255);
          focus.requestFocus();
          await t.pumpAndSettle();
          await t.sendKeyEvent(LogicalKeyboardKey.enter);
          await t.pumpAndSettle();
          final blurred = await contrast(t, background);
          final sharp = await contrast(t, foreground);
          // A tint without blur keeps roughly 170/112 levels of contrast in the
          // two themes. Two-pixel Gaussian blur removes these 2px stripe edges.
          expect(blurred, lessThan(20));
          expect(sharp, greaterThan(240));
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
          await t.pump();
          await t.pump();
          expect(find.byKey(content), findsNothing);
          expect(completed, 1);
          expect(focus.hasPrimaryFocus, isTrue);
          expect(await contrast(t, background), original);
          // Closing during entrance must dispose both route and barrier too.
          await t.sendKeyEvent(LogicalKeyboardKey.enter);
          await t.pump();
          await t.pump(const Duration(milliseconds: 30));
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
          await t.pump();
          await t.pump();
          expect(find.byKey(content), findsNothing);
          expect(completed, 2);
          expect(focus.hasPrimaryFocus, isTrue);
          expect(await contrast(t, background), original);
          measurements['dark=$dark reduced=$reduced'] = {
            'unfilteredContrast': original,
            'filteredBackgroundContrast': blurred,
            'sharpPopupContrast': sharp,
            'closeFrameBudgetMs': 0,
            'rapidCloseMs': 30,
            'focusRestored': true,
          };
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'disabled close and PopScope retain modal; re-enabled close releases it',
    (t) async {
      final ready = ValueNotifier(false);
      addTearDown(ready.dispose);
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => DesktopButton(
                onPressed: () => showDesktopDialog<void>(
                  context,
                  builder: (_) => ValueListenableBuilder<bool>(
                    valueListenable: ready,
                    builder: (_, canClose, _) => PopScope(
                      canPop: canClose,
                      child: DesktopDialog(
                        closeEnabled: canClose,
                        title: const Text('提交结果待核对'),
                        content: const Text('保留当前操作'),
                      ),
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      final close = find.byKey(const ValueKey('desktop-dialog-close'));
      expect(t.getSize(close), const Size(36, 36));
      await t.tap(close);
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('保留当前操作'), findsOneWidget);
      ready.value = true;
      await t.pumpAndSettle();
      await t.tap(close);
      await t.pump();
      await t.pump();
      expect(find.byType(DesktopDialog), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'nested confirmation removes only its own barrier and returns to outer form',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => DesktopButton(
                onPressed: () => showDesktopDialog<void>(
                  context,
                  builder: (outer) => DesktopDialog(
                    title: const Text('原表单'),
                    content: DesktopButton(
                      onPressed: () => showDesktopDialog<void>(
                        outer,
                        builder: (_) => const DesktopDialog(
                          title: Text('确认'),
                          content: Text('合成确认'),
                        ),
                      ),
                      child: const Text('核对'),
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      await t.tap(find.text('核对'));
      await t.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNWidgets(2));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump();
      expect(find.text('合成确认'), findsNothing);
      expect(find.text('原表单'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump();
      expect(find.byType(DesktopDialog), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
