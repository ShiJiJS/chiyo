@TestOn('windows || mac-os')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/device_credential_batch_host.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/storage_desktop_launcher.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_remote/connection_profile.dart';

import '../../server/test/support/device_credential_fixture.dart';
import 'support/desktop_platform_fixture.dart';
import 'support/online_ui_harness.dart';

class _RealHttp extends HttpOverrides {}

class _Native implements NativeFillDriver {
  int disposals = 0;
  int discoveries = 0;
  @override
  Future<List<NativeFillTarget>> discover({
    required String scope,
    required String appId,
    String? windowId,
  }) async {
    discoveries++;
    return [];
  }

  @override
  Future<PreparedNativeFill> prepare({
    required String scope,
    required String targetId,
    NativeFillTarget? expected,
  }) => throw StateError('Bootstrap must not prepare a password');
  @override
  Future<void> release({
    required String scope,
    required String targetId,
  }) async {}
  @override
  Future<void> dispose() async {
    disposals++;
  }
}

class _Focus implements FocusedFillDriver {
  @override
  Future<PreparedFocusedFill> prepare(FocusedFillApplication application) =>
      throw StateError('No focus fallback');
}

void main() {
  final previousHttp = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = previousHttp);
  testWidgets(
    'the local App bootstrap publishes native capability through its actual local Agent server',
    (tester) async {
      final ui = OnlineUiHarness(tester);
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('native-local-bootstrap-'),
      );
      final native = _Native();
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      DesktopBootstrap? boot;
      try {
        await tester.pumpWidget(
          StorageDesktopLauncher(
            profiles: PrivateConnectionProfileStore(root.path),
            platform: NativeDesktopFixture(),
            nativeFillDriver: native,
            openLocal: (_, _) async =>
                DesktopLibrary(service: service, close: () async {}),
            localBuilder: (value) {
              boot = value;
              return const SizedBox.shrink();
            },
          ),
        );
        await ui.tap('setup-continue');
        await ui.until(() => boot != null);
        await ui.resolve(boot!.start);
        expect(boot!.state, DesktopStartupState.ready);
        final profile = await ui.resolve(() async {
          final file = await AutomaticConnectionStore(root.path).agentFile();
          expect(file, isNotNull);
          return AgentConnectionProfile.read(file!);
        });
        expect(profile.isLocal, true);
        await ui.until(
          () => File(
            '${root.path}/credential-batch-host/endpoint.json',
          ).existsSync(),
        );
        final capability = await ui.resolve(
          () => DeviceCredentialBatchClient(
            profile,
            directory: root,
          ).execute(null, {'command': 'capabilities'}),
        );
        expect(capability['status'], 'ok');
        expect(capability['providers'], contains('native'));
        expect(capability['providers'], isNot(contains('focus')));
        expect(
          capability['capabilities'],
          contains('credential-native-fill.v1'),
        );
        final targets = await ui.resolve(
          () => DeviceCredentialBatchClient(profile, directory: root).execute(
            service.agent.openSession('Synthetic no-focus discovery'),
            {'command': 'native-targets', 'appId': 'synthetic.native'},
          ),
        );
        expect(targets['status'], 'ok');
        expect(targets['targets'], isEmpty);
        expect(native.discoveries, 1);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (boot != null) await ui.resolve(boot!.close);
        await ui.until(() => native.disposals == 1);
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
  );
  for (final available in [false, true]) {
    testWidgets(
      'App bootstrap advertises native only with its actual driver ($available), independently of failed focus startup',
      (tester) async {
        final ui = OnlineUiHarness(tester);
        final fixture = await ui.resolve(DeviceCredentialFixture.create);
        final directory = Directory(
          '${fixture.root.path}/app-native-bootstrap',
        );
        final native = _Native();
        try {
          await ui.resolve(
            () => AutomaticConnectionStore(directory.path).publish(
              ConnectionProfile(
                address: fixture.owner.address.toString(),
                token: fixture.token,
                serverId: fixture.owner.serverId,
                certificate: fixture.certificate,
              ).toJson(),
              fixture.profiles.first,
            ),
          );
          await ui.resolve(
            () => privateDeviceDirectory(
              Directory('${directory.path}/focused-fill-host'),
            ),
          );
          await ui.resolve(
            () => writePrivateDeviceState(
              File('${directory.path}/focused-fill-host/endpoint.json'),
              {'invalid': true},
            ),
          );
          await tester.pumpWidget(
            StorageDesktopLauncher(
              profiles: PrivateConnectionProfileStore(directory.path),
              platform: NativeDesktopFixture(),
              focusedFillDriver: _Focus(),
              openNativeFillDriver: () async => available ? native : null,
              localBuilder: (_) => const SizedBox.shrink(),
            ),
          );
          await ui.until(
            () => File(
              '${directory.path}/credential-batch-host/endpoint.json',
            ).existsSync(),
          );
          final capability = await ui.resolve(
            () => DeviceCredentialBatchClient(
              fixture.profiles.first,
              directory: directory,
            ).execute(null, {'command': 'capabilities'}),
          );
          expect(capability['status'], 'ok');
          expect(
            (capability['providers'] as List).contains('native'),
            available,
          );
          expect(
            (capability['capabilities'] as List).contains(
              'credential-native-fill.v1',
            ),
            available,
          );
          expect(native.disposals, 0);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await ui.resolve(() async {
            for (var i = 0; i < 100; i++) {
              final record = await readPrivateDeviceState(
                File('${directory.path}/credential-batch-host/endpoint.json'),
              );
              if (record?['phase'] == 'closed') break;
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          });
          try {
            expect(native.disposals, available ? 1 : 0);
          } finally {
            await ui.resolve(fixture.dispose);
          }
        }
      },
    );
  }
  testWidgets(
    'an adapter factory completing after App disposal releases its untransferred resident driver',
    (tester) async {
      final ui = OnlineUiHarness(tester);
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('native-late-factory-'),
      );
      final pending = Completer<NativeFillDriver?>();
      final native = _Native();
      try {
        await tester.pumpWidget(
          StorageDesktopLauncher(
            profiles: PrivateConnectionProfileStore(root.path),
            platform: NativeDesktopFixture(),
            openNativeFillDriver: () => pending.future,
            localBuilder: (_) => const SizedBox.shrink(),
          ),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        pending.complete(native);
        await ui.until(() => native.disposals == 1);
        expect(
          File('${root.path}/credential-batch-host/endpoint.json').existsSync(),
          false,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
  );
}
