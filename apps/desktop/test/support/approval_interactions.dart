import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> selectGrantMinutes(
  WidgetTester tester,
  Finder control,
  int minutes,
) async {
  if (control.evaluate().single.widget is DropdownButton<int>) {
    await tester.tap(control);
    await tester.pumpAndSettle();
    final label = minutes == 480
        ? '8 小时（默认）'
        : minutes < 60
        ? '$minutes 分钟'
        : '${minutes ~/ 60} 小时';
    await tester.tap(find.text(label).last);
  } else {
    await tester.enterText(control, '$minutes');
  }
  await tester.pumpAndSettle();
}
