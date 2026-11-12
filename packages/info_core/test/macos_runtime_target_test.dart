import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/macos_runtime_target.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Darwin private stdin tolerates a target that exits without reading',
    () async {
      final target = MacOsRuntimeTarget.spawn('/usr/bin/true', [], {
        'PATH': '/usr/bin:/bin',
      }, pipeStdin: true);
      target.resume();
      final delivered = target.sendStdin(List.filled(65536, 83));
      expect(await target.exitCode.timeout(const Duration(seconds: 5)), 0);
      await delivered.timeout(const Duration(seconds: 5));
    },
    skip: !Platform.isMacOS,
  );

  for (final code in [0, 7, 255]) {
    test('Darwin short exit preserves status $code', () async {
      final target = MacOsRuntimeTarget.spawn(
        '/bin/sh',
        ['-c', 'exit $code'],
        {'PATH': '/usr/bin:/bin'},
      );
      target.resume();
      expect(await target.exitCode.timeout(const Duration(seconds: 5)), code);
    }, skip: !Platform.isMacOS);
  }
  test('Darwin signal exit preserves its native signal', () async {
    final target = MacOsRuntimeTarget.spawn(
      '/bin/sh',
      ['-c', r'kill -TERM $$'],
      {'PATH': '/usr/bin:/bin'},
    );
    target.resume();
    expect(await target.exitCode.timeout(const Duration(seconds: 5)), -15);
  }, skip: !Platform.isMacOS);
  test(
    'actual Darwin target remains identifiable until resumed and short exit is reaped',
    () async {
      final target = MacOsRuntimeTarget.spawn('/usr/bin/true', [], {
        'PATH': '/usr/bin:/bin',
      });
      final identity = CredentialProcessIdentity.capture(target.pid)!;
      try {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(
          CredentialProcessIdentity.isActive(target.pid, identity.value),
          isTrue,
        );
        target.resume();
        expect(await target.exitCode.timeout(const Duration(seconds: 5)), 0);
        expect(
          CredentialProcessIdentity.isActive(target.pid, identity.value),
          isFalse,
        );
      } finally {
        identity.close();
        target.resume();
        await target.exitCode;
      }
    },
    skip: !Platform.isMacOS,
  );
}
