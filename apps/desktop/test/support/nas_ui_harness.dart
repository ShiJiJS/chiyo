import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'online_ui_harness.dart';

/// Explicit mechanical-disk NAS checks allow real I/O deadlines without
/// widening ordinary isolated test timeouts or printing private UI contents.
class NasUiHarness extends OnlineUiHarness {
  NasUiHarness(super.tester);
  String Function()? diagnostic;
  @override
  Future<void> until(bool Function() ready) async {
    for (var i = 0; i < 600; i++) {
      if (ready()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 80));
    }
    fail(
      'Explicit NAS check did not settle ($phase): ${diagnostic?.call() ?? ''}',
    );
  }

  @override
  Future<void> tap(String id) async {
    await until(() {
      if (key(id).evaluate().length != 1) return false;
      final widget = key(id).evaluate().single.widget;
      return widget is! DesktopButton ||
          widget.onPressed != null && !widget.busy;
    });
    await tester.ensureVisible(key(id));
    await tester.pump();
    // Closing an anchored picker leaves its barrier in the overlay during
    // the exit animation. A mounted/enabled button alone is not yet clickable.
    final buttons = find.descendant(
      of: key(id),
      matching: find.byType(TextButton),
    );
    final target = buttons.evaluate().length == 1 ? buttons : key(id);
    await until(() => target.hitTestable().evaluate().length == 1);
    await tester.runAsync(() => tester.tap(target));
    await tester.pump();
  }
}
