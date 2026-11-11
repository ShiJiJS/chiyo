import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/online_desktop_runtime.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'support/desktop_platform_fixture.dart';

class _Native extends NativeDesktopFixture {
  int shows = 0;
  @override
  Future<void> showWindow() async {
    shows++;
    await super.showWindow();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native activation reports visibility without requesting navigation',
    () async {
      const channel = MethodChannel('agent_info_manage/desktop');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'initialize'
            ? {'tray': true, 'notifications': 'enabled'}
            : null,
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        channel.setMethodCallHandler(null);
      });
      final events = <DesktopEvent>[];
      await NativeDesktopPlatform().initialize((event) async {
        events.add(event);
      });
      final reply = Completer<void>();
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('shown')),
        (_) => reply.complete(),
      );
      await reply.future;
      expect(events, [DesktopEvent.windowShown]);
    },
  );
  test(
    'local activation clears hidden state without routing or a second native show',
    () async {
      final service = InformationService.fictional();
      final native = _Native();
      final runtime = DesktopRuntime(
        service: service,
        platform: native,
        closeServer: () async {},
        closeRepository: () async {},
      );
      await runtime.start();
      try {
        await runtime.handleEvent(DesktopEvent.closeWindow);
        expect(runtime.windowHidden, isTrue);
        await runtime.handleEvent(DesktopEvent.windowShown);
        expect(runtime.windowHidden, isFalse);
        expect(runtime.navigationRevision, 0);
        expect(native.shows, 0);
      } finally {
        await runtime.quit();
      }
    },
  );
  test(
    'online activation updates visibility while modal navigation is disabled',
    () async {
      final native = _Native();
      final runtime = OnlineDesktopRuntime(
        platform: native,
        beforeExit: () async {},
        onResume: () async {},
      );
      await runtime.start();
      try {
        runtime.preferences = const WorkspacePreferences();
        expect(await runtime.hideWindow(), isTrue);
        await runtime.setNavigationEnabled(false);
        final pages = <WorkspacePage>[];
        runtime.onNavigate = pages.add;
        await runtime.handleEvent(DesktopEvent.windowShown);
        expect(runtime.windowHidden, isFalse);
        expect(runtime.navigationEnabled, isFalse);
        expect(pages, isEmpty);
        expect(native.shows, 0);
      } finally {
        runtime.dispose();
      }
    },
  );
}
