import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/ui.dart';

void main() {
  testWidgets('desktop menu supports keyboard selection and escape', (
    tester,
  ) async {
    var value = 30;
    await tester.pumpWidget(
      MaterialApp(
        theme: informationTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => Center(
              child: DesktopSelect<int>(
                key: const ValueKey('duration'),
                value: value,
                items: const [
                  DropdownMenuItem(value: 15, child: Text('15 分钟')),
                  DropdownMenuItem(value: 30, child: Text('30 分钟')),
                ],
                onChanged: (next) => update(() => value = next!),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('15 分钟'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(value, 15);
    expect(find.text('30 分钟'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('duration')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(value, 15);
    expect(find.text('30 分钟'), findsNothing);
  });

  testWidgets('unsaved selection does not replace the persisted setting', (
    tester,
  ) async {
    int? attempted;
    await tester.pumpWidget(
      MaterialApp(
        theme: informationTheme(),
        home: Scaffold(
          body: Center(
            child: DesktopSelect<int>(
              value: 30,
              items: const [
                DropdownMenuItem(value: 15, child: Text('15 分钟')),
                DropdownMenuItem(value: 30, child: Text('30 分钟')),
              ],
              onChanged: (next) => attempted = next,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('30 分钟'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 分钟'));
    await tester.pumpAndSettle();
    expect(attempted, 15);
    expect(find.text('30 分钟'), findsOneWidget);
    expect(find.text('15 分钟'), findsNothing);
  });
}
