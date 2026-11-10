@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/macos_agent_bundle.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/agents_controller.dart';
import 'package:info_desktop/workspace/agents_page.dart';
import 'package:info_desktop/workspace/remote_workspace_agents.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import '../../server/test/support/device_credential_fixture.dart';
import '../../server/test/support/owner_reply_proxy.dart';
import 'support/online_ui_harness.dart';

class _Http extends HttpOverrides {}

Matcher _fails(String code) =>
    throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
Future<RemoteWorkspaceSource> _source(
  DeviceCredentialFixture f, {
  OwnerReplyProxy? proxy,
}) async {
  final client = await OwnerClient.connect(
    address: proxy?.address ?? f.owner.address,
    token: f.token,
    trust: f.trust,
  );
  final s = RemoteWorkspaceSource(
    client,
    deviceFilesDirectory: '${f.root.path}/app-device',
  );
  addTearDown(s.dispose);
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'online original controller rechecks metadata, retains explicit chat selection and rejects stale details through decisions, restart and failed reads',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final proxy = await OwnerReplyProxy.start(
          tls: f.tls,
          trust: f.trust,
          target: () => f.owner.address,
          serverId: f.owner.serverId,
        );
        addTearDown(proxy.close);
        final s = await _source(f, proxy: proxy);
        final m = WorkspaceAgentsController(s.agents, const Stream.empty());
        addTearDown(m.dispose);
        await f.agents.first.call('/session/lifecycle', {
          'chatLabel': '同名合成聊天',
        });
        final chat = await f.agents.last.call('/session/lifecycle', {
          'chatLabel': '同名合成聊天',
        });
        await m.load();
        expect(m.readFailure, isNull);
        expect(m.value!.sessions, hasLength(2));
        expect(m.value!.session.state, WorkspaceAgentSessionState.unselected);
        expect(m.value!.serviceReason, contains('资料服务器'));
        expect(m.value!.skill, WorkspaceAgentCheck.unavailable);
        expect(m.value!.hooks, isEmpty);
        final item = await f.runtime.run(
          () => f.runtime.service.owner.createInformation('合成说明', '', [
            const FieldInput('内容', '', 'SYNTHETIC_PRIVATE'),
          ]),
        );
        final request = await f.agents.last.call('/request', {
          'sessionSecret': chat['sessionSecret'],
          'operationId': 'diagnose-request',
          'purpose': '合成读取',
          'fields': [
            {'itemId': item.id, 'fieldId': item.fields.single.id},
          ],
        });
        final requestId = request['requestId'] as String;
        await expectLater(
          s.agents.diagnose(m.value!.version),
          _fails('observation_changed'),
        );
        await m.load();
        final id = m.value!.sessions
            .singleWhere((s) => s.totalRequests == 1)
            .id!;
        await m.selectSession(id);
        m.open(WorkspaceAgentView.session);
        await m.readDetails();
        expect(m.session!.matches(m.value!), isTrue);
        expect(m.session!.requests.single.id, requestId);
        final prior = m.value!;
        await f.runtime.run(
          () async => f.runtime.service.owner.approve(requestId, [
            FieldRef(item.id, item.fields.single.id),
          ], lifetime: const Duration(minutes: 10)),
        );
        await expectLater(
          s.agents.currentSession(prior.version),
          _fails('observation_changed'),
        );
        await m.retryDetails();
        expect(m.selectedSessionId, id);
        expect(m.session!.session.activeGrants, 1);
        final beforeRestart = m.value!;
        await f.reopen();
        await expectLater(
          s.agents.diagnose(beforeRestart.version),
          _fails('observation_changed'),
        );
        await m.retryDetails();
        expect(m.session!.session.activeGrants, 1);
        proxy.failGetPrefix = '/v1/owner/agent-sessions';
        await m.retryDetails();
        expect(m.readFailure, isNotNull);
        expect(m.available, isFalse);
        expect(m.session, isNull);
        proxy.failGetPrefix = null;
        await f.agents.last.call('/session/end', {
          'endCapability': chat['endCapability'],
        });
        await m.retryDetails();
        expect(m.readFailure, isNull);
        expect(m.value!.session.state, WorkspaceAgentSessionState.ended);
        expect(m.session!.matches(m.value!), isTrue);
        expect(m.session!.session.activeGrants, 0);
      }, _Http());
    },
  );
  test(
    'actual package hash observation stays on the client and never declares Skill or hooks trusted',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final root = Directory(
          '${await f.root.resolveSymbolicLinks()}/synthetic-delivery',
        );
        final rows = <Map<String, Object?>>[];
        for (final path in MacAgentBundle.requiredFiles) {
          final file = await File('${root.path}/$path').create(recursive: true);
          await file.writeAsString('synthetic non-executable entry $path');
          if (path == MacAgentBundle.appExecutable ||
              path.startsWith('cli/') && !path.startsWith('cli/template/')) {
            await Process.run('/bin/chmod', ['700', file.path]);
          }
          rows.add({
            'path': path,
            'sha256': sha256.convert(await file.readAsBytes()).toString(),
            'bytes': await file.length(),
            'mode': (await file.stat()).mode & 0xfff,
          });
        }
        await File('${root.path}/manifest.json').writeAsString(
          jsonEncode({
            'format': 1,
            'architecture': 'macos-arm64',
            'appIdentity': 'com.example.infoDesktop',
            'sourceDirty': false,
            'sourceCommit': 'a' * 40,
            'files': rows,
          }),
        );
        final bundle = MacAgentBundle(
          executable: '${root.path}/${MacAgentBundle.appExecutable}',
        );
        final c = await OwnerClient.connect(
          address: f.owner.address,
          token: f.token,
          trust: f.trust,
        );
        addTearDown(c.close);
        final agents = RemoteWorkspaceAgents(c, readBundle: bundle.read);
        final v = await agents.read();
        expect(v.cli, WorkspaceAgentCheck.ready);
        expect(v.packageDirectory, root.path);
        expect(v.skill, WorkspaceAgentCheck.unavailable);
        expect(v.hooks, isEmpty);
        expect(v.connection, WorkspaceAgentConnection.unverified);
        expect((await agents.diagnose(v.version)).fingerprint, v.fingerprint);
        await File(
          '${root.path}/cli/info',
        ).writeAsString('changed synthetic entry');
        await expectLater(
          agents.diagnose(v.version),
          _fails('observation_changed'),
        );
        final changed = await agents.read();
        expect(changed.cli, WorkspaceAgentCheck.unavailable);
        expect(changed.packageDirectory, isNull);
        expect(changed.cliReason, contains('不一致'));
        expect(f.runtime.service.owner.sessions, isEmpty);
      }, _Http());
    },
  );
  testWidgets(
    'normal online settings shows server sessions and opens the original session and diagnostic dialogs',
    (t) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Http();
      t.view.physicalSize = const Size(1500, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      DeviceCredentialFixture? f;
      RemoteWorkspaceSource? live;
      try {
        final profiles = await ui.resolve(() async {
          f = await DeviceCredentialFixture.create();
          await f!.agents.first.call('/session/lifecycle', {
            'chatLabel': '界面合成聊天',
          });
          final p = PrivateConnectionProfileStore('${f!.root.path}/profiles');
          await p.save(
            ConnectionProfile(
              address: f!.owner.address.toString(),
              token: f!.token,
              serverId: f!.owner.serverId,
              certificate: f!.certificate,
            ),
          );
          return p;
        });
        await t.pumpWidget(OnlineDesktopLauncher(profiles: profiles));
        await ui.until(() => find.byType(WorkspaceApp).evaluate().isNotEmpty);
        live =
            t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
                as RemoteWorkspaceSource;
        await ui.tap('workspace-nav-settings');
        await ui.tap('settings-section-agents');
        await ui.until(
          () =>
              find.byType(WorkspaceAgentsPage).evaluate().isNotEmpty &&
              t
                      .widget<WorkspaceAgentsPage>(
                        find.byType(WorkspaceAgentsPage),
                      )
                      .controller
                      .value !=
                  null,
        );
        final m = t
            .widget<WorkspaceAgentsPage>(find.byType(WorkspaceAgentsPage))
            .controller;
        expect(m.value!.sessions.single.label, '界面合成聊天');
        final session = m.value!.sessions.single;
        await ui.tap('agents-session-select');
        final label =
            '${session.label} · ${session.id!.substring(0, 8)} · ${session.state.label}';
        await ui.until(() => find.text(label).evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text(label).last));
        await ui.until(() => m.value!.session.id == session.id && !m.loading);
        await ui.tap('agents-session');
        await ui.until(() => m.session != null);
        expect(m.session!.matches(m.value!), isTrue);
        expect(find.textContaining('PRIVATE'), findsNothing);
        await ui.tap('agents-flow-close');
        await ui.until(() => m.view == null);
        await ui.tap('agents-diagnostics');
        await ui.until(() => m.report != null);
        expect(m.report!.serviceAvailable, isTrue);
        expect(m.report!.serviceReason, contains('资料服务器'));
        expect(m.report!.skill, WorkspaceAgentCheck.unavailable);
        expect(t.takeException(), isNull);
        await ui.tap('agents-flow-close');
        await ui.resolve(
          () => f!.agents.last.call('/session/lifecycle', {
            'chatLabel': '后来出现的空聊天',
          }),
        );
        await ui.until(() => !m.loading && m.value!.sessions.length == 2);
        expect(
          m.value!.sessions
              .singleWhere((s) => s.label == '后来出现的空聊天')
              .totalRequests,
          0,
        );
      } finally {
        await t.pumpWidget(const SizedBox());
        if (live != null) await ui.resolve(live.dispose);
        if (f != null) await ui.resolve(f!.dispose);
        HttpOverrides.global = previous;
      }
    },
  );
}
