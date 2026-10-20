import 'dart:io';
import 'package:info_cli/desktop_control.dart';
import 'package:test/test.dart';

void main() {
  test(
    'app control rejects malformed or duplicate arguments before any IPC',
    () async {
      for (final args in <List<String>>[
        [],
        ['app'],
        ['app', 'kill'],
        ['app', 'quit', '--port', '47125'],
        ['app', 'quit', '--pid'],
        ['app', 'quit', '--pid', '0'],
        ['app', 'quit', '--pid', '4294967296'],
        ['app', 'quit', '--pid', '1', '--pid', '2'],
        ['app', 'quit', '--timeout-ms', '99'],
        ['app', 'quit', '--timeout-ms', '60001'],
      ]) {
        final result = await desktopControlCommand(args);
        expect(result.exitCode, 64, reason: '$args');
        expect(result.output['status'], 'invalid_request');
      }
    },
  );
  test('explicit unrelated CLI process is refused and remains alive', () async {
    final result = await desktopControlCommand([
      'app',
      'quit',
      '--pid',
      '$pid',
    ]);
    expect(
      result.output['status'],
      Platform.isWindows ? 'target_mismatch' : 'unsupported_platform',
    );
    expect(result.exitCode, Platform.isWindows ? 75 : 69);
  });
}
