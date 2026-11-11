import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/platform/local_library.dart';
import 'package:info_desktop/local_library_sync.dart';
import 'package:info_desktop/storage_desktop_launcher.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/device_credential_fixture.dart';
import 'support/desktop_platform_fixture.dart';
import 'support/online_ui_harness.dart';

class _Http extends HttpOverrides {}

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

void main() {
  final previous = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _Http());
  tearDownAll(() => HttpOverrides.global = previous);
  testWidgets('server inbox and CLI follow mode without moving old requests', (
    t,
  ) async {
    t.view.physicalSize = const Size(1600, 1100);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final ui = OnlineUiHarness(t);
    final server = await ui.resolve(
      () => DeviceCredentialFixture.create(replication: true),
    );
    final root = await ui.resolve(
      () => Directory.systemTemp.createTemp('chiyo-mode-inbox-'),
    );
    final keys = _Keys();
    DesktopBootstrap? boot;
    DesktopLibrary? preparing;
    var serverStopped = false;
    WorkspaceSource source() =>
        t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source;
    Future<AgentConnectionProfile> cliTarget() => ui.resolve(
      () async => AgentConnectionProfile.read(
        (await discoverAgentConnection(
          environment: {'CHIYO_CONNECTION_DIRECTORY': root.path},
        ))!,
      ),
    );
    Future<void> settings() async {
      await ui.tap('workspace-nav-settings');
      await ui.tap('settings-section-connection');
      await ui.until(() => ui.key('connection-mode').evaluate().isNotEmpty);
    }

    Future<void> approvals(String title) async {
      await ui.until(
        () => ui
            .key('workspace-nav-approvals')
            .hitTestable()
            .evaluate()
            .isNotEmpty,
      );
      await ui.tap('workspace-nav-approvals');
      await ui.until(() => find.text(title).evaluate().isNotEmpty);
    }

    Widget launcher(int generation) => StorageDesktopLauncher(
      key: ValueKey(generation),
      profiles: PrivateConnectionProfileStore(root.path),
      platform: NativeDesktopFixture(),
      openLocal: (config, _) => openLocalLibrary(config, keyStore: keys),
      localBuilder: (value) {
        boot = value;
        return DesktopLauncher(bootstrap: value, useWorkspace: true);
      },
    );
    try {
      final item = await ui.resolve(
        () => server.runtime.run(
          () => server.runtime.service.owner.createInformation('同步合成资料', '', [
            const FieldInput('正文', '', 'SYNTHETIC_MODE_SCOPE'),
          ]),
        ),
      );
      final field = FieldRef(item.id, item.fields.single.id);
      final serverChat = server.runtime.service.agent.openSession('NAS 模式验收');
      final nasRequest = await ui.resolve(
        () => server.runtime.run(
          () async => server.runtime.service.agent.request(
            serverChat,
            'NAS 待审批合成请求',
            [field],
          ),
        ),
      );
      final config = await ui.resolve(
        () => LocalLibraryConfiguration.open(root.path),
      );
      preparing = await ui.resolve(
        () => openLocalLibrary(config, keyStore: keys),
      );
      await ui.resolve(
        () =>
            LocalLibrarySync(
              configuration: config,
              owner: preparing!.service.owner,
              replication: preparing.replication!,
            ).connect(
              ConnectionProfile(
                address: server.owner.address.toString(),
                token: server.token,
                certificate: server.certificate,
                serverId: server.owner.serverId,
              ),
            ),
      );
      await ui.resolve(preparing!.service.close);
      await ui.resolve(preparing.close);
      preparing = null;
      await t.pumpWidget(launcher(1));
      await ui.until(
        () => find.textContaining('服务器同步 ·').evaluate().isNotEmpty,
      );
      await approvals('NAS 待审批合成请求');
      expect((await cliTarget()).isLocal, false);
      expect(
        (await ui.resolve(
          () => AgentConnectionProfile.read(
            File('${root.path}/agent-connection.json'),
          ),
        )).isLocal,
        false,
      );
      expect(
        boot!.library!.service.owner.queryInbox(limit: 10).pendingCount,
        0,
      );
      await ui.tap('approval-approve');
      await ui.until(
        () =>
            server.runtime.service.owner.queryInbox(limit: 10).pendingCount ==
            0,
      );
      expect(
        (await ui.resolve(
          () => source().grantHistory.query(const WorkspaceGrantQuery()),
        )).items.any((row) => row.requestId == nasRequest.id),
        true,
      );
      final local = boot!.library!.service;
      final nasProposal = await ui.resolve(
        () => server.runtime.run(
          () => server.runtime.service.agent.submitImport(
            serverChat,
            [
              ImportItemInput('NAS 合成新资料', '', [
                const FieldInput('正文', '', 'NAS_PROPOSAL'),
              ]),
            ],
            title: 'NAS 独立录入提案',
            purpose: '只在 NAS 审批',
          ),
        ),
      );
      final localProposalChat = local.agent.openSession('本机提案验收');
      final localProposal = await ui.resolve(
        () => local.agent.submitImport(
          localProposalChat,
          [
            ImportItemInput('本机合成新资料', '', [
              const FieldInput('正文', '', 'LOCAL_PROPOSAL'),
            ]),
          ],
          title: '本机独立录入提案',
          purpose: '只在本机审批',
        ),
      );
      final serverProposals = await ui.resolve(
        () => source().proposals.query(const WorkspaceProposalQuery()),
      );
      expect(serverProposals.items.any((row) => row.id == nasProposal), true);
      expect(
        serverProposals.items.any((row) => row.id == localProposal),
        false,
      );

      final localChat = local.agent.openSession('本机模式验收');
      final localRequest = local.agent.request(localChat, '本机独立待审批', [field]);
      final held = await ui.resolve(
        () => server.runtime.run(
          () async => server.runtime.service.agent.request(
            serverChat,
            'NAS 保留的待审批',
            [field],
          ),
        ),
      );
      expect(
        (await ui.resolve(
          () => source().approvals.query(const WorkspaceApprovalQuery()),
        )).items.any((row) => row.id == localRequest.id),
        false,
      );
      await settings();
      await ui.tap('connection-mode-local');
      await approvals('本机独立待审批');
      final localProposals = await ui.resolve(
        () => source().proposals.query(const WorkspaceProposalQuery()),
      );
      expect(localProposals.items.any((row) => row.id == localProposal), true);
      expect(localProposals.items.any((row) => row.id == nasProposal), false);

      expect((await cliTarget()).isLocal, true);
      expect(
        (await ui.resolve(
          () => AgentConnectionProfile.read(
            File('${root.path}/agent-connection.json'),
          ),
        )).isLocal,
        true,
      );
      expect(
        (await ui.resolve(
          () => source().approvals.query(const WorkspaceApprovalQuery()),
        )).items.any((row) => row.id == held.id),
        false,
      );
      await ui.tap('approval-approve');
      await ui.until(() => local.owner.queryInbox(limit: 10).pendingCount == 0);
      expect(
        server.runtime.service.owner.queryInbox(limit: 10).pendingCount,
        1,
      );
      await settings();
      await ui.tap('connection-mode-server');
      await ui.tap('connection-save');
      await ui.until(
        () => find.textContaining('服务器同步 ·').evaluate().isNotEmpty,
      );
      await approvals('NAS 保留的待审批');
      expect((await cliTarget()).isLocal, false);
      expect(
        server.runtime.service.owner.queryInbox(limit: 10).pendingCount,
        1,
      );
      final prior = boot!;
      await t.pumpWidget(const SizedBox());
      await ui.resolve(prior.close);
      await t.pumpWidget(launcher(2));
      await ui.until(
        () => find.textContaining('服务器同步 ·').evaluate().isNotEmpty,
      );
      await approvals('NAS 保留的待审批');
      expect((await cliTarget()).isLocal, false);
      await ui.resolve(server.close);
      serverStopped = true;
      await ui.resolve(() async {
        await expectLater(
          source().approvals.query(const WorkspaceApprovalQuery()),
          throwsA(isA<WorkspaceFailure>()),
        );
      });
      await settings();
      await ui.tap('connection-mode-local');
      await ui.until(
        () => ui.key('workspace-storage-mode').evaluate().isNotEmpty,
      );
      expect((await cliTarget()).isLocal, true);
      expect(t.takeException(), isNull);
    } finally {
      await t.pumpWidget(const SizedBox());
      if (boot != null) await ui.resolve(boot!.close);
      if (preparing != null) {
        await ui.resolve(preparing.service.close);
        await ui.resolve(preparing.close);
      }
      if (serverStopped) {
        await ui.resolve(() => server.root.delete(recursive: true));
      } else {
        await ui.resolve(server.dispose);
      }
      await ui.resolve(() => root.delete(recursive: true));
    }
  });
}
