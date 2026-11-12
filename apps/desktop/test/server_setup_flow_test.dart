import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/platform/local_library.dart';
import 'package:info_desktop/storage_desktop_launcher.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_desktop/local_library_sync.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_core/info_core.dart';
import '../../server/test/support/device_credential_fixture.dart';
import 'support/desktop_platform_fixture.dart';
import 'support/online_ui_harness.dart';

class _RealHttp extends HttpOverrides {}

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

void main() {
  final previousHttp = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = previousHttp);
  testWidgets(
    'local -> first server password -> real sync -> remembered reconnect -> change password',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      final host = await ui.resolve(
        () => DeviceCredentialFixture.create(
          replication: true,
          connectionSetup: true,
        ),
      );
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('chiyo-real-setup-ui-'),
      );
      final keys = _Keys();
      DesktopBootstrap? boot;
      Finder field(String label) => find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is DesktopTextField && w.decoration.labelText == label,
        ),
        matching: find.byType(TextField),
      );
      Future<void> fill(String key, String value) async {
        await ui.until(() => ui.key(key).evaluate().isNotEmpty);
        await t.enterText(
          find.descendant(of: ui.key(key), matching: find.byType(TextField)),
          value,
        );
      }

      try {
        await ui.resolve(
          () => host.runtime.run(
            () => host.runtime.service.owner.createInformation('保留的服务器资料', '', [
              const FieldInput('正文', '', 'SYNTHETIC_SETUP_DATA'),
            ]),
          ),
        );
        await t.pumpWidget(
          StorageDesktopLauncher(
            profiles: PrivateConnectionProfileStore(root.path),
            platform: NativeDesktopFixture(),
            openLocal: (config, _) => openLocalLibrary(config, keyStore: keys),
            localBuilder: (value) {
              boot = value;
              return DesktopLauncher(bootstrap: value, useWorkspace: true);
            },
          ),
        );
        await ui.until(() => ui.key('setup-continue').evaluate().isNotEmpty);
        expect(boot, isNull);
        await ui.tap('setup-continue');
        await ui.until(() => find.byTooltip('添加资料').evaluate().isNotEmpty);
        await ui.tap('workspace-nav-settings');
        await ui.tap('settings-section-connection');
        await ui.until(
          () => ui.key('connection-mode-server').evaluate().isNotEmpty,
        );
        await ui.tap('connection-mode-server');
        await t.enterText(field('服务器 IP 或域名'), host.owner.address.host);
        await t.enterText(field('端口'), '${host.owner.address.port}');
        expect(find.textContaining('已有的管理密码'), findsNothing);
        await ui.tap('connection-save');
        await ui.until(() => find.text('设置知予连接密码').evaluate().isNotEmpty);
        await fill('settings-server-password', 'synthetic-ui-password');
        await fill('settings-server-password-confirm', 'synthetic-ui-password');
        await ui.tap('settings-server-password-save');
        await ui.until(
          () =>
              boot!.library!.service.owner.information.length == 1 &&
              find.textContaining('服务器同步 ·').evaluate().isNotEmpty,
        );
        final configuration = await ui.resolve(
          () => LocalLibraryConfiguration.open(root.path),
        );
        final sync = LocalLibrarySync(
          configuration: configuration,
          owner: boot!.library!.service.owner,
          replication: boot!.library!.replication!,
        );
        var stored = await ui.resolve(sync.readConfiguration);
        final oldToken = (stored['server'] as Map)['token'];
        expect(stored['enabled'], true);
        expect(jsonEncode(stored), isNot(contains('synthetic-ui-password')));
        expect(
          boot!.library!.service.owner.information.single.name,
          '保留的服务器资料',
        );
        await ui.tap('workspace-nav-settings');
        await ui.tap('settings-section-connection');
        await ui.until(
          () => ui.key('connection-mode-local').evaluate().isNotEmpty,
        );
        await ui.tap('connection-mode-local');
        await ui.until(() => find.text('资料保存在这台电脑').evaluate().isNotEmpty);
        await ui.tap('connection-mode-server');
        await ui.tap('connection-save');
        await ui.until(
          () => find.textContaining('服务器同步 ·').evaluate().isNotEmpty,
        );
        expect(ui.key('settings-server-password-confirm'), findsNothing);
        expect(ui.key('settings-server-password'), findsNothing);
        await ui.tap('workspace-nav-settings');
        await ui.tap('settings-section-connection');
        await ui.until(
          () => ui.key('settings-change-password').evaluate().isNotEmpty,
        );
        await ui.tap('settings-change-password');
        await fill('settings-current-password', 'synthetic-ui-password');
        await fill('settings-new-password', 'synthetic-ui-new-password');
        await fill('settings-repeat-password', 'synthetic-ui-new-password');
        await ui.tap('settings-save-password');
        await ui.until(
          () =>
              ui.key('settings-save-password').evaluate().isEmpty &&
              find.textContaining('服务器同步 ·').evaluate().isNotEmpty,
        );
        stored = await ui.resolve(sync.readConfiguration);
        expect((stored['server'] as Map)['token'], isNot(oldToken));
        expect(
          jsonEncode(stored),
          isNot(contains('synthetic-ui-new-password')),
        );
        expect(
          boot!.library!.service.owner.information.single.name,
          '保留的服务器资料',
        );
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (boot != null) await ui.resolve(boot!.close);
        await ui.resolve(host.dispose);
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'first launch can directly connect a new server and reopen its local replica',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      final host = await ui.resolve(
        () => DeviceCredentialFixture.create(
          replication: true,
          connectionSetup: true,
        ),
      );
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('chiyo-first-server-ui-'),
      );
      final keys = _Keys();
      DesktopBootstrap? boot;
      Widget launch() => StorageDesktopLauncher(
        profiles: PrivateConnectionProfileStore(root.path),
        platform: NativeDesktopFixture(),
        openLocal: (config, _) => openLocalLibrary(config, keyStore: keys),
        localBuilder: (value) {
          boot = value;
          return DesktopLauncher(bootstrap: value, useWorkspace: true);
        },
      );
      Future<void> fill(String key, String value) async {
        await ui.until(() => ui.key(key).evaluate().isNotEmpty);
        await t.enterText(
          find.descendant(of: ui.key(key), matching: find.byType(TextField)),
          value,
        );
      }

      try {
        await ui.resolve(
          () => host.runtime.run(
            () => host.runtime.service.owner.createInformation('首次连接保留资料', '', [
              const FieldInput('正文', '', 'SYNTHETIC_FIRST_SERVER'),
            ]),
          ),
        );
        await t.pumpWidget(launch());
        await ui.tap('setup-mode-server');
        await ui.tap('setup-continue');
        for (final entry in {
          '服务器 IP 或域名': host.owner.address.host,
          '端口': '${host.owner.address.port}',
        }.entries) {
          await t.enterText(
            find.descendant(
              of: find.byWidgetPredicate(
                (w) =>
                    w is DesktopTextField &&
                    w.decoration.labelText == entry.key,
              ),
              matching: find.byType(TextField),
            ),
            entry.value,
          );
        }
        await ui.tap('setup-continue');
        await fill('setup-password', 'synthetic-first-server-password');
        await fill('setup-password-confirm', 'synthetic-first-server-password');
        await ui.tap('setup-continue');
        await ui.until(
          () =>
              boot?.library?.service.owner.information.length == 1 &&
              find.byTooltip('添加资料').evaluate().isNotEmpty,
        );
        expect(
          boot!.library!.service.owner.information.single.name,
          '首次连接保留资料',
        );
        final saved = await ui.resolve(
          () => PrivateConnectionProfileStore(root.path).read(),
        );
        expect(saved, isNotNull);
        expect(saved!.certificate, isNotEmpty);
        await t.pumpWidget(const SizedBox());
        await ui.resolve(boot!.close);
        boot = null;
        await t.pumpWidget(launch());
        await ui.until(
          () =>
              boot?.library?.service.owner.information.length == 1 &&
              find.byTooltip('添加资料').evaluate().isNotEmpty,
        );
        expect(ui.key('setup-continue'), findsNothing);
        expect(
          boot!.library!.service.owner.information.single.name,
          '首次连接保留资料',
        );
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (boot != null) await ui.resolve(boot!.close);
        await ui.resolve(host.dispose);
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
