import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/bundled_focused_fill.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'support/desktop_platform_fixture.dart';

const _digest =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

class _Discovery implements FocusedFillDiscoveryDriver {
  int inspections = 0;
  @override
  Future<FocusedFillTarget> inspectTarget() async {
    inspections++;
    return const FocusedFillTarget.refused('unsupported_target');
  }

  @override
  Future<PreparedFocusedFill> prepare(FocusedFillApplication application) =>
      throw StateError('No input is allowed in this discovery test.');
}

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final priorHttp = HttpOverrides.current;
  // These are actual 127.0.0.1 bootstrap tests; no external HTTP is used.
  setUpAll(() => HttpOverrides.global = _LoopbackHttpOverrides());
  tearDownAll(() => HttpOverrides.global = priorHttp);
  late Directory directory;
  late File helper;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('aim-bundle-test-');
    helper = await File(
      '${directory.path}/info-focus-broker.exe',
    ).writeAsString('abc');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  Future<Object?> identity() async => {
    'executable': helper.path,
    'sha256': _digest,
  };
  Future<FocusedFillDriver> load([Future<Object?> Function()? read]) =>
      loadBundledFocusedFill(
        applicationExecutable: '${directory.path}/info_desktop.exe',
        readIdentity: read ?? identity,
      );

  test(
    'native method returns a build-bound sibling identity without focusing or starting input',
    () async {
      const channel = MethodChannel('agent_info_manage/desktop');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            expect(call.arguments, isNull);
            return identity();
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final driver = await loadBundledFocusedFill(
        applicationExecutable: '${directory.path}/info_desktop.exe',
      );
      expect(
        driver.helper.executable.toLowerCase(),
        (await helper.resolveSymbolicLinks()).toLowerCase(),
      );
      expect(driver.helper.sha256, _digest);
      expect(calls, ['focusedFillHelper']);
    },
    skip: !Platform.isWindows,
  );
  for (final bad in [
    null,
    'not a map',
    <String, Object?>{},
    {'executable': r'C:\Outside\info-focus-broker.exe', 'sha256': 'invalid'},
    {
      'executable': r'C:\Outside\info-focus-broker.exe',
      'sha256': _digest,
      'extra': true,
    },
  ]) {
    test(
      'malformed native identity fails closed: ${bad.runtimeType} ${bad.toString().length}',
      () async {
        await expectLater(
          load(() async => bad),
          throwsA(isA<FocusedFillBundleFailure>()),
        );
      },
    );
  }
  test(
    'missing, changed and out-of-directory helpers are rejected before execution',
    () async {
      final valid = await identity() as Map<String, Object?>;
      await helper.writeAsString('abd');
      await expectLater(load(), throwsA(isA<FocusedFillBundleFailure>()));
      await helper.delete();
      await expectLater(load(), throwsA(isA<FocusedFillBundleFailure>()));
      final sub = await Directory('${directory.path}/elsewhere').create();
      final outside = await File(
        '${sub.path}/info-focus-broker.exe',
      ).writeAsString('abc');
      await expectLater(
        load(() async => {...valid, 'executable': outside.path}),
        throwsA(isA<FocusedFillBundleFailure>()),
      );
    },
  );
  test(
    'driver rechecks the bundled bytes after startup before creating a child',
    () async {
      final driver = await loadBundledFocusedFill(
        applicationExecutable: '${directory.path}/info_desktop.exe',
        readIdentity: identity,
      );
      await helper.writeAsString('different');
      await expectLater(
        driver.inspectTarget(),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'application_changed',
          ),
        ),
      );
    },
    skip: !Platform.isWindows,
  );
  test(
    'bundle failure starts no library/server and a repaired retry clears the failure',
    () async {
      var attempts = 0, closed = false;
      final bootstrap = DesktopBootstrap(
        port: 0,
        platform: NativeDesktopFixture(),
        openLibrary: () async {
          if (attempts++ == 0) throw const FocusedFillBundleFailure();
          return DesktopLibrary(
            service: InformationService(
              repository: MemoryInformationRepository(),
            ),
            close: () async {
              closed = true;
            },
          );
        },
      );
      addTearDown(() async {
        await bootstrap.runtime?.stop();
        bootstrap.dispose();
      });
      await bootstrap.start();
      expect(bootstrap.state, DesktopStartupState.failed);
      expect(bootstrap.applicationFilesInvalid, isTrue);
      expect(bootstrap.library, isNull);
      expect(bootstrap.boundPort, isNull);
      await bootstrap.start();
      expect(bootstrap.state, DesktopStartupState.ready);
      expect(bootstrap.applicationFilesInvalid, isFalse);
      await bootstrap.runtime!.stop();
      expect(closed, isTrue);
    },
  );
  for (final enabled in [false, true]) {
    test(
      'bootstrap advertises focused target only on Windows with a configured driver: $enabled',
      () async {
        final driver = _Discovery();
        final service = InformationService(
          repository: MemoryInformationRepository(),
          focusedFillDriver: enabled ? driver : null,
        );
        final bootstrap = DesktopBootstrap(
          port: 0,
          platform: NativeDesktopFixture(),
          openLibrary: () async =>
              DesktopLibrary(service: service, close: () async {}),
        );
        await bootstrap.start();
        expect(bootstrap.state, DesktopStartupState.ready);
        final client = AgentClient(bootstrap.boundPort!);
        addTearDown(() async {
          client.close();
          await bootstrap.runtime?.stop();
          bootstrap.dispose();
        });
        final capabilities =
            (await client.execute({'command': 'capabilities'}))['capabilities']
                as List;
        final supported = Platform.isWindows && enabled;
        expect(capabilities.contains('credential-focused-fill.v1'), supported);
        expect(
          capabilities.contains('credential-focused-target.v1'),
          supported,
        );
        await client.execute({
          'command': 'session',
          'chatLabel': 'Synthetic bundle capability',
        });
        final result = await client.execute({'command': 'focus-target'});
        expect(driver.inspections, supported ? 1 : 0);
        if (supported) {
          expect(result['targetState'], 'refused');
        } else {
          expect(result['errorCode'], 'unsupported_capability');
        }
        expect(service.owner.credentialUseRequests, isEmpty);
      },
    );
  }
}
