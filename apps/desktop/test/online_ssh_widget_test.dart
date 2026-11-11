@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/information_files.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/connection_profile.dart';
import '../../server/test/support/device_credential_fixture.dart';
import '../../server/test/support/device_ssh_fixture.dart';
import '../../server/test/support/device_test_receiver.dart';
import 'support/online_ui_harness.dart';

class _RealHttp extends HttpOverrides {}

class _Picker implements InformationFilePicker {
  _Picker(this.path);
  final String path;
  int calls = 0;
  @override
  Future<String?> choose() async {
    calls++;
    return path;
  }

  @override
  Future<String?> saveAs(String name) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousHttp = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = previousHttp);
  testWidgets(
    'normal online App manages SSH trust and approves SSH and Token requests; actual CLI use continues with App closed',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      t.view.physicalSize = const Size(1500, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      DeviceCredentialFixture? f;
      DeviceSshFixture? ssh;
      AgentClient? agent;
      RemoteWorkspaceSource? source;
      late Directory root;
      late PrivateConnectionProfileStore profiles;
      late _Picker picker;
      late ManagedCredential credential;
      late String worker;
      try {
        await t.runAsync(() async {
          ssh = await DeviceSshFixture.start();
          f = await DeviceCredentialFixture.create();
          root = Directory(await f!.root.resolveSymbolicLinks());
          profiles = PrivateConnectionProfileStore('${root.path}/profile');
          await profiles.save(
            ConnectionProfile(
              address: f!.owner.address.toString(),
              token: f!.token,
              serverId: f!.owner.serverId,
              certificate: f!.certificate,
            ),
          );
          final hosts = File('${root.path}/synthetic-known_hosts');
          await hosts.writeAsBytes(await ssh!.trust);
          picker = _Picker(hosts.path);
          worker = '${root.path}/info-runtime-worker';
          final dart = File(
            '../../.tools/flutter/bin/cache/dart-sdk/bin/dart',
          ).absolute.path;
          final built = await Process.run(
            dart,
            ['compile', 'exe', 'bin/runtime_worker.dart', '-o', worker],
            workingDirectory: Directory(
              '../../packages/info_cli',
            ).absolute.path,
          );
          expect(built.exitCode, 0, reason: '${built.stderr}');
          credential = await f!.runtime.run(() async {
            final raw = await f!.runtime.service.owner.createFileCredential(
              name: 'Synthetic UI SSH identity',
              publicPurpose: 'Synthetic test container',
              fileName: 'identity',
              bytes: await ssh!.key,
            );
            return f!.runtime.service.owner.updateCredentialMetadata(
              raw.id,
              raw.revision,
              name: raw.name,
              publicPurpose: raw.publicPurpose,
              privateNote: '',
              suggestedBinding: 'identity',
              discoverable: true,
            );
          });
          agent = AgentClient.remote(
            f!.profiles.first,
            deviceFileStateDirectory: Directory('${root.path}/device-files'),
            runtimeWorkerExecutable: worker,
          );
          expect(
            (await agent!.openLifecycleSession(
              'Synthetic UI SSH chat',
            ))['status'],
            'ok',
          );
        });
        ui.phase = 'launch normal online App';
        await t.pumpWidget(
          OnlineDesktopLauncher(profiles: profiles, filePicker: picker),
        );
        await ui.until(() => find.byType(LibraryPage).evaluate().isNotEmpty);
        source =
            t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
                as RemoteWorkspaceSource;
        ui.phase = 'select SSH trust settings';
        await ui.tap('workspace-nav-settings');
        await ui.tap('settings-section-plugins');
        await ui.tap('plugin-select-builtin.server');
        await ui.tap('plugin-tab-settings');
        await ui.tap('host-import');
        ui.phase = 'preview selected public hosts file';
        await ui.until(
          () => find.text('[127.0.0.1]:${ssh!.port}').evaluate().isNotEmpty,
        );
        expect(picker.calls, 1);
        expect(find.text('synthetic-known_hosts'), findsOneWidget);
        expect(f!.runtime.service.owner.sshKnownHosts, isNull);
        await ui.tap('host-import-submit');
        await ui.until(() => ui.key('host-import-submit').evaluate().isEmpty);
        final identities = await ui.resolve(() => source!.hosts.load());
        expect(identities.single.state, WorkspaceHostState.trusted);
        final target = identities.single.target;
        ui.phase = 'revoke and confirm real imported host';
        await ui.tap('host-open-${target.key}');
        await ui.tap('host-revoke');
        await ui.until(() => find.text('已撤销').evaluate().isNotEmpty);
        await ui.tap('host-confirm');
        await ui.until(() => find.text('已确认').evaluate().isNotEmpty);
        await ui.tap('host-close');
        ui.phase = 'AI submits actual device SSH request';
        final work = await ui.resolve(
          () => Directory('${root.path}/device-work').create(),
        );
        final launch = <String, dynamic>{
          'receiver': 'ssh_identity',
          'executable': '/usr/bin/ssh',
          'cwd': work.path,
          'argv': ssh!.argv(),
          'env': <String, Object?>{},
        };
        final requested = await ui.resolve(
          () => agent!.execute({
            'command': 'request-use',
            'purpose': 'Connect to synthetic SSH container',
            'credentials': [
              {
                'alias': 'identity',
                'credentialId': credential.id,
                'version': 1,
              },
            ],
            'launch': launch,
          }),
        );
        expect(requested['status'], 'pending', reason: jsonEncode(requested));
        final id = requested['requestId'] as String;
        ui.phase = 'review real request in normal approvals page';
        await ui.tap('workspace-nav-approvals');
        await ui.tap('approval-select-$id');
        await ui.until(
          () =>
              find.byType(ApprovalsPage).evaluate().isNotEmpty &&
              t
                      .widget<ApprovalsPage>(find.byType(ApprovalsPage))
                      .controller
                      .detail
                      ?.request
                      .id ==
                  id,
        );
        expect(find.textContaining('/usr/bin/ssh'), findsAtLeastNWidgets(1));
        expect(find.textContaining('〈凭据文件〉'), findsAtLeastNWidgets(1));
        expect(find.textContaining(work.path), findsAtLeastNWidgets(1));
        final approvals = t
            .widget<ApprovalsPage>(find.byType(ApprovalsPage))
            .controller;
        expect(approvals.detail!.credential!.supportsSessionValidity, true);
        expect(approvals.draft!.selected, isNotEmpty);
        await ui.tap('approval-credential-ttl');
        await ui.until(() => find.text('不限时（限本聊天）').evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text('不限时（限本聊天）').last));
        await t.pump();
        await ui.until(() => approvals.draft!.credentialMinutes == null);
        expect(approvals.draft!.credentialMinutes, isNull);
        await ui.tap('approval-approve');
        await ui.until(
          () => f!
              .runtime
              .service
              .owner
              .credentialUseRequests
              .single
              .credentialApproved,
        );
        expect(
          f!
              .runtime
              .service
              .owner
              .credentialUseRequests
              .single
              .credentialValidity,
          CredentialUseValidity.session,
        );
        expect(
          f!
              .runtime
              .service
              .owner
              .credentialUseRequests
              .single
              .credentialExpiresAt,
          isNull,
        );
        ui.phase = 'close App before actual credential use';
        await t.pumpWidget(const SizedBox.shrink());
        await ui.resolve(() => source!.dispose());
        source = null;
        final run = await ui.resolve(
          () => agent!.execute({
            'command': 'run-use',
            'requestId': id,
            'operationId': 'ui-ssh-once',
            'launch': launch,
          }),
        );
        expect(run['status'], 'accepted', reason: jsonEncode(run));
        await ui.resolve(() => agent!.drainCredentialExecutions());
        final status = await ui.resolve(
          () => agent!.execute({
            'command': 'execution-status',
            'executionId': run['executionId'],
          }),
        );
        expect(status['executionState'], 'exited', reason: jsonEncode(status));
        expect(status['exitCode'], 0, reason: jsonEncode(status));
        expect(status['cleanupState'], 'complete');
        final output = await ui.resolve(
          () => agent!.execute({
            'command': 'execution-output',
            'executionId': run['executionId'],
          }),
        );
        expect(
          utf8.decode(
            (output['chunks'] as List)
                .expand<int>((c) => base64Decode(c['dataBase64'] as String))
                .toList(),
          ),
          contains('SYNTHETIC_SSH_OK'),
        );
        expect(f!.repo.credentialExecutions, hasLength(1));
        ui.phase = 'prepare permissionless Token receiver';
        final tokenLaunch = await ui.resolve(() async {
          final program = File('${work.path}/gh');
          await program.writeAsString(syntheticCredentialReceiver);
          expect(
            (await Process.run('/bin/chmod', ['700', program.path])).exitCode,
            0,
          );
          final release = File('${work.path}/token-release');
          await release.writeAsString('release');
          return <String, dynamic>{
            'receiver': 'gh_token',
            'executable': program.path,
            'cwd': work.path,
            'argv': ['api', 'user', '${work.path}/token-counter', release.path],
            'env': {
              'GH_TOKEN': {'secret': 'material'},
            },
          };
        });
        final token = await ui.resolve(
          () => f!.runtime.run(() async {
            final raw = await f!.runtime.service.owner.createStringCredential(
              name: 'Synthetic UI Token',
              publicPurpose: 'Permissionless receiver',
              secret: 'SYNTHETIC_DEVICE_TOKEN',
            );
            return f!.runtime.service.owner.updateCredentialMetadata(
              raw.id,
              raw.revision,
              name: raw.name,
              publicPurpose: raw.publicPurpose,
              privateNote: '',
              suggestedBinding: 'material',
              discoverable: true,
            );
          }),
        );
        final tokenRequest = await ui.resolve(
          () => agent!.execute({
            'command': 'request-use',
            'purpose': 'Synthetic UI Token use',
            'credentials': [
              {'alias': 'material', 'credentialId': token.id, 'version': 1},
            ],
            'launch': tokenLaunch,
          }),
        );
        expect(
          tokenRequest['status'],
          'pending',
          reason: jsonEncode(tokenRequest),
        );
        final tokenId = tokenRequest['requestId'] as String;
        ui.phase = 'reopen App and approve Token with fixed lifetime';
        await t.pumpWidget(
          OnlineDesktopLauncher(profiles: profiles, filePicker: picker),
        );
        await ui.until(() => find.byType(LibraryPage).evaluate().isNotEmpty);
        source =
            t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
                as RemoteWorkspaceSource;
        await ui.tap('workspace-nav-approvals');
        await ui.tap('approval-select-$tokenId');
        await ui.until(
          () =>
              t
                  .widget<ApprovalsPage>(find.byType(ApprovalsPage))
                  .controller
                  .detail
                  ?.request
                  .id ==
              tokenId,
        );
        final tokenApprovals = t
            .widget<ApprovalsPage>(find.byType(ApprovalsPage))
            .controller;
        expect(
          tokenApprovals.detail!.credential!.supportsSessionValidity,
          false,
        );
        expect(find.textContaining('GH_TOKEN'), findsAtLeastNWidgets(1));
        await ui.tap('approval-credential-ttl');
        await ui.until(() => find.text('4 小时').evaluate().isNotEmpty);
        expect(find.text('不限时（限本聊天）'), findsNothing);
        await t.runAsync(() => t.tap(find.text('4 小时').last));
        await t.pump();
        await ui.until(() => tokenApprovals.draft!.credentialMinutes == 240);
        await ui.tap('approval-approve');
        await ui.until(
          () => f!.runtime.service.owner.credentialUseRequests
              .singleWhere((r) => r.id == tokenId)
              .credentialApproved,
        );
        final recordedToken = f!.runtime.service.owner.credentialUseRequests
            .singleWhere((r) => r.id == tokenId);
        expect(recordedToken.credentialValidity, CredentialUseValidity.timed);
        expect(
          recordedToken.credentialExpiresAt!.difference(
            recordedToken.decidedAt!,
          ),
          const Duration(hours: 4),
        );
        await t.pumpWidget(const SizedBox.shrink());
        await ui.resolve(() => source!.dispose());
        source = null;
        ui.phase = 'actual Token use with App closed';
        final tokenRun = await ui.resolve(
          () => agent!.execute({
            'command': 'run-use',
            'requestId': tokenId,
            'operationId': 'ui-token-once',
            'launch': tokenLaunch,
          }),
        );
        expect(tokenRun['status'], 'accepted', reason: jsonEncode(tokenRun));
        await ui.resolve(() => agent!.drainCredentialExecutions());
        final tokenStatus = await ui.resolve(
          () => agent!.execute({
            'command': 'execution-status',
            'executionId': tokenRun['executionId'],
          }),
        );
        expect(
          tokenStatus['executionState'],
          'exited',
          reason: jsonEncode(tokenStatus),
        );
        expect(tokenStatus['exitCode'], 0);
        final tokenOutput = await ui.resolve(
          () => agent!.execute({
            'command': 'execution-output',
            'executionId': tokenRun['executionId'],
          }),
        );
        final tokenText = utf8.decode(
          (tokenOutput['chunks'] as List)
              .expand<int>((c) => base64Decode(c['dataBase64'] as String))
              .toList(),
        );
        expect(tokenText, contains('completed'));
        expect(tokenText, isNot(contains('SYNTHETIC_DEVICE_TOKEN')));
        expect(f!.repo.credentialExecutions, hasLength(2));
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        if (source != null) await ui.resolve(() => source!.dispose());
        await t.runAsync(() async {
          await agent?.drainCredentialExecutions();
          agent?.close();
          await f?.dispose();
          await ssh?.close();
        });
        debugDefaultTargetPlatformOverride = null;
      }
    },
    skip: !Platform.isMacOS,
  );
}
