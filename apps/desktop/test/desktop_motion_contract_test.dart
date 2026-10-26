import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/anchored_surface.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_feedback.dart';
import 'package:info_desktop/desktop_motion.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

/// Expected times/displacements come from S5, not from implementation constants.
/// Samples inspect laid-out/rendered widgets on every 10ms test frame. Native
/// wall-clock rendering is recorded separately by the integration check.
void main() {
  final evidence = <String, Object>{};
  tearDownAll(() async {
    const directory = String.fromEnvironment('UI_MOTION_EVIDENCE_DIR');
    if (directory.isNotEmpty) {
      final file = File('$directory/motion-contract.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'scope':
              'real Flutter render properties; deterministic 10ms frame clock',
          'nativeWallClock': false,
          'measurements': evidence,
        }),
      );
    }
  });

  Widget app(Widget child) => MaterialApp(
    theme: zhiyuTheme(Brightness.light),
    builder: (_, child) => DesktopFeedback(child: child!),
    home: Scaffold(body: Center(child: child)),
  );

  double opacity(Finder target) {
    var value = 1.0;
    target.evaluate().single.visitAncestorElements((e) {
      if (e.widget case Opacity(:final opacity)) value *= opacity;
      if (e.widget case FadeTransition(:final opacity)) value *= opacity.value;
      return true;
    });
    return value;
  }

  Future<void> observe(
    WidgetTester tester,
    Finder target,
    String name, {
    required int milliseconds,
    required double initialY,
  }) async {
    final samples = <Map<String, Object>>[];
    for (var time = 0; time <= milliseconds + 20; time += 10) {
      if (time != 0) await tester.pump(const Duration(milliseconds: 10));
      samples.add({
        'ms': time,
        'opacity': opacity(target),
        'y': tester.getTopLeft(target).dy,
      });
    }
    final finalY = samples.last['y']! as double;
    expect((samples.first['y']! as double) - finalY, closeTo(initialY, .05));
    expect(samples.first['opacity'], closeTo(0, .00001));
    final complete = samples.indexWhere(
      (s) => (s['opacity']! as double) >= 1 - .000001,
    );
    expect(complete, greaterThan(0));
    expect(
      samples[complete]['ms'],
      inInclusiveRange(milliseconds - 10, milliseconds + 10),
    );
    for (final sample in samples) {
      final time = sample['ms']! as int;
      final fraction = (time / milliseconds).clamp(0.0, 1.0);
      final expected = Curves.easeOut.transform(fraction);
      expect(sample['opacity'], closeTo(expected, .0001));
      expect(
        (sample['y']! as double) - finalY,
        closeTo(initialY * (1 - expected), .05),
      );
    }
    evidence[name] = samples;
  }

  testWidgets(
    'button hover colors and pressed displacement follow 150ms CSS ease',
    (tester) async {
      const marker = ValueKey('press-marker');
      await tester.pumpWidget(
        app(
          DesktopButton(
            onPressed: () {},
            child: const Text('操作', key: marker),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byType(DesktopButton), text = find.byKey(marker);
      Color background() =>
          (tester
                      .renderObject<RenderDecoratedBox>(
                        find
                            .descendant(
                              of: button,
                              matching: find.byType(DecoratedBox),
                            )
                            .first,
                      )
                      .decoration
                  as BoxDecoration)
              .color!;
      final pointer = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await pointer.addPointer(location: Offset.zero);
      await pointer.moveTo(tester.getCenter(button));
      await tester.pump();
      final hover = <Map<String, Object>>[];
      for (var time = 0; time <= 170; time += 10) {
        if (time != 0) await tester.pump(const Duration(milliseconds: 10));
        final color = background();
        final expected = Color.lerp(
          const Color(0xffffffff),
          const Color(0xffe9ecf1),
          Curves.ease.transform((time / 150).clamp(0.0, 1.0)),
        )!;
        expect(color.r, closeTo(expected.r, .0001));
        expect(color.g, closeTo(expected.g, .0001));
        expect(color.b, closeTo(expected.b, .0001));
        hover.add({'ms': time, 'argb': color.toARGB32()});
      }
      evidence['hover'] = hover;
      final start = tester.getTopLeft(text).dy;
      final press = await tester.startGesture(tester.getCenter(button));
      await tester.pump();
      final samples = <Map<String, Object>>[];
      for (var time = 0; time <= 170; time += 10) {
        if (time != 0) await tester.pump(const Duration(milliseconds: 10));
        final y = tester.getTopLeft(text).dy - start;
        expect(
          y,
          closeTo(Curves.ease.transform((time / 150).clamp(0.0, 1.0)), .0001),
        );
        samples.add({'ms': time, 'translationY': y});
      }
      evidence['pressed'] = samples;
      await press.up();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(text).dy, closeTo(start, .0001));
      await pointer.removePointer();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'quiet hover preserves premultiplied color and selection owns one background',
    (tester) async {
      Widget control(bool selected) => app(
        DesktopButton(
          kind: DesktopButtonKind.quiet,
          selected: selected,
          onPressed: () {},
          child: const Text('导航'),
        ),
      );
      await tester.pumpWidget(control(false));
      await tester.pumpAndSettle();
      final button = find.byType(DesktopButton);
      Color background() =>
          (tester
                      .renderObject<RenderDecoratedBox>(
                        find
                            .descendant(
                              of: button,
                              matching: find.byType(DecoratedBox),
                            )
                            .first,
                      )
                      .decoration
                  as BoxDecoration)
              .color!;
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(button));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      expect(background().r, closeTo(const Color(0xffe9ecf1).r, .000000001));
      expect(background().a, closeTo(Curves.ease.transform(.5), .00001));
      await tester.pumpAndSettle();
      await tester.pumpWidget(control(true));
      await tester.pumpAndSettle();
      expect(background().toARGB32(), const Color(0xffede8f5).toARGB32());
      final shape = tester.renderObject<RenderPhysicalShape>(
        find.descendant(of: button, matching: find.byType(PhysicalShape)).first,
      );
      expect(shape.color.a, 0);
      await mouse.removePointer();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'detail entrance measures 3px/180ms and stable identity does not replay',
    (tester) async {
      const key = ValueKey('detail-marker');
      await tester.pumpWidget(
        app(
          const DesktopEntrance(
            key: ValueKey('a'),
            child: Text('详情', key: key),
          ),
        ),
      );
      await observe(
        tester,
        find.byKey(key),
        'detail',
        milliseconds: 180,
        initialY: 3,
      );
      await tester.pumpWidget(
        app(
          const DesktopEntrance(
            key: ValueKey('a'),
            child: Text('同一资料刷新', key: key),
          ),
        ),
      );
      expect(opacity(find.byKey(key)), 1);
      await tester.pumpWidget(
        app(
          const DesktopEntrance(
            key: ValueKey('b'),
            child: Text('新资料', key: key),
          ),
        ),
      );
      await observe(
        tester,
        find.byKey(key),
        'new-identity',
        milliseconds: 180,
        initialY: 3,
      );
    },
  );

  testWidgets(
    'dialog measures 7px/180ms; rapid closing leaves no blocking route',
    (tester) async {
      const marker = ValueKey('dialog-marker');
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => DesktopButton(
              onPressed: () => showDesktopDialog<void>(
                context,
                builder: (_) => const DesktopDialog(
                  title: Text('弹窗', key: marker),
                  content: Text('正文'),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开'));
      await tester.pump();
      await observe(
        tester,
        find.byKey(marker),
        'dialog',
        milliseconds: 180,
        initialY: 7,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(marker), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'anchored menu measures -3px/120ms and never centers over its trigger',
    (tester) async {
      const marker = ValueKey('menu-marker');
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => DesktopButton(
              onPressed: () => showAnchoredSurface<void>(
                context,
                width: 200,
                height: 100,
                builder: (_) => const Text('菜单', key: marker),
              ),
              child: const Text('菜单入口'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final anchor = tester.getRect(find.text('菜单入口'));
      await tester.tap(find.text('菜单入口'));
      await tester.pump();
      await observe(
        tester,
        find.byKey(marker),
        'menu',
        milliseconds: 120,
        initialY: -3,
      );
      expect(
        tester.getRect(find.byKey(marker)).top,
        greaterThan(anchor.bottom),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'feedback measures 6px/180ms, replacement cancels the old timer',
    (tester) async {
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => DesktopButton(
              onPressed: () => DesktopFeedback.show(context, '保存完成'),
              child: const Text('触发'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('触发'));
      await tester.pump();
      await observe(
        tester,
        find.text('保存完成'),
        'feedback',
        milliseconds: 180,
        initialY: 6,
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.text('触发'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('保存完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
