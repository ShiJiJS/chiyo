import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

void main() {
  testWidgets(
    'search shortcut leaves forward and reverse form traversal available',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      addTearDown(() async {
        final closing = service.close();
        await tester.pump();
        await closing;
      });
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-information')));
      await tester.pumpAndSettle();
      final name = find.byKey(const ValueKey('item-name'));
      await tester.enterText(name, 'Keep this draft');
      final editable = tester.widget<EditableText>(
        find.descendant(of: name, matching: find.byType(EditableText)),
      );
      expect(editable.focusNode.hasFocus, isTrue);

      // macOS routes unhandled text keys through its selector test handler;
      // Windows uses the WidgetsApp key/action path. Both must retain defaults.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(editable.focusNode.hasFocus, isFalse);
      expect(FocusManager.instance.primaryFocus, isNotNull);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(editable.focusNode.hasFocus, isTrue);
      expect(editable.controller.text, 'Keep this draft');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );
}
