@TestOn('!windows')
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/connection_view.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/settings_page.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/online_server.dart';
import '../../server/test/support/device_credential_fixture.dart';
import '../../server/test/support/owner_reply_proxy.dart';
import 'support/desktop_platform_fixture.dart';
import 'support/online_ui_harness.dart';

class _Http extends HttpOverrides {}

class _Profiles implements ConnectionProfileStore {
  _Profiles(this.real);
  final PrivateConnectionProfileStore real;
  bool failSave = false;
  @override
  Future<ConnectionProfile?> read() => real.read();
  @override
  Future<void> save(ConnectionProfile p) {
    if (failSave) throw const FileSystemException('Synthetic denied write');
    return real.save(p);
  }
}

class _Native extends NativeDesktopFixture {
  int starts = 0;
  @override
  Future<DesktopAvailability> initialize(
    Future<void> Function(DesktopEvent) onEvent,
  ) {
    starts++;
    return super.initialize(onEvent);
  }
}

void main() {
  final prior = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _Http());
  tearDownAll(() => HttpOverrides.global = prior);
  testWidgets('connection drafts are transactional across two real HTTPS servers', (
    t,
  ) async {
    t.view.physicalSize = const Size(1500, 1100);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final ui = OnlineUiHarness(t);
    final a = await ui.resolve(DeviceCredentialFixture.create);
    final b = await ui.resolve(DeviceCredentialFixture.create);
    final proxy = await ui.resolve(
      () => OwnerReplyProxy.start(
        tls: a.tls,
        trust: a.trust,
        target: () => a.owner.address,
        serverId: a.owner.serverId,
      ),
    );
    final profiles = _Profiles(
      PrivateConnectionProfileStore('${a.root.path}/app-profile'),
    );
    final native = _Native();
    final sources = <RemoteWorkspaceSource>[];
    Completer<void>? gate;
    Finder field(String name) => find.byWidgetPredicate(
      (w) => w is DesktopTextField && w.decoration.labelText == name,
    );
    RemoteWorkspaceSource live() =>
        t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
            as RemoteWorkspaceSource;
    Future<void> open() async {
      await ui.tap('workspace-nav-settings');
      await ui.tap('settings-section-connection');
      await ui.until(() => field('服务器地址').evaluate().isNotEmpty);
    }

    Future<void> saveError(String text) async {
      await ui.tap('connection-save');
      await ui.until(() => find.text(text).evaluate().isNotEmpty);
      await ui.until(
        () => !t.widget<ConnectionForm>(find.byType(ConnectionForm)).busy,
      );
      expect(identical(live(), sources.first), isTrue);
      expect(
        (await ui.resolve(profiles.read))!.address,
        proxy.address.toString(),
      );
    }

    try {
      await ui.resolve(() async {
        await a.runtime.run(
          () => a.runtime.service.owner.createInformation('第一台资料', '', [
            const core.FieldInput('内容', '', 'First body'),
          ]),
        );
        await b.runtime.run(
          () => b.runtime.service.owner.createInformation('第二台资料', '', [
            const core.FieldInput('内容', '', 'Second body'),
          ]),
        );
        await b.server.close();
        b.server = await OnlineServer.start(
          runtime: b.runtime,
          devices: AgentDeviceRegistry(b.repo),
          tls: b.tls,
          ownerToken: b.token,
          serverId: 'synthetic-second-connection',
        );
        await profiles.save(
          ConnectionProfile(
            address: proxy.address.toString(),
            token: a.token,
            certificate: a.certificate,
            serverId: a.owner.serverId,
          ),
        );
      });
      await t.pumpWidget(
        OnlineDesktopLauncher(
          profiles: profiles,
          desktopPlatform: native,
          deviceFilesDirectory: '${a.root.path}/app-files',
        ),
      );
      await ui.until(() => find.byType(LibraryPage).evaluate().isNotEmpty);
      final library = t
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller;
      sources.add(live());
      expect(find.byTooltip('连接设置'), findsNothing);
      await t.enterText(find.byKey(const ValueKey('library-search')), '第一台');
      await ui.until(() => library.query.keyword == '第一台');
      final selection = library.selection;
      await open();
      final settings = t
          .widget<WorkspaceSettingsPage>(find.byType(WorkspaceSettingsPage))
          .controller;
      await ui.until(() => settings.draft != null);
      settings.stage(settings.draft!.copyWith(requestMinutes: 137));
      expect(find.text('已核验'), findsOneWidget);
      await t.enterText(field('服务器地址'), 'not a URL');
      await saveError('请填写完整的 HTTPS 服务器地址和 Token。');
      expect(
        t.widget<DesktopTextField>(field('服务器地址')).controller!.text,
        'not a URL',
      );
      await ui.tap('connection-cancel');
      await ui.until(() => find.byType(LibraryPage).evaluate().isNotEmpty);
      expect(
        identical(
          t.widget<LibraryPage>(find.byType(LibraryPage)).controller,
          library,
        ),
        isTrue,
      );
      expect(library.query.keyword, '第一台');
      expect(library.selection, selection);
      expect(settings.draft!.requestMinutes, 137);
      expect(settings.dirty, isTrue);
      await open();
      await t.enterText(field('服务器地址'), proxy.address.toString());
      await t.enterText(field('Token'), 'invalid-synthetic-token');
      await saveError('Token 不正确，请重新填写。');
      await t.enterText(field('Token'), a.token);
      await t.tap(find.text('服务器证书'));
      await t.pumpAndSettle();
      await t.enterText(field('服务器 CA 证书'), b.certificate);
      await saveError('无法验证服务器证书，请检查证书或连接地址。');
      expect(find.text('核验失败'), findsOneWidget);
      await t.enterText(field('服务器 CA 证书'), 'not a certificate');
      await saveError('证书格式不正确，请填写 PEM 格式的 CA 证书。');
      await t.enterText(
        field('服务器 CA 证书'),
        '${a.certificate}\n${b.certificate}',
      );
      // A healthy handshake is insufficient if the initial projection fails.
      proxy.failPostPrefix = '/v1/owner/sync';
      await saveError('连接失败，请检查服务器地址、Token 和网络后重试。');
      proxy.failPostPrefix = null;
      await t.enterText(field('服务器 CA 证书'), a.certificate);
      await ui.tap('connection-save');
      await ui.until(
        () => !t.widget<ConnectionForm>(find.byType(ConnectionForm)).busy,
      );
      expect(identical(live(), sources.first), isTrue);
      expect(settings.draft!.requestMinutes, 137);
      // Offline settings use the same page and can return without a new runtime.
      await ui.tap('connection-cancel');
      proxy.failGetPrefix = '/v1/owner/health';
      await ui.until(
        () => ui.key('online-offline-blocker').evaluate().isNotEmpty,
      );
      await t.tap(find.text('连接设置'));
      await ui.until(() => ui.key('online-offline-blocker').evaluate().isEmpty);
      expect(find.byType(ConnectionForm), findsOneWidget);
      expect(identical(live(), sources.first), isTrue);
      await ui.tap('connection-cancel');
      await ui.until(
        () => ui.key('online-offline-blocker').evaluate().isNotEmpty,
      );
      proxy.failGetPrefix = null;
      await t.tap(find.text('重新连接'));
      await ui.until(() => ui.key('online-offline-blocker').evaluate().isEmpty);
      expect(identical(live(), sources.first), isTrue);
      expect(library.query.keyword, '第一台');
      await open();
      await t.enterText(field('服务器地址'), 'https://127.0.0.1:${b.server.port}');
      await t.enterText(field('Token'), b.token);
      await t.tap(find.text('服务器证书'));
      await t.pumpAndSettle();
      await t.enterText(field('服务器 CA 证书'), b.certificate);
      profiles.failSave = true;
      await saveError('无法保存本机连接设置，请检查应用的数据目录权限后重试。');
      profiles.failSave = false;
      // Hold the real initial sync: old source and saved profile remain active.
      final bproxy = await ui.resolve(
        () => OwnerReplyProxy.start(
          tls: b.tls,
          trust: b.trust,
          target: () => Uri.parse('https://127.0.0.1:${b.server.port}'),
          serverId: 'synthetic-second-connection',
        ),
      );
      try {
        await t.enterText(field('服务器地址'), bproxy.address.toString());
        expect(
          t.widget<DesktopTextField>(field('服务器地址')).controller!.text,
          bproxy.address.toString(),
        );
        gate = Completer<void>();
        bproxy.beforeReply = (path) async {
          if (path == '/v1/owner/sync') await gate!.future;
        };
        await ui.tap('connection-save');
        await ui.until(() => (bproxy.requests['POST /v1/owner/sync'] ?? 0) > 0);
        expect(identical(live(), sources.first), isTrue);
        expect(
          (await ui.resolve(profiles.read))!.address,
          proxy.address.toString(),
        );
        expect(find.byType(CircularProgressIndicator), findsWidgets);
        gate.complete();
        await ui.until(() => live() != sources.first);
        sources.add(live());
        await ui.until(() => find.text('第二台资料').evaluate().isNotEmpty);
        expect(find.text('第一台资料'), findsNothing);
        expect(live().client.serverId, 'synthetic-second-connection');
        expect(
          (await ui.resolve(profiles.read))!.address,
          bproxy.address.toString(),
        );
        expect(native.starts, 1);
        expect(a.runtime.service.owner.information.single.name, '第一台资料');
        expect(b.runtime.service.owner.information.single.name, '第二台资料');
        await t.pumpWidget(const SizedBox());
        for (final s in sources) {
          await ui.resolve(s.dispose);
        }
      } finally {
        await ui.resolve(bproxy.close);
      }
      expect(t.takeException(), isNull);
    } finally {
      if (gate != null && !gate.isCompleted) gate.complete();
      await t.pumpWidget(const SizedBox());
      for (final s in sources) {
        await ui.resolve(s.dispose);
      }
      await ui.resolve(proxy.close);
      await ui.resolve(a.dispose);
      await ui.resolve(b.dispose);
    }
  });
}
