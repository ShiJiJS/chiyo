import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/macos_desktop_control.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('agent_info_manage/desktop');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'Mac control survives startup and commits only after the library and service close',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mac-control-bootstrap-',
      );
      final directory = Directory('${root.path}/control');
      MacDesktopControlHost? host;
      DesktopBootstrap? bootstrap;
      addTearDown(() async {
        await host?.close();
        bootstrap?.runtime?.dispose();
        bootstrap?.dispose();
        await root.delete(recursive: true);
      });
      var closed = false, terminated = false;
      final service = InformationService.fictional();
      final entered = Completer<void>(), opening = Completer<DesktopLibrary>();
      late String Function() state;
      late Future<void> Function() quit;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'terminate') {
          expect(closed, isTrue);
          expect(
            () => service.agent.openSession('after close'),
            throwsA(isA<AccessFailure>()),
          );
          final receipt = jsonDecode(
            await File('${directory.path}/endpoint.json').readAsString(),
          );
          expect(receipt['exitCommitted'], isTrue);
          terminated = true;
        }
        return {'tray': true, 'notifications': 'enabled'};
      });
      bootstrap = DesktopBootstrap(
        platform: NativeDesktopPlatform(),
        port: 0,
        openAppControl: (readState, requestQuit) async {
          state = readState;
          quit = requestQuit;
          return host = await MacDesktopControlHost.start(
            directory: directory,
            state: state,
            quit: quit,
          );
        },
        openLibrary: () {
          entered.complete();
          return opening.future;
        },
      );
      final starting = bootstrap.start();
      await entered.future;
      expect(state(), 'starting');
      expect(terminated, isFalse);
      expect(
        jsonDecode(
          await File('${directory.path}/endpoint.json').readAsString(),
        )['exitCommitted'],
        isFalse,
      );
      opening.complete(
        DesktopLibrary(
          service: service,
          close: () async {
            closed = true;
          },
        ),
      );
      await starting;
      expect(state(), 'running');
      await quit();
      expect(terminated, isTrue);
      expect(state(), 'exiting');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'optional control failure never blocks library startup or normal quit',
    () async {
      final service = InformationService.fictional();
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'tray': true, 'notifications': 'enabled'},
      );
      final bootstrap = DesktopBootstrap(
        platform: NativeDesktopPlatform(),
        port: 0,
        openAppControl: (_, _) async =>
            throw StateError('synthetic unavailable registry'),
        openLibrary: () async =>
            DesktopLibrary(service: service, close: () async {}),
      );
      await bootstrap.start();
      expect(bootstrap.state, DesktopStartupState.ready);
      await bootstrap.runtime!.quit();
      expect(bootstrap.runtime!.stopped, isTrue);
      bootstrap.runtime!.dispose();
      bootstrap.dispose();
    },
  );

  test('missing control receipt does not prevent native termination', () async {
    var terminated = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      terminated = call.method == 'terminate';
      return null;
    });
    final native = NativeDesktopPlatform()
      ..commitAppControlExit = () async =>
          throw StateError('synthetic disk failure');
    await native.terminate();
    expect(terminated, isTrue);
  });
}
