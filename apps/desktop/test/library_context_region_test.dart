import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/library_context_region.dart';

void main() {
  testWidgets(
    'Control click opens one menu without activation; later Enter and keyboard context menus work',
    (t) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var activations = 0, menus = 0;
      String? action;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => LibraryContextRegion(
                onActivate: () => activations++,
                onContext: (position) async {
                  menus++;
                  action = await showLibraryContextMenu(context, position, [
                    const PopupMenuItem(value: 'move', child: Text('移动')),
                  ]);
                },
                builder: (activate) => TextButton(
                  focusNode: focus,
                  onPressed: activate,
                  child: const Text('资料'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.tap(find.text('资料'), kind: PointerDeviceKind.mouse);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
      expect(menus, 1);
      expect(activations, 0);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      focus.requestFocus();
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(activations, 1);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.f10);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pumpAndSettle();
      expect(menus, 2);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(action, 'move');
      expect(activations, 1);
      focus.requestFocus();
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await t.pumpAndSettle();
      expect(menus, 3);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'disabling management context menus preserves normal row activation',
    (t) async {
      var activations = 0, menus = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryContextRegion(
              enabled: false,
              onActivate: () => activations++,
              onContext: (_) async {
                menus++;
              },
              builder: (activate) =>
                  TextButton(onPressed: activate, child: const Text('资料')),
            ),
          ),
        ),
      );
      await t.tap(find.text('资料'));
      await t.pumpAndSettle();
      expect(activations, 1);
      expect(menus, 0);
    },
  );
}
