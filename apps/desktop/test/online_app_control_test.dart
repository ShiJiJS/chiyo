import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/macos_desktop_control.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/online_desktop_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('agent_info_manage/desktop');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'online native control commits after App resources close and never claims a live process exited',
    () async {
      final root = await Directory.systemTemp.createTemp('online-app-control-');
      final directory = Directory('${root.path}/control');
      MacDesktopControlHost? host;
      var closed = false, terminated = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'terminate') {
          expect(closed, true);
          final record = jsonDecode(
            await File('${directory.path}/endpoint.json').readAsString(),
          );
          expect(record['exitCommitted'], true);
          terminated++;
        }
        return {'tray': true, 'notifications': 'enabled'};
      });
      final runtime = OnlineDesktopRuntime(
        platform: NativeDesktopPlatform(),
        beforeExit: () async {
          closed = true;
        },
        onResume: () async {},
        openAppControl: (state, quit) async =>
            host = await MacDesktopControlHost.start(
              directory: directory,
              state: state,
              quit: quit,
            ),
      );
      try {
        await runtime.start();
        final status = await MacDesktopControl.execute(
          quit: false,
          executable: Platform.resolvedExecutable,
          processId: pid,
          directory: directory,
        );
        expect(status['status'], 'running');
        final quit = await MacDesktopControl.execute(
          quit: true,
          executable: Platform.resolvedExecutable,
          processId: pid,
          directory: directory,
          timeout: const Duration(milliseconds: 300),
        );
        expect(quit['status'], 'timeout');
        expect(terminated, 1);
        expect(runtime.closed, true);
        // The test native boundary does not kill this VM. It cannot be called
        // an observed OS exit merely because the durable commitment exists.
      } finally {
        await host?.close();
        runtime.dispose();
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'an unavailable optional control registry does not block online start or normal quit',
    () async {
      var closed = false, terminated = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'terminate') terminated = true;
        return {'tray': true, 'notifications': 'enabled'};
      });
      final runtime = OnlineDesktopRuntime(
        platform: NativeDesktopPlatform(),
        beforeExit: () async {
          closed = true;
        },
        onResume: () async {},
        openAppControl: (_, _) async =>
            throw StateError('synthetic registry unavailable'),
      );
      try {
        await runtime.start();
        await runtime.quit();
        expect(closed && terminated && runtime.closed, true);
      } finally {
        runtime.dispose();
      }
    },
  );
}
