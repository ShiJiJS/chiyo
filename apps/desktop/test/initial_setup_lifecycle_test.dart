@TestOn('windows || mac-os')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart' show DesktopLauncher;
import 'package:info_desktop/onboarding/setup_configuration.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/storage_desktop_launcher.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_remote/private_connection_files.dart';

import 'support/desktop_platform_fixture.dart';
import 'support/online_ui_harness.dart';

class _RealHttp extends HttpOverrides {}

class _Native implements NativeFillDriver {
  int disposals = 0;
  final released = Completer<void>();
  @override
  Future<List<NativeFillTarget>> discover({
    required String scope,
    required String appId,
    String? windowId,
  }) => throw StateError('Setup lifecycle must not discover fields');
  @override
  Future<PreparedNativeFill> prepare({
    required String scope,
    required String targetId,
    NativeFillTarget? expected,
  }) => throw StateError('Setup lifecycle must not prepare input');
  @override
  Future<void> release({
    required String scope,
    required String targetId,
  }) async {}
  @override
  Future<void> dispose() async {
    disposals++;
    await released.future;
  }
}

void main() {
  final previousHttp = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = previousHttp);
  testWidgets(
    'configured local runtime retains close-to-background and normal quit ownership',
    (tester) async {
      final ui = OnlineUiHarness(tester);
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('chiyo-setup-handoff-'),
      );
      final platform = NativeDesktopFixture();
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      DesktopBootstrap? bootstrap;
      var closes = 0;
      try {
        await tester.pumpWidget(
          StorageDesktopLauncher(
            profiles: PrivateConnectionProfileStore(root.path),
            platform: platform,
            openLocal: (_, _) async => DesktopLibrary(
              service: service,
              close: () async {
                closes++;
              },
            ),
            localBuilder: (value) {
              bootstrap = value;
              return DesktopLauncher(bootstrap: value);
            },
          ),
        );
        await ui.tap('setup-continue');
        await ui.until(() => bootstrap?.state == DesktopStartupState.ready);
        await ui.resolve(() => platform.events!(DesktopEvent.closeWindow));
        expect(platform.hidden, true);
        expect(platform.terminated, false);
        expect(closes, 0);
        await ui.resolve(() => platform.events!(DesktopEvent.quit));
        expect(platform.terminated, true);
        expect(closes, 1);
        expect(tester.takeException(), null);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (bootstrap != null) await ui.resolve(bootstrap!.close);
        await ui.resolve(service.close);
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
  );
  for (final event in [DesktopEvent.quit, DesktopEvent.closeWindow]) {
    testWidgets('first-run setup handles $event without creating a library', (
      tester,
    ) async {
      final ui = OnlineUiHarness(tester);
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('chiyo-first-run-exit-'),
      );
      final platform = NativeDesktopFixture();
      var opens = 0;
      try {
        await tester.pumpWidget(
          StorageDesktopLauncher(
            profiles: PrivateConnectionProfileStore(root.path),
            platform: platform,
            openLocal: (_, _) async {
              opens++;
              throw StateError('An unconfigured exit must not open a library');
            },
            localBuilder: (_) => const SizedBox.shrink(),
          ),
        );
        await ui.until(
          () => find.byType(InitialConnectionSetup).evaluate().length == 1,
        );
        expect(platform.events, isNotNull);
        await ui.resolve(() => platform.events!(event));
        expect(platform.terminated, true);
        expect(opens, 0);
        expect(File('${root.path}/local-library.json').existsSync(), false);
        expect(File('${root.path}/local/library.db').existsSync(), false);
        expect(tester.takeException(), null);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await ui.resolve(() => root.delete(recursive: true));
      }
    });
  }

  testWidgets(
    'quit during initial native startup waits without starting profile recovery',
    (tester) async {
      final ui = OnlineUiHarness(tester);
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('chiyo-initial-native-exit-'),
      );
      final initialized = Completer<void>();
      final platform = NativeDesktopFixture()
        ..initialization = initialized.future;
      Future<void>? quitting;
      var opens = 0;
      try {
        await tester.pumpWidget(
          StorageDesktopLauncher(
            profiles: PrivateConnectionProfileStore(root.path),
            platform: platform,
            openLocal: (_, _) async {
              opens++;
              throw StateError('Quit must stop late recovery');
            },
            localBuilder: (_) => const SizedBox.shrink(),
          ),
        );
        await ui.until(() => platform.events != null);
        await tester.runAsync(() async {
          quitting = platform.events!(DesktopEvent.quit);
        });
        await ui.until(() => find.text('正在退出应用…').evaluate().isNotEmpty);
        expect(platform.terminated, false);
        initialized.complete();
        await ui.resolve(() => quitting!);
        expect(platform.terminated, true);
        expect(opens, 0);
        expect(find.byType(InitialConnectionSetup), findsNothing);
        expect(File('${root.path}/local-library.json').existsSync(), false);
      } finally {
        if (!initialized.isCompleted) initialized.complete();
        if (quitting != null) await ui.resolve(() => quitting!);
        await tester.pumpWidget(const SizedBox.shrink());
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'quit during profile recovery waits for its owned library and prevents runtime handoff',
    (tester) async {
      final ui = OnlineUiHarness(tester);
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('chiyo-recovery-exit-'),
      );
      final platform = NativeDesktopFixture();
      final opening = Completer<DesktopLibrary>();
      final entered = Completer<void>(), released = Completer<void>();
      final closing = Completer<void>();
      var closes = 0, handoffs = 0;
      Future<void>? quitting;
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final profiles = PrivateConnectionProfileStore(root.path);
      try {
        await ui.resolve(() async {
          final configuration = await LocalLibraryConfiguration.open(root.path);
          await Directory(configuration.libraryDirectory).create();
          await File(
            '${configuration.libraryDirectory}/library.db',
          ).writeAsString('synthetic marker; openLocal owns test storage');
          await PrivateConnectionFiles.write(
            File('${root.path}/library-sync.json'),
            {'version': 1, 'localLibraryId': configuration.libraryId},
          );
          await profiles.save(
            ConnectionProfile(
              address: 'https://127.0.0.1:1',
              token: 'synthetic-owner-token',
              serverId: 'synthetic-recovery-server',
            ),
          );
        });
        await tester.pumpWidget(
          StorageDesktopLauncher(
            profiles: profiles,
            platform: platform,
            openLocal: (_, _) {
              if (!entered.isCompleted) entered.complete();
              return opening.future;
            },
            localBuilder: (_) {
              handoffs++;
              return const SizedBox.shrink();
            },
          ),
        );
        await ui.until(() => entered.isCompleted);
        expect(platform.events, isNotNull);
        await tester.runAsync(() async {
          quitting = platform.events!(DesktopEvent.quit);
        });
        await tester.pump();
        expect(platform.terminated, false);
        opening.complete(
          DesktopLibrary(
            service: service,
            close: () async {
              closes++;
              if (!closing.isCompleted) closing.complete();
              await released.future;
            },
          ),
        );
        await ui.until(() => closing.isCompleted);
        expect(platform.terminated, false);
        released.complete();
        await ui.resolve(() => quitting!);
        expect(platform.terminated, true);
        expect(closes, 1);
        expect(handoffs, 0);
        expect(find.byType(OnlineDesktopLauncher), findsNothing);
        expect(find.byType(InitialConnectionSetup), findsNothing);
        expect(tester.takeException(), null);
      } finally {
        if (!opening.isCompleted) {
          opening.complete(
            DesktopLibrary(service: service, close: () async {}),
          );
        }
        if (!released.isCompleted) released.complete();
        if (quitting != null) await ui.resolve(() => quitting!);
        await tester.pumpWidget(const SizedBox.shrink());
        await ui.resolve(service.close);
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'setup quit joins a late native factory and its resident disposal',
    (tester) async {
      final ui = OnlineUiHarness(tester);
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('chiyo-first-run-native-exit-'),
      );
      final platform = NativeDesktopFixture();
      final factory = Completer<NativeFillDriver?>();
      final native = _Native();
      Future<void>? quitting;
      try {
        await tester.pumpWidget(
          StorageDesktopLauncher(
            profiles: PrivateConnectionProfileStore(root.path),
            platform: platform,
            openNativeFillDriver: () => factory.future,
            localBuilder: (_) => const SizedBox.shrink(),
          ),
        );
        await ui.until(
          () => find.byType(InitialConnectionSetup).evaluate().length == 1,
        );
        expect(platform.events, isNotNull);
        await tester.runAsync(() async {
          quitting = platform.events!(DesktopEvent.quit);
        });
        await tester.pump();
        expect(platform.terminated, false);
        factory.complete(native);
        await ui.until(() => native.disposals == 1);
        expect(platform.terminated, false);
        native.released.complete();
        await ui.resolve(() => quitting!);
        expect(platform.terminated, true);
        expect(native.disposals, 1);
        expect(
          File('${root.path}/credential-batch-host/endpoint.json').existsSync(),
          false,
        );
      } finally {
        if (!factory.isCompleted) factory.complete(native);
        if (!native.released.isCompleted) native.released.complete();
        if (quitting != null) await ui.resolve(() => quitting!);
        await tester.pumpWidget(const SizedBox.shrink());
        await ui.until(() => native.disposals == 1);
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'quit during initial local selection drains setup without a late library open',
    (tester) async {
      final ui = OnlineUiHarness(tester);
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('chiyo-first-run-select-exit-'),
      );
      final platform = NativeDesktopFixture();
      var opens = 0;
      Future<void>? selecting, quitting;
      try {
        await tester.pumpWidget(
          StorageDesktopLauncher(
            profiles: PrivateConnectionProfileStore(root.path),
            platform: platform,
            openLocal: (_, _) async {
              opens++;
              return DesktopLibrary(
                service: InformationService(
                  repository: MemoryInformationRepository(),
                ),
                close: () async {},
              );
            },
            localBuilder: (_) => const SizedBox.shrink(),
          ),
        );
        await ui.until(
          () => find.byType(InitialConnectionSetup).evaluate().length == 1,
        );
        expect(platform.events, isNotNull);
        final setup = tester
            .widget<InitialConnectionSetup>(find.byType(InitialConnectionSetup))
            .draft;
        await tester.runAsync(() async {
          selecting = setup.useLocal();
          expect(setup.busy, true);
          quitting = platform.events!(DesktopEvent.quit);
        });
        await ui.resolve(() => Future.wait([selecting!, quitting!]));
        expect(setup.busy, false);
        expect(platform.terminated, true);
        expect(opens, 0);
        expect(tester.takeException(), null);
      } finally {
        if (selecting != null) await ui.resolve(() => selecting!);
        if (quitting != null) await ui.resolve(() => quitting!);
        await tester.pumpWidget(const SizedBox.shrink());
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
  );
}
