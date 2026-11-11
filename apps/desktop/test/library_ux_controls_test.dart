import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/ui.dart';
import 'package:info_desktop/desktop_scroll.dart';
import 'package:info_desktop/desktop_interaction_host.dart';
import 'package:info_desktop/settings_controls.dart';
import 'package:info_desktop/prototype_dialog.dart';

Widget host(Widget child) => MaterialApp(
  theme: informationTheme().copyWith(platform: TargetPlatform.windows),
  scrollBehavior: const DesktopScrollBehavior(),
  builder: (_, child) => DesktopInteractionHost(child: child!),
  home: Scaffold(body: child),
);

void main() {
  for (final scale in [1.0, 2.0]) {
    for (final settings in [true, false]) {
      testWidgets(
        'dialog close glyph stays whole at $scale text (settings=$settings)',
        (tester) async {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpWidget(
            host(
              settings
                  ? const SettingsDialog(
                      title: 'Structure',
                      actions: [],
                      child: Text('Body'),
                    )
                  : PrototypeDialog(
                      title: 'Structure',
                      onClose: () {},
                      body: const Text('Body'),
                    ),
            ),
          );
          await tester.pumpAndSettle();
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.text('×'),
              matching: find.byType(RichText),
            ),
          );
          final glyph = paragraph
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 1),
              )
              .single
              .toRect();
          expect(glyph.left, greaterThanOrEqualTo(-.01));
          expect(glyph.right, lessThanOrEqualTo(paragraph.size.width + .01));
          expect(glyph.bottom, lessThanOrEqualTo(paragraph.size.height + .01));
          expect(find.text('×').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'popup aligns in an inset navigator such as the Windows title frame',
    (tester) async {
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          builder: (_, child) => Padding(
            padding: const EdgeInsets.fromLTRB(40, 60, 20, 20),
            child: child,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: DesktopSelect<int>(
                key: const ValueKey('inset-trigger'),
                value: 1,
                items: const [
                  DropdownMenuItem(value: 1, child: Text('First')),
                  DropdownMenuItem(value: 2, child: Text('Second')),
                ],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      final trigger = tester.getRect(
        find.byKey(const ValueKey('inset-trigger')),
      );
      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      final popup = tester.getRect(
        find.byWidgetPredicate((w) => w is Material && w.elevation == 4),
      );
      expect(popup.top, closeTo(trigger.bottom + 6, .01));
      expect(popup.left, closeTo(trigger.left + 12, .01));
      expect(popup.right, lessThanOrEqualTo(608));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    },
  );

  testWidgets('long menu searches, reports no match, and commits with Enter', (
    tester,
  ) async {
    var value = 99, changes = 0;
    await tester.pumpWidget(
      host(
        Center(
          child: DesktopSelect<int>(
            value: value,
            items: [
              for (var n = 0; n < 100; n++)
                DropdownMenuItem(value: n, child: Text('Option $n')),
            ],
            onChanged: (v) {
              value = v!;
              changes++;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Option 99'));
    await tester.pumpAndSettle();
    final search = find.widgetWithText(TextField, '搜索选项');
    await tester.enterText(search, 'does not exist');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的选项'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(changes, 0);
    await tester.enterText(search, 'Option 83');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(value, 83);
    expect(changes, 1);
  });

  testWidgets(
    'long menu keyboard reaches offscreen options and skips disabled ones',
    (tester) async {
      int? value;
      await tester.pumpWidget(
        host(
          Center(
            child: DesktopSelect<int>(
              value: 0,
              items: [
                for (var n = 0; n < 30; n++)
                  DropdownMenuItem(
                    value: n,
                    enabled: n != 14,
                    child: Text('Option $n'),
                  ),
              ],
              onChanged: (v) => value = v,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Option 0'));
      await tester.pumpAndSettle();
      for (var n = 0; n < 17; n++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(
        find.widgetWithText(TextButton, 'Option 18').hitTestable(),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(value, 18);
    },
  );

  testWidgets(
    'resizing and clicking outside dismiss without changing a value',
    (tester) async {
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var changes = 0;
      await tester.pumpWidget(
        host(
          Center(
            child: DesktopSelect<int>(
              value: 1,
              items: const [
                DropdownMenuItem(value: 1, child: Text('First')),
                DropdownMenuItem(value: 2, child: Text('Second')),
              ],
              onChanged: (_) => changes++,
            ),
          ),
        ),
      );
      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsNothing);
      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(600, 440);
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsNothing);
      expect(changes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final bottom in [false, true]) {
    testWidgets(
      'menu stays wholly ${bottom ? 'above' : 'below'} its trigger and commits once',
      (tester) async {
        tester.view.physicalSize = const Size(640, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var value = 30, changes = 0;
        await tester.pumpWidget(
          host(
            StatefulBuilder(
              builder: (context, update) => Align(
                alignment: bottom
                    ? Alignment.bottomCenter
                    : Alignment.topCenter,
                child: SizedBox(
                  width: 180,
                  child: DesktopSelect<int>(
                    key: const ValueKey('menu-trigger'),
                    value: value,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: 15, child: Text('15 分钟')),
                      DropdownMenuItem(value: 30, child: Text('30 分钟')),
                    ],
                    onChanged: (next) => update(() {
                      value = next!;
                      changes++;
                    }),
                  ),
                ),
              ),
            ),
          ),
        );
        final trigger = tester.getRect(
          find.byKey(const ValueKey('menu-trigger')),
        );
        await tester.tap(find.text('30 分钟'));
        await tester.pumpAndSettle();
        final popup = find.byWidgetPredicate(
          (w) => w is Material && w.elevation == 4,
        );
        final rect = tester.getRect(popup);
        expect(
          bottom
              ? rect.bottom <= trigger.top - 6
              : rect.top >= trigger.bottom + 6,
          isTrue,
        );
        expect(rect.left, greaterThanOrEqualTo(12));
        expect(rect.right, lessThanOrEqualTo(628));
        await tester.tap(find.text('15 分钟'));
        await tester.pumpAndSettle();
        expect(value, 15);
        expect(changes, 1);
        expect(popup, findsNothing);
        await tester.tap(find.text('15 分钟'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(changes, 1);
        expect(value, 15);
        expect(popup, findsNothing);
        expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
      },
    );
  }

  for (final explicit in [false, true]) {
    testWidgets(
      'scrollbar reserves a separate lane, drag never clicks content ($explicit)',
      (tester) async {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        var clicked = 0;
        Widget list = ListView(
          controller: scroll,
          padding: EdgeInsets.zero,
          children: [
            for (var i = 0; i < 50; i++)
              TextButton(
                key: ValueKey('row-$i'),
                onPressed: () => clicked++,
                child: Text('行 $i'),
              ),
          ],
        );
        if (explicit) {
          list = Scrollbar(
            controller: scroll,
            thumbVisibility: true,
            child: list,
          );
        }
        await tester.pumpWidget(
          host(
            Center(
              child: SizedBox(
                key: const ValueKey('region'),
                width: 260,
                height: 200,
                child: list,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Scrollbar), findsOneWidget);
        final outer = tester.getRect(find.byKey(const ValueKey('region')));
        final row = tester.getRect(find.byKey(const ValueKey('row-0')));
        expect(
          row.right,
          lessThanOrEqualTo(outer.right),
        );
        await tester.dragFrom(
          Offset(outer.right - 5, outer.top + 12),
          const Offset(0, 100),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(scroll.offset, greaterThan(0));
        expect(clicked, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'keyboard tooltip uses normal focus, Escape dismisses without losing input focus',
    (tester) async {
      await tester.pumpWidget(
        host(
          Center(
            child: IconButton(
              tooltip: '字段类型说明',
              onPressed: () {},
              icon: const Icon(Icons.info_outline),
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();
      expect(find.text('字段类型说明'), findsOneWidget);
      final focused = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('字段类型说明'), findsNothing);
      expect(FocusManager.instance.primaryFocus, focused);
    },
  );

  testWidgets('removing a menu trigger closes its floating surface', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      host(
        ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (_, value, _) => value
              ? Center(
                  child: DesktopSelect<int>(
                    value: 30,
                    items: const [
                      DropdownMenuItem(value: 15, child: Text('15 分钟')),
                      DropdownMenuItem(value: 30, child: Text('30 分钟')),
                    ],
                    onChanged: (_) {},
                  ),
                )
              : const Text('已切换'),
        ),
      ),
    );
    await tester.tap(find.text('30 分钟'));
    await tester.pumpAndSettle();
    visible.value = false;
    await tester.pumpAndSettle();
    expect(find.text('15 分钟'), findsNothing);
    expect(find.text('已切换'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
