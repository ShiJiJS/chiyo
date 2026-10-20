import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/windows_desktop_control.dart';
import 'package:test/test.dart';

void main() {
  final executable = Platform.environment['INFO_TEST_CONTROL_FIXTURE'];
  test(
    'native control pins one peer and preserves explicit failures and unknown exits',
    () async {
      final peers = <Process>[];
      Future<Process> peer(String mode) async {
        final process = await Process.start(executable!, [mode]);
        peers.add(process);
        unawaited(process.stderr.drain<void>());
        expect(
          await process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 5)),
          'ready',
        );
        return process;
      }

      Future<Map<String, Object?>> call(
        Process process, {
        bool quit = true,
        int milliseconds = 2000,
      }) => WindowsDesktopControl.execute(
        quit: quit,
        executable: executable!,
        processId: process.pid,
        timeout: Duration(milliseconds: milliseconds),
      );
      addTearDown(() async {
        for (final process in peers) {
          await process.stdin.close();
          expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0);
        }
      });
      final normal = await peer('normal');
      expect((await call(normal, quit: false))['status'], 'running');
      final clock = Stopwatch()..start();
      expect((await call(normal))['status'], 'exited');
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(160));
      final old = await peer('old');
      expect((await call(old))['status'], 'unsupported_version');
      final stuck = await peer('timeout');
      expect((await call(stuck, milliseconds: 200))['status'], 'timeout');
      expect((await call(stuck, quit: false))['status'], 'exiting');
      final failed = await peer('failed');
      expect((await call(failed))['status'], 'shutdown_failed');
      expect((await call(failed, quit: false))['status'], 'shutdown_failed');
      expect((await call(failed))['status'], 'exited');
      final starting = await peer('starting');
      expect((await call(starting))['status'], 'exited');
      // Two synthetic instances remain: default discovery refuses
      // to select one rather than treating all matching processes as a target.
      expect(
        (await WindowsDesktopControl.execute(
          quit: true,
          executable: executable!,
        ))['status'],
        'ambiguous_target',
      );
      expect((await call(stuck, quit: false))['status'], 'exiting');
      await old.stdin.close();
      await old.exitCode;
      await stuck.stdin.close();
      await stuck.exitCode;
      final single = await peer('normal');
      expect(
        (await WindowsDesktopControl.execute(
          quit: true,
          executable: executable,
        ))['status'],
        'exited',
      );
      expect(await single.exitCode, 0);
      expect(
        (await WindowsDesktopControl.execute(
          quit: true,
          executable: executable,
        ))['status'],
        'not_running',
      );
    },
    skip: !Platform.isWindows || executable == null
        ? 'Opt in with the compiled synthetic Win32 control peer.'
        : false,
  );
}
