import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/online_desktop_runtime.dart';

// Send a bounded power message only to this test process's real runner window.
// Does not suspend the computer, broadcast to other apps, or use NAS data.
void sendOwnPowerEvent(int event) {
  final user = DynamicLibrary.open('user32.dll');
  final find = user
      .lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
      >('FindWindowExW');
  final process = user
      .lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetWindowThreadProcessId');
  final send = user
      .lookupFunction<
        IntPtr Function(
          IntPtr,
          Uint32,
          UintPtr,
          IntPtr,
          Uint32,
          Uint32,
          Pointer<UintPtr>,
        ),
        int Function(int, int, int, int, int, int, Pointer<UintPtr>)
      >('SendMessageTimeoutW');
  final name = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final owner = calloc<Uint32>();
  final result = calloc<UintPtr>();
  try {
    var window = 0;
    while (true) {
      window = find(0, window, name, nullptr);
      if (window == 0) throw StateError('Own runner window not found');
      process(window, owner);
      if (owner.value == pid) break;
    }
    expect(send(window, 0x218, event, 0, 3, 1000, result) != 0, true);
  } finally {
    calloc.free(name);
    calloc.free(owner);
    calloc.free(result);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows native resume reaches online reconnect once without quitting',
    (tester) async {
      var resumed = 0, exits = 0;
      final runtime = OnlineDesktopRuntime(
        platform: NativeDesktopPlatform(),
        beforeExit: () async {
          exits++;
        },
        onResume: () async {
          resumed++;
        },
      );
      addTearDown(runtime.dispose);
      await tester.runAsync(() async {
        await runtime.start();
        sendOwnPowerEvent(0x0a); // Power-source change is not a resume.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(resumed, 0);
        sendOwnPowerEvent(0x12); // PBT_APMRESUMEAUTOMATIC.
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (resumed == 0 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(resumed, 1);
        sendOwnPowerEvent(
          0x07,
        ); // User-activity follow-up must not reconnect twice.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(resumed, 1);
        expect(exits, 0);
        expect(runtime.quitting || runtime.resourcesClosed, false);
      });
    },
    skip: !Platform.isWindows,
  );
}
