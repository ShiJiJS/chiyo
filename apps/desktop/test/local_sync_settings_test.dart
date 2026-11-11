@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/platform/local_library.dart';
import 'package:info_desktop/storage_desktop_launcher.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/local_library_sync.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_storage/info_storage.dart';

import '../../server/test/support/device_credential_fixture.dart';
import '../../server/test/support/owner_reply_proxy.dart';
import 'support/desktop_platform_fixture.dart';
import 'support/online_ui_harness.dart';

class _RealHttp extends HttpOverrides {}

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> bytes) async => key = List.of(bytes);
}

void main() {
  final priorHttp = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = priorHttp);
  testWidgets(
    'restart selects a completely admitted local copy without contacting the now stopped NAS',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      final host = await ui.resolve(
        () => DeviceCredentialFixture.create(replication: true),
      );
      final proxy = await ui.resolve(
        () => OwnerReplyProxy.start(
          tls: host.tls,
          trust: host.trust,
          target: () => host.owner.address,
          serverId: host.owner.serverId,
        ),
      );
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('chiyo-admitted-before-switch-'),
      );
      final keys = _Keys();
      DesktopLibrary? preparing;
      DesktopBootstrap? boot;
      var serverClosed = false, dropped = false;
      proxy.beforeReply = (path) async {
        if (!dropped &&
            RegExp(r'/replication/transfers/[A-Za-z0-9_-]+$').hasMatch(path)) {
          dropped = true;
          proxy.dropNextPath = path;
        }
      };
      try {
        await ui.resolve(
          () => host.runtime.run(
            () => host.runtime.service.owner.createInformation(
              '已完整保存的本地副本',
              '',
              [const FieldInput('正文', '', 'SYNTHETIC_ADMITTED_BEFORE_SWITCH')],
            ),
          ),
        );
        final profile = ConnectionProfile(
          address: proxy.address.toString(),
          token: host.token,
          certificate: host.certificate,
          serverId: host.owner.serverId,
        );
        final profiles = PrivateConnectionProfileStore(root.path);
        await ui.resolve(() => profiles.save(profile));
        final config = await ui.resolve(
          () => LocalLibraryConfiguration.open(root.path),
        );
        final preparedLocal = await ui.resolve(
          () => openLocalLibrary(config, keyStore: keys),
        );
        preparing = preparedLocal;
        final sync = LocalLibrarySync(
          configuration: config,
          owner: preparedLocal.service.owner,
          replication: preparedLocal.replication!,
        );
        await ui.resolve(() async {
          await expectLater(
            sync.connect(profile, enabled: false),
            throwsA(isA<RemoteFailure>()),
          );
        });
        expect(dropped, true);
        expect(preparedLocal.service.owner.information, hasLength(1));
        expect(
          (await ui.resolve(sync.readConfiguration))['pending'],
          isNotNull,
        );
        await ui.resolve(preparedLocal.service.close);
        await ui.resolve(preparedLocal.close);
        preparing = null;
        await ui.resolve(host.close);
        serverClosed = true;
        proxy.failGetPrefix = '/v1/';
        final requests = jsonEncode(proxy.requests);
        await t.pumpWidget(
          StorageDesktopLauncher(
            profiles: profiles,
            platform: NativeDesktopFixture(),
            openLocal: (value, _) => openLocalLibrary(value, keyStore: keys),
            localBuilder: (value) {
              boot = value;
              return DesktopLauncher(bootstrap: value, useWorkspace: true);
            },
          ),
        );
        await ui.until(
          () =>
              boot?.state == DesktopStartupState.ready &&
              find.text('已完整保存的本地副本').evaluate().isNotEmpty,
        );
        expect(find.byType(OnlineDesktopLauncher), findsNothing);
        expect(jsonEncode(proxy.requests), requests);
        expect(
          boot!.library!.service.owner.information.single.fields.single.value,
          'SYNTHETIC_ADMITTED_BEFORE_SWITCH',
        );
        expect((await ui.resolve(sync.readConfiguration))['pending'], isNull);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (boot != null) await ui.resolve(boot!.close);
        if (preparing != null) {
          await ui.resolve(preparing.service.close);
          await ui.resolve(preparing.close);
        }
        await ui.resolve(proxy.close);
        if (serverClosed) {
          await ui.resolve(() => host.root.delete(recursive: true));
        } else {
          await ui.resolve(host.dispose);
        }
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
  );
  testWidgets(
    'an existing server workspace waits for its pending work before becoming a persistent local library',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      final host = await ui.resolve(
        () => DeviceCredentialFixture.create(replication: true),
      );
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('chiyo-online-adoption-ui-'),
      );
      final keys = _Keys();
      final profiles = PrivateConnectionProfileStore(root.path);
      DesktopBootstrap? boot;
      Widget app(int generation) => StorageDesktopLauncher(
        key: ValueKey(generation),
        profiles: profiles,
        platform: NativeDesktopFixture(),
        openLocal: (config, _) => openLocalLibrary(config, keyStore: keys),
        localBuilder: (value) {
          boot = value;
          return DesktopLauncher(bootstrap: value, useWorkspace: true);
        },
      );
      try {
        final item = await ui.resolve(
          () => host.runtime.run(
            () => host.runtime.service.owner.createInformation('原服务器完整资料', '', [
              const FieldInput('正文', '', 'SYNTHETIC_EXISTING_SERVER'),
            ]),
          ),
        );
        final request = await ui.resolve(
          () => host.runtime.run(() async {
            final chat = host.runtime.service.agent.openSession('原服务器待审批');
            return host.runtime.service.agent.request(chat, '合成未处理申请', [
              FieldRef(item.id, item.fields.single.id),
            ]);
          }),
        );
        await ui.resolve(
          () => profiles.save(
            ConnectionProfile(
              address: host.owner.address.toString(),
              token: host.token,
              certificate: host.certificate,
              serverId: host.owner.serverId,
            ),
          ),
        );
        await t.pumpWidget(app(1));
        await ui.until(() => find.text('原服务器完整资料').evaluate().isNotEmpty);
        expect(find.byType(OnlineDesktopLauncher), findsOneWidget);
        await ui.tap('workspace-nav-settings');
        await ui.tap('settings-section-connection');
        await ui.tap('connection-mode-local');
        await ui.until(
          () => find
              .text('请先处理服务器上的访问申请和录入提案，再切换到本地资料库。待办不会自动转到本机。')
              .evaluate()
              .isNotEmpty,
        );
        expect(boot, isNull);
        expect(keys.key, isNull);
        await ui.resolve(
          () => host.runtime.run(
            () async => host.runtime.service.owner.deny(request.id),
          ),
        );
        await ui.tap('connection-mode-local');
        await ui.until(
          () =>
              boot?.state == DesktopStartupState.ready &&
              find.text('原服务器完整资料').evaluate().isNotEmpty,
        );
        expect(find.byType(OnlineDesktopLauncher), findsNothing);
        expect(boot!.library!.service.owner.information.single.id, item.id);
        expect(find.text('本地模式'), findsWidgets);
        final previous = boot!;
        await t.pumpWidget(const SizedBox());
        await ui.resolve(previous.close);
        await t.pumpWidget(app(2));
        await ui.until(
          () =>
              boot?.state == DesktopStartupState.ready &&
              find.text('原服务器完整资料').evaluate().isNotEmpty,
        );
        expect(find.byType(OnlineDesktopLauncher), findsNothing);
        expect(
          boot!.library!.service.owner.information.single.fields.single.value,
          'SYNTHETIC_EXISTING_SERVER',
        );
        expect(host.repo.items.single.id, item.id);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (boot != null) await ui.resolve(boot!.close);
        await ui.resolve(host.dispose);
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
  );
  testWidgets(
    'local and server modes reconnect, survive restart, and disable synchronization while offline',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      final host = await ui.resolve(
        () => DeviceCredentialFixture.create(replication: true),
      );
      final proxy = await ui.resolve(
        () => OwnerReplyProxy.start(
          tls: host.tls,
          trust: host.trust,
          target: () => host.owner.address,
          serverId: host.owner.serverId,
        ),
      );
      final root = await ui.resolve(
        () => Directory.systemTemp.createTemp('chiyo-sync-settings-ui-'),
      );
      final keys = _Keys();
      DesktopBootstrap? boot;
      var serverClosed = false;
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is DesktopTextField && w.decoration.labelText == label,
      );
      try {
        await ui.resolve(
          () => host.runtime.run(
            () => host.runtime.service.owner.createInformation('服务器合成资料', '', [
              const FieldInput('正文', '', 'SYNTHETIC_STORAGE_SETTINGS'),
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
        await ui.until(() => find.byTooltip('添加资料').evaluate().isNotEmpty);
        await ui.tap('workspace-nav-settings');
        await ui.tap('settings-section-connection');
        await ui.until(() => ui.key('connection-mode').evaluate().isNotEmpty);
        expect(field('服务器地址'), findsNothing);
        await ui.tap('connection-mode-server');
        await ui.until(() => field('服务器地址').evaluate().isNotEmpty);
        await t.enterText(field('服务器地址'), proxy.address.toString());
        await t.enterText(field('Token'), 'synthetic-invalid-token');
        await t.tap(find.text('服务器证书'));
        await t.pumpAndSettle();
        await t.enterText(field('服务器 CA 证书'), host.certificate);
        await ui.tap('connection-save');
        await ui.until(
          () => find.text('Token 不正确，请重新填写。').evaluate().isNotEmpty,
        );
        expect(ui.key('workspace-storage-mode'), findsOneWidget);
        final configuration = await ui.resolve(
          () => LocalLibraryConfiguration.open(root.path),
        );
        final sync = LocalLibrarySync(
          configuration: configuration,
          owner: boot!.library!.service.owner,
          replication: boot!.library!.replication!,
        );
        expect((await ui.resolve(sync.readConfiguration))['enabled'], false);
        await t.enterText(field('Token'), host.token);
        await ui.tap('connection-save');
        await ui.until(
          () => boot!.library!.service.owner.information.isNotEmpty,
        );
        await ui.until(
          () => find.textContaining('服务器同步 ·').evaluate().isNotEmpty,
        );
        expect(ui.key('workspace-storage-mode'), findsNothing);
        await ui.until(
          () => ui
              .key('workspace-nav-library')
              .hitTestable()
              .evaluate()
              .isNotEmpty,
        );
        await ui.tap('workspace-nav-library');
        await ui.until(() => find.text('服务器合成资料').evaluate().isNotEmpty);
        expect(
          boot!.library!.service.owner.information.first.fields.single.value,
          'SYNTHETIC_STORAGE_SETTINGS',
        );
        expect(host.repo.items, hasLength(1));
        await ui.tap('workspace-nav-settings');
        await ui.tap('settings-section-connection');
        await ui.tap('connection-mode-local');
        await ui.until(
          () => ui.key('workspace-storage-mode').evaluate().isNotEmpty,
        );
        expect(ui.key('connection-save'), findsNothing);
        expect((await ui.resolve(sync.readConfiguration))['enabled'], false);
        await ui.resolve(
          () => host.runtime.run(
            () => host.runtime.service.owner.createInformation('停用同步期间新增', '', [
              const FieldInput('正文', '', 'SYNTHETIC_RECONNECTED'),
            ]),
          ),
        );
        await ui.tap('connection-mode-server');
        expect(field('服务器地址'), findsOneWidget);
        expect((await ui.resolve(sync.readConfiguration))['enabled'], false);
        await ui.tap('connection-save');
        await ui.until(
          () =>
              boot!.library!.service.owner.information.length == 2 &&
              find.textContaining('服务器同步 ·').evaluate().isNotEmpty,
        );
        expect((await ui.resolve(sync.readConfiguration))['enabled'], true);
        expect(ui.key('workspace-storage-mode'), findsNothing);
        final originalLibrary = configuration.libraryId;
        final previous = boot!;
        await t.pumpWidget(const SizedBox());
        await ui.resolve(previous.close);
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
        await ui.until(
          () =>
              boot!.state == DesktopStartupState.ready &&
              find.textContaining('服务器同步 ·').evaluate().isNotEmpty,
        );
        expect(boot!.library!.service.owner.information, hasLength(2));
        expect(
          (await ui.resolve(
            () => LocalLibraryConfiguration.open(root.path),
          )).libraryId,
          originalLibrary,
        );
        expect(ui.key('workspace-storage-mode'), findsNothing);
        await ui.resolve(host.close);
        serverClosed = true;
        await ui.resolve(() async {
          final found = (await discoverAgentConnection(
            environment: {'CHIYO_CONNECTION_DIRECTORY': root.path},
          ))!;
          final profile = await AgentConnectionProfile.read(found);
          expect(profile.isLocal, true);
          final client = AgentClient.remote(
            profile,
            requireSubmissionMetadata: true,
          );
          try {
            await client.execute({
              'command': 'session',
              'chatLabel': '服务器关闭后的本机申请',
              'externalChatId': 'offline-local-synthetic',
            });
            final info = boot!.library!.service.owner.information.first;
            final ref = FieldRef(info.id, info.fields.single.id);
            final request = await client.execute({
              'command': 'request',
              'operationId': 'offline-local-read',
              'agentName': '本地验收 Agent',
              'purpose': '关闭服务器后核对本地资料',
              'fields': [ref.toJson()],
            });
            expect(request['status'], 'pending');
            boot!.library!.service.owner.approve(
              request['requestId'] as String,
              [ref],
            );
            expect(
              (await client.execute({
                'command': 'claim',
                'requestId': request['requestId'],
              }))['status'],
              'ok',
            );
            expect(
              (await client.execute({
                'command': 'read',
                'requestId': request['requestId'],
                'itemId': info.id,
                'fieldId': info.fields.single.id,
              }))['value'],
              'SYNTHETIC_STORAGE_SETTINGS',
            );
          } finally {
            client.close();
          }
        });
        await ui.tap('workspace-nav-settings');
        await ui.tap('settings-section-connection');
        await ui.until(
          () =>
              ui.key('connection-mode').evaluate().isNotEmpty &&
              field('服务器地址').evaluate().isNotEmpty,
        );
        proxy.failGetPrefix = '/v1/';
        final requests = jsonEncode(proxy.requests);
        await ui.tap('connection-mode-local');
        await ui.until(
          () =>
              find.text('本地模式').evaluate().isNotEmpty &&
              field('服务器地址').evaluate().isEmpty &&
              ui.key('connection-save').evaluate().isEmpty,
        );
        expect(jsonEncode(proxy.requests), requests);
        expect(boot!.library!.service.owner.information, hasLength(2));
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (boot != null) await ui.resolve(boot!.close);
        await ui.resolve(proxy.close);
        if (serverClosed) {
          await ui.resolve(() => host.root.delete(recursive: true));
        } else {
          await ui.resolve(host.dispose);
        }
        await ui.resolve(() => root.delete(recursive: true));
      }
    },
  );
}
