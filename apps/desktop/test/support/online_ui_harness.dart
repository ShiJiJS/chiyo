import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';

/// Pump UI work while real TLS/SQLCipher/native processes run in runAsync.
/// Never await a real I/O future from Flutter's fake clock zone.
class OnlineUiHarness {
  OnlineUiHarness(this.tester);
  final WidgetTester tester;
  String phase = 'startup';
  Finder key(String id) => find.byKey(ValueKey(id));
  Future<void> until(bool Function() ready) async {
    for (var i = 0; i < 600; i++) {
      if (ready()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    fail(
      'Online UI did not settle ($phase): ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().join(' | ')}',
    );
  }

  Future<T> resolve<T>(Future<T> Function() action) async {
    var done = false;
    late T value;
    Object? error;
    await tester.runAsync(() async {
      unawaited(
        action().then<void>(
          (v) {
            value = v;
            done = true;
          },
          onError: (Object e) {
            error = e;
            done = true;
          },
        ),
      );
    });
    await until(() => done);
    if (error != null) throw error!;
    return value;
  }

  Future<void> tap(String id) async {
    await until(() {
      if (key(id).evaluate().length != 1) return false;
      final widget = key(id).evaluate().single.widget;
      return widget is! DesktopButton ||
          widget.onPressed != null && !widget.busy;
    });
    await tester.ensureVisible(key(id));
    await tester.pump();
    await tester.runAsync(() => tester.tap(key(id)));
    await tester.pump();
  }
}
