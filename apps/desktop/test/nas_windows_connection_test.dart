import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/connection_profile.dart';
import 'support/desktop_platform_fixture.dart';
import 'support/nas_ui_harness.dart';

class _Http extends HttpOverrides {
  bool disconnected = false;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _NetworkClient(super.createHttpClient(context), this);
}

class _NetworkClient implements HttpClient {
  _NetworkClient(this.inner, this.network);
  final HttpClient inner;
  final _Http network;
  @override
  Duration? get connectionTimeout => inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    if (network.disconnected) {
      throw const SocketException('Synthetic device network disconnect');
    }
    return inner.openUrl(method, url);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected HTTP client operation');
}

class _Profile implements ConnectionProfileStore {
  _Profile(this.value);
  ConnectionProfile value;
  int saves = 0;
  @override
  Future<ConnectionProfile?> read() async => value;
  @override
  Future<void> save(ConnectionProfile profile) async {
    value = profile;
    saves++;
  }
}

void main() {
  const directory = String.fromEnvironment('CHIYO_NAS_PROFILE_DIRECTORY');
  testWidgets(
    'existing NAS: normal launcher rejects wrong Token, CA and server identity, then reconnects',
    (t) async {
      final previousHttp = HttpOverrides.current;
      final network = _Http();
      HttpOverrides.global = network;
      final ui = NasUiHarness(t);
      t.view.physicalSize = const Size(1440, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      Directory? temporary;
      RemoteWorkspaceSource? source;
      try {
        final good = (await ui.resolve(
          () => PrivateConnectionProfileStore(directory).read(),
        ))!;
        final wrongCa = await ui.resolve(() async {
          temporary = await Directory.systemTemp.createTemp(
            'chiyo-untrusted-ca-',
          );
          final openssl =
              Platform.environment['CHIYO_TEST_OPENSSL'] ??
              '${Platform.environment['ProgramFiles']}/Git/usr/bin/openssl.exe';
          final result = await Process.run(openssl, [
            'req',
            '-x509',
            '-newkey',
            'rsa:2048',
            '-nodes',
            '-days',
            '1',
            '-keyout',
            '${temporary!.path}/synthetic.key',
            '-out',
            '${temporary!.path}/synthetic.pem',
            '-subj',
            '/CN=Chiyo unrelated synthetic CA',
            '-addext',
            'basicConstraints=critical,CA:TRUE',
          ]);
          if (result.exitCode != 0) {
            throw StateError('Could not prepare unrelated synthetic CA');
          }
          return File('${temporary!.path}/synthetic.pem').readAsString();
        });
        for (final scenario in [
          (
            name: 'wrong Token',
            profile: ConnectionProfile(
              address: good.address,
              token: 'synthetic-invalid-owner-token',
              serverId: good.serverId,
              certificate: good.certificate,
            ),
            error: 'Token 不正确，请重新填写。',
          ),
          (
            name: 'wrong CA',
            profile: ConnectionProfile(
              address: good.address,
              token: good.token,
              serverId: good.serverId,
              certificate: wrongCa,
            ),
            error: '无法验证服务器证书，请检查证书或连接地址。',
          ),
          (
            name: 'wrong server identity',
            profile: ConnectionProfile(
              address: good.address,
              token: good.token,
              serverId: 'synthetic-wrong-server',
              certificate: good.certificate,
            ),
            error: '服务器身份已变化，请核对服务器地址。',
          ),
        ]) {
          ui.phase = scenario.name;
          final profiles = _Profile(scenario.profile);
          await t.pumpWidget(
            OnlineDesktopLauncher(
              profiles: profiles,
              desktopPlatform: NativeDesktopFixture(),
            ),
          );
          await ui.until(
            () => ui.key('connection-error').evaluate().isNotEmpty,
          );
          expect(find.text(scenario.error), findsOneWidget);
          expect(find.byType(WorkspaceApp), findsNothing);
          expect(profiles.saves, 0);
          await t.pumpWidget(const SizedBox());
        }
        ui.phase = 'unreachable endpoint';
        final profiles = _Profile(
          ConnectionProfile(
            address: 'https://127.0.0.1:9',
            token: good.token,
            serverId: good.serverId,
            certificate: good.certificate,
          ),
        );
        await t.pumpWidget(
          OnlineDesktopLauncher(
            profiles: profiles,
            desktopPlatform: NativeDesktopFixture(),
            deviceFilesDirectory: '$directory/files',
          ),
        );
        await ui.until(() => ui.key('connection-error').evaluate().isNotEmpty);
        expect(find.byType(WorkspaceApp), findsNothing);
        expect(profiles.saves, 0);
        final address = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '服务器地址',
        );
        await t.enterText(address, good.address);
        ui.phase = 'reconnect to original NAS';
        await t.tap(find.widgetWithText(FilledButton, '连接'));
        await ui.until(
          () =>
              find.byType(WorkspaceApp).evaluate().isNotEmpty &&
              find.byType(LibraryPage).evaluate().isNotEmpty,
        );
        source =
            t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
                as RemoteWorkspaceSource;
        final model = t
            .widget<LibraryPage>(find.byType(LibraryPage))
            .controller;
        await ui.until(() => model.loadState == WorkspaceLoad.ready);
        expect(model.failure, isNull);
        expect(model.results!.total, greaterThan(0));
        expect(profiles.saves, 1);
        ui.phase = 'connected App loses network';
        await ui.until(() => model.detail != null);
        final version = model.detail!.version;
        network.disconnected = true;
        await ui.until(
          () => ui.key('online-offline-blocker').evaluate().isNotEmpty,
        );
        expect(find.text('与服务器的连接已断开。'), findsOneWidget);
        expect(profiles.saves, 1);
        ui.phase = 'same App resumes original connection';
        network.disconnected = false;
        await ui.until(
          () => ui.key('online-offline-blocker').evaluate().isEmpty,
        );
        await ui.until(() => model.loadState == WorkspaceLoad.ready);
        expect(model.detail?.version, version);
        expect(profiles.saves, 1);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (source != null) await ui.resolve(source.dispose);
        if (temporary != null) {
          await ui.resolve(() => temporary!.delete(recursive: true));
        }
        HttpOverrides.global = previousHttp;
      }
    },
    skip: !Platform.isWindows || directory.isEmpty,
    variant: TargetPlatformVariant({TargetPlatform.windows}),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
