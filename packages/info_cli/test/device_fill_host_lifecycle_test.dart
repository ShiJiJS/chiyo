@TestOn('windows || mac-os')
library;

import 'dart:io';

import 'package:info_cli/device_credential_batch_host.dart';
import 'package:info_cli/device_focused_fill_host.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class _Focus implements FocusedFillDriver {
  @override
  Future<PreparedFocusedFill> prepare(FocusedFillApplication application) =>
      throw StateError('Lifecycle checks never prepare input');
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('device-host-lifecycle-');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> lockAvailable(File file, bool available) async {
    final probe = await Process.run(Platform.resolvedExecutable, [
      File('test/support/device_host_lock_probe.dart').absolute.path,
      file.path,
    ]);
    expect(probe.exitCode, available ? 0 : 2);
    expect(probe.stdout, isEmpty);
    expect(probe.stderr, isEmpty);
  }

  for (final batch in [false, true]) {
    final name = batch ? 'batch' : 'focus';
    String folder() =>
        '${root.path}/${batch ? 'credential-batch-host' : 'focused-fill-host'}';
    File guard() => File('${folder()}/owner.lock');
    File endpoint() => File('${folder()}/endpoint.json');
    Future<Future<void> Function()> start() async {
      if (batch) {
        return (await DeviceCredentialBatchHost.start(directory: root)).close;
      }
      return (await DeviceFocusedFillHost.start(
        directory: root,
        driver: _Focus(),
      )).close;
    }

    test('$name startup rejection closes its acquired owner lock', () async {
      await privateDeviceDirectory(Directory(folder()));
      await writePrivateDeviceState(endpoint(), {'invalid': true});
      await expectLater(start(), throwsFormatException);
      await lockAvailable(guard(), true);
      // NTFS also rejects removal of an open Dart file handle independently
      // of its record lock. Do not retry deletion or wait for process exit.
      await root.delete(recursive: true);
    });

    test('$name awaited close releases ownership before returning', () async {
      final close = await start();
      addTearDown(close);
      await lockAvailable(guard(), false);
      await Future.wait([close(), close()]);
      expect((await readPrivateDeviceState(endpoint()))!['phase'], 'closed');
      await lockAvailable(guard(), true);
      await root.delete(recursive: true);
    });

    test(
      '$name close releases its lock when closed-state publication fails',
      () async {
        final close = await start();
        addTearDown(() async {
          try {
            await close();
          } on Object {
            // This case deliberately makes locator publication fail.
          }
        });
        await lockAvailable(guard(), false);
        await endpoint().delete();
        await Directory(endpoint().path).create();
        await expectLater(close(), throwsA(anything));
        await lockAvailable(guard(), true);
        await root.delete(recursive: true);
      },
    );
  }
}
