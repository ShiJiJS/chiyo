@TestOn('!windows')
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/onboarding/setup_configuration.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/settings_page.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_remote/connection_profile.dart';
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
    final b = await ui.resolve(
      () => DeviceCredentialFixture.create(
        connectionPassword: 'synthetic-b-password',
      ),
    );
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
      await ui.until(() => field('服务器 IP 或域名').evaluate().isNotEmpty);
    }

    Future<void> saveError(String text) async {
      await ui.tap('connection-save');
      await ui.until(() => find.text(text).evaluate().isNotEmpty);
      await ui.until(
        () => !t
            .widget<ConnectionSettings>(find.byType(ConnectionSettings))
            .draft
            .busy,
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
      expect(find.text('已记住服务器证书'), findsOneWidget);
      await t.enterText(field('服务器 IP 或域名'), 'not a URL');
      await saveError('请填写服务器 IP 或域名，不需要填写 https://。');
      expect(
        t.widget<DesktopTextField>(field('服务器 IP 或域名')).controller!.text,
        'not a URL',
      );
      await t.tap(find.text('返回信息库'));
      await t.pump();
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
      await t.enterText(field('服务器 IP 或域名'), proxy.address.host);
      await t.enterText(field('端口'), '${proxy.address.port}');
      // A saved connection to an older backend still works without setup API.
      await ui.tap('connection-save');
      await ui.until(
        () => !t
            .widget<ConnectionSettings>(find.byType(ConnectionSettings))
            .draft
            .busy,
      );
      expect(identical(live(), sources.first), isTrue);
      expect(settings.draft!.requestMinutes, 137);
      // Offline settings use the same page and can return without a new runtime.
      await t.tap(find.text('返回信息库'));
      await t.pump();
      proxy.failGetPrefix = '/v1/owner/health';
      await ui.until(
        () => ui.key('online-offline-blocker').evaluate().isNotEmpty,
      );
      await t.tap(find.text('连接设置'));
      await ui.until(() => ui.key('online-offline-blocker').evaluate().isEmpty);
      expect(find.byType(ConnectionSettings), findsOneWidget);
      expect(identical(live(), sources.first), isTrue);
      await t.tap(find.text('返回信息库'));
      await t.pump();
      await ui.until(
        () => ui.key('online-offline-blocker').evaluate().isNotEmpty,
      );
      proxy.failGetPrefix = null;
      await t.tap(find.text('重新连接'));
      await ui.until(() => ui.key('online-offline-blocker').evaluate().isEmpty);
      expect(identical(live(), sources.first), isTrue);
      expect(library.query.keyword, '第一台');
      await open();
      // Hold the real initial sync: old source and saved profile remain active.
      final bproxy = await ui.resolve(
        () => OwnerReplyProxy.start(
          tls: b.tls,
          trust: b.trust,
          target: () => Uri.parse('https://127.0.0.1:${b.server.port}'),
          serverId: b.owner.serverId,
        ),
      );
      try {
        await t.enterText(field('服务器 IP 或域名'), bproxy.address.host);
        await t.enterText(field('端口'), '${bproxy.address.port}');
        expect(
          t.widget<DesktopTextField>(field('服务器 IP 或域名')).controller!.text,
          bproxy.address.host,
        );
        await ui.tap('connection-save');
        await ui.until(
          () => ui.key('settings-server-password').evaluate().isNotEmpty,
        );
        Future<void> password(String value) => t.enterText(
          find.descendant(
            of: ui.key('settings-server-password'),
            matching: find.byType(TextField),
          ),
          value,
        );
        Future<void> submitError(String text) async {
          await ui.tap('settings-server-password-save');
          await ui.until(() => find.text(text).evaluate().isNotEmpty);
          expect(identical(live(), sources.first), isTrue);
          expect(
            (await ui.resolve(profiles.read))!.address,
            proxy.address.toString(),
          );
        }

        await password('wrong-password');
        await submitError('知予连接密码不正确，请重新输入。');
        await password('synthetic-b-password');
        bproxy.failPostPrefix = '/v1/owner/sync';
        await submitError('连接失败，请检查服务器地址和网络后重试。');
        bproxy.failPostPrefix = null;
        profiles.failSave = true;
        await submitError('无法保存本机连接设置，请检查应用的数据目录权限后重试。');
        profiles.failSave = false;
        gate = Completer<void>();
        bproxy.beforeReply = (path) async {
          if (path == '/v1/owner/sync') await gate!.future;
        };
        await ui.tap('settings-server-password-save');
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
        expect(live().client.serverId, b.owner.serverId);
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
