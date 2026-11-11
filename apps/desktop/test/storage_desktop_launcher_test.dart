@TestOn('!windows')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/platform/local_library.dart';
import 'package:info_desktop/storage_desktop_launcher.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_storage/info_storage.dart';

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
  final priorHttp = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = priorHttp);

  testWidgets(
    'existing server settings never silently become a new empty local library',
    (t) async {
      final ui = OnlineUiHarness(t);
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('chiyo-server-mode-'),
      );
      final store = PrivateConnectionProfileStore(root.path);
      await ui.resolve(
        () => store.save(
          ConnectionProfile(
          address: 'https://127.0.0.1:1',
            token: 'synthetic-owner-token',
            serverId: 'existing-server-library',
          ),
        ),
      );
      var localOpens = 0;
      try {
        await t.pumpWidget(
          StorageDesktopLauncher(
            profiles: store,
            platform: NativeDesktopFixture(),
            openLocal: (_, _) async {
              localOpens++;
              throw StateError('Existing server must stay selected');
            },
            localBuilder: (_) => const Text('Unexpected local library'),
          ),
        );
        await ui.until(
          () => find.byType(OnlineDesktopLauncher).evaluate().isNotEmpty,
        );
        expect(localOpens, 0);
        expect(find.text('Unexpected local library'), findsNothing);
        expect(
          await ui.resolve(
            () => File('${root.path}/local-library.json').exists(),
          ),
          false,
        );
      } finally {
        await t.pumpWidget(const SizedBox());
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'empty settings open the real local workspace and preserve UI edits after restart',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('chiyo-local-ui-'),
      );
      final keys = _Keys();
      DesktopBootstrap? boot;
      Widget launcher(int generation) => StorageDesktopLauncher(
        key: ValueKey(generation),
        profiles: PrivateConnectionProfileStore(root.path),
        platform: NativeDesktopFixture(),
        openLocal: (configuration, _) =>
            openLocalLibrary(configuration, keyStore: keys),
        localBuilder: (value) {
          boot = value;
          return DesktopLauncher(bootstrap: value, useWorkspace: true);
        },
      );
      try {
        await t.pumpWidget(launcher(1));
        await ui.until(() => find.byTooltip('添加资料').evaluate().isNotEmpty);
        expect(find.text('本地模式'), findsWidgets);
        await ui.tap('library-create');
        await ui.until(() => find.text('通用资料').evaluate().isNotEmpty);
        await t.tap(find.text('通用资料').last);
        await ui.until(() => ui.key('library-edit-name').evaluate().isNotEmpty);
        Future<void> enter(String id, String value) => t.enterText(
          find.descendant(of: ui.key(id), matching: find.byType(TextField)),
          value,
        );
        await enter('library-edit-name', '本地界面保存');
        await enter('library-edit-body', '合成正文，真实加密保存');
        await ui.tap('library-edit-save');
        await ui.until(
          () => boot!.library!.service.owner.information.length == 1,
        );
        expect(
          boot!.library!.service.owner.information.single.fields.single.value,
          '合成正文，真实加密保存',
        );

        await ui.tap('workspace-nav-settings');
        await ui.tap('settings-section-connection');
        await ui.until(() => find.text('资料保存在本机。').evaluate().isNotEmpty);
        expect(find.text('服务器地址'), findsNothing);
        await t.tap(find.text('返回工作区'));
        await t.pumpAndSettle();
        final previous = boot!;
        await t.pumpWidget(const SizedBox());
        await ui.resolve(previous.close);
        await t.pumpWidget(launcher(2));
        await ui.until(() => find.byTooltip('添加资料').evaluate().isNotEmpty);
        expect(find.text('本地模式'), findsWidgets);
        expect(boot!.library!.service.owner.information.single.name, '本地界面保存');
        expect(
          boot!.library!.service.owner.information.single.fields.single.value,
          '合成正文，真实加密保存',
        );
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (boot != null) await ui.resolve(boot!.close);
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
  );
}
