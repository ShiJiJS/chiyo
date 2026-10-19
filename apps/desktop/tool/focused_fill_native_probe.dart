// Explicit QA entry only. Production startup never imports this file.
// Uses the same native workflow/assertions as the testWidgets regression, with
// a normal WidgetsBinding so OS-owned accessibility handles live with the app.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/focused_fill_native_test.dart'
    show runFocusedFillNative;

Future<void> main() async {
  if (!const bool.fromEnvironment('FILL_STANDALONE_PROBE')) {
    stderr.writeln('Explicit isolated QA opt-in is required.');
    exit(64);
  }
  final binding = WidgetsFlutterBinding.ensureInitialized();
  var frameworkErrors = 0;
  FlutterError.onError = (_) => frameworkErrors++;
  binding.platformDispatcher.onError = (_, _) {
    frameworkErrors++;
    return true;
  };
  final controller = LiveWidgetController(binding);
  void verifyFrameworkErrors() => expect(frameworkErrors, 0);
  try {
    await runFocusedFillNative(
      controller,
      mount: (widget) async {
        runApp(widget);
        await controller.pump();
      },
      verifyFrameworkErrors: verifyFrameworkErrors,
      lockedOnly: false,
      harness: 'production WidgetsBinding + LiveWidgetController',
    ).timeout(const Duration(minutes: 6));
    verifyFrameworkErrors();
    stdout.writeln('NATIVE_FOCUSED_FILL_ASSERTIONS=PASS');
    await stdout.flush();
    exit(0);
  } on Object {
    // No raw framework errors or process payloads are emitted by this probe.
    stderr.writeln('NATIVE_FOCUSED_FILL_ASSERTIONS=FAIL');
    await stderr.flush();
    exit(1);
  }
}
