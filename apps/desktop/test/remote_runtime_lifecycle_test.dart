@TestOn('windows || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/online_desktop_runtime.dart';
import 'package:info_desktop/workspace/remote_workspace_runtime.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

import '../../server/test/support/device_credential_fixture.dart';
import 'support/desktop_platform_fixture.dart';

class _Http extends HttpOverrides {}

Future<void> _lockAvailable(File file, bool available) async {
  final config = File('.dart_tool/package_config.json').absolute;
  final packages =
      (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
  final flutter = packages.singleWhere((p) => p['name'] == 'flutter') as Map;
  final sdk = Directory.fromUri(
    config.uri.resolve(flutter['rootUri'] as String),
  ).parent.parent;
  final probe = await Process.run(
    '${sdk.path}/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}',
    [
      File(
        '../../packages/info_cli/test/support/device_host_lock_probe.dart',
      ).absolute.path,
      file.path,
    ],
  );
  expect(probe.exitCode, available ? 0 : 2);
  expect(probe.stdout, isEmpty);
  expect(probe.stderr, isEmpty);
}

void main() {
  test(
    'runtime quit finishes its receipt without self-waiting and post-exit status opens no journal',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final fixture = await DeviceCredentialFixture.create();
        final platform = NativeDesktopFixture();
        late RemoteWorkspaceRuntime runtime;
        final desktop = OnlineDesktopRuntime(
          platform: platform,
          beforeExit: () => runtime.release(),
          onResume: () async {},
        );
        final directory = Directory('${fixture.root.path}/runtime-client');
        runtime = RemoteWorkspaceRuntime(
          fixture.owner,
          desktop,
          directory: directory.path,
          copies: ({bool maintain = false}) async => [],
          preferences: () async => const WorkspacePreferences(),
          changed: () {},
        );
        try {
          await desktop.start();
          final preview = await runtime.previewQuit();
          final change = WorkspaceRuntimeChange(
            operationId: 'synthetic-runtime-quit',
            action: WorkspaceRuntimeAction.quit,
            expectedVersion: preview.version,
            quitToken: preview.token,
          );
          final receipt = await runtime
              .change(change)
              .timeout(const Duration(seconds: 10));
          expect(receipt.matches(change), true);
          expect(receipt.phase, WorkspaceRuntimePhase.stopped);
          expect(platform.terminated, true);
          await directory.delete(recursive: true);
          expect((await runtime.status()).serviceAvailable, false);
          expect(await directory.exists(), false);
        } finally {
          desktop.dispose();
          await fixture.dispose();
        }
      }, _Http());
    },
  );
  test('ordinary App quit waits for an in-flight runtime status lock', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await DeviceCredentialFixture.create();
      final platform = NativeDesktopFixture();
      final entered = Completer<void>(), gate = Completer<void>();
      final releasing = Completer<void>();
      late RemoteWorkspaceRuntime runtime;
      final desktop = OnlineDesktopRuntime(
        platform: platform,
        beforeExit: () {
          final release = runtime.release();
          if (!releasing.isCompleted) releasing.complete();
          return release;
        },
        onResume: () async {},
      );
      final directory = '${fixture.root.path}/runtime-client';
      runtime = RemoteWorkspaceRuntime(
        fixture.owner,
        desktop,
        directory: directory,
        copies: ({bool maintain = false}) async => [],
        preferences: () async {
          if (!entered.isCompleted) entered.complete();
          await gate.future;
          return const WorkspacePreferences();
        },
        changed: () {},
      );
      Future<void>? status;
      Future<void>? quit;
      try {
        await desktop.start();
        status = runtime.status().then<void>(
          (_) {},
          onError: (Object e) {
            expect(e, isA<WorkspaceFailure>());
          },
        );
        await entered.future;
        final lock = File(
          '$directory/runtime/${sha256.convert(utf8.encode(fixture.owner.serverId))}/runtime.lock',
        );
        await _lockAvailable(lock, false);
        quit = desktop.quit();
        await releasing.future;
        await expectLater(
          runtime.status().timeout(const Duration(seconds: 2)),
          throwsA(isA<WorkspaceFailure>()),
        );
        // The child probe is an independent I/O turn, not a timing allowance.
        // The blocked read must retain ownership and delay native termination.
        await _lockAvailable(lock, false);
        expect(platform.terminated, false);
        gate.complete();
        await status;
        await quit;
        expect(platform.terminated, true);
        await _lockAvailable(lock, true);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await status;
        await quit;
        desktop.dispose();
        await fixture.dispose();
      }
    }, _Http());
  });
}
