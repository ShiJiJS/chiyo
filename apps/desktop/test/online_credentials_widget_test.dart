import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_cli/agent_client.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_desktop/mac_inline_password.dart';
import 'package:info_desktop/workspace/proposals_page.dart';
import 'package:info_desktop/credential_files.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/tls_fixture.dart';

class _RealHttp extends HttpOverrides {}

class _Files implements CredentialFilePicker {
  @override
  Future<SelectedCredentialFile?> choose() async => SelectedCredentialFile(
    'synthetic.key',
    utf8.encode('SYNTHETIC_UI_KEY_FILE'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previous = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = previous);
  testWidgets(
    'normal online App creates, replaces and disables credentials and reopens metadata from the real encrypted server',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      t.view.physicalSize = const Size(1500, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (_) async => null,
      );
      final inlineChannels = <MethodChannel>[];
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
        for (final channel in inlineChannels) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      });
      const secret = 'SYNTHETIC_UI_PRIVATE_TOKEN';
      var nextSecret = secret;
      const channel = MethodChannel('agent_info_manage/secret_editor');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'edit' ? nextSecret : null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      late Directory root;
      late EncryptedInformationRepository repo;
      late core.OnlineInformationRuntime runtime;
      late OnlineServer server;
      late OwnerClient independent;
      late PrivateConnectionProfileStore profiles;
      var phase = 'setup';
      await t.runAsync(() async {
        root = await Directory.systemTemp.createTemp('chiyo-credential-ui-');
        root = Directory(await root.resolveSymbolicLinks());
        await initializeServerSecrets('${root.path}/secrets');
        final fixture = await createTlsFixture(root);
        final tls = SecurityContext()
          ..useCertificateChain(fixture.certificate)
          ..usePrivateKey(fixture.privateKey);
        final trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(fixture.ca);
        final token = base64Url
            .encode(
              await File('${root.path}/secrets/owner.token').readAsBytes(),
            )
            .replaceAll('=', '');
        repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
        );
        runtime = await core.OnlineInformationRuntime.open(repository: repo);
        server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: 'online-credential-ui-synthetic',
        );
        independent = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${server.port}'),
          token: token,
          trust: trust,
        );
        profiles = PrivateConnectionProfileStore('${root.path}/profile');
        await profiles.save(
          ConnectionProfile(
            address: independent.address.toString(),
            token: token,
            serverId: independent.serverId,
            certificate: await File(fixture.ca).readAsString(),
          ),
        );
      });
      Future<void> until(bool Function() ready) async {
        for (var n = 0; n < 500; n++) {
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump(const Duration(milliseconds: 60));
        }
        final messages = find
            .byType(Text)
            .evaluate()
            .map((e) => (e.widget as Text).data)
            .whereType<String>()
            .where(
              (s) => s.contains('凭据') || s.contains('核对') || s.contains('连接'),
            )
            .join(' | ');
        fail(
          'Online credential UI did not reach the expected state ($phase). Saved=${repo.managedCredentials.length}. $messages',
        );
      }

      Finder key(String id) => find.byKey(ValueKey(id));
      Future<void> tap(String id) async {
        await until(
          () =>
              key(id).evaluate().length == 1 &&
              (key(id).evaluate().single.widget is! DesktopButton ||
                  (key(id).evaluate().single.widget as DesktopButton)
                              .onPressed !=
                          null &&
                      !(key(id).evaluate().single.widget as DesktopButton)
                          .busy),
        );
        await t.ensureVisible(key(id));
        await t.pump();
        await t.runAsync(() => t.tap(key(id)));
        await t.pump();
      }

      LibraryController model() =>
          t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
      Future<void> enter(String id, String value) async {
        await until(
          () =>
              key(id).evaluate().length == 1 &&
              t.widget<DesktopTextField>(key(id)).enabled != false,
        );
        await t.enterText(key(id), value);
        await t.pump();
        expect(t.widget<DesktopTextField>(key(id)).controller!.text, value);
      }

      Future<T> resolve<T>(Future<T> Function() action) async {
        var done = false;
        late T value;
        Object? error;
        await t.runAsync(() async {
          unawaited(
            action().then<void>(
              (result) {
                value = result;
                done = true;
              },
              onError: (Object e) {
                error = e;
                done = true;
              },
            ),
          );
        });
        await until(() => done);
        if (error is WorkspaceFailure) {
          fail('Owner read failed: ${(error as WorkspaceFailure).code}');
        }
        if (error != null) throw error!;
        return value;
      }

      Future<void> closeApp() async {
        final app = find.byType(WorkspaceApp);
        final source = app.evaluate().isEmpty
            ? null
            : t.widget<WorkspaceApp>(app).source as RemoteWorkspaceSource;
        await t.pumpWidget(const SizedBox.shrink());
        if (source != null) {
          var done = false;
          Object? error;
          final closing = source.dispose().then(
            (_) => done = true,
            onError: (Object e) {
              error = e;
              done = true;
            },
          );
          await until(() => done);
          await closing;
          expect(error, isNull);
        }
      }

      Future<void> launch() async {
        await t.pumpWidget(
          OnlineDesktopLauncher(profiles: profiles, credentialFiles: _Files()),
        );
        await until(
          () =>
              find.byType(LibraryPage).evaluate().isNotEmpty &&
              {
                WorkspaceLoad.empty,
                WorkspaceLoad.ready,
              }.contains(model().loadState),
        );
      }

      try {
        await launch();
        await tap('library-create');
        await tap('library-new-type-credential');
        await tap('credential-edit-candidate');
        await until(() => find.text('填写').evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text('填写')));
        await t.pump();
        await tap('owner-credential-input-complete');
        await until(
          () => key('owner-credential-input-complete').evaluate().isEmpty,
        );
        expect(find.text(secret), findsNothing);
        await enter('credential-edit-name', '合成联网凭据');
        await enter('credential-edit-purpose', '合成服务登录');
        await tap('credential-edit-save');
        await until(
          () =>
              key('credential-edit-save').evaluate().isEmpty &&
              model().detail?.record.ref.kind == WorkspaceRecordKind.credential,
        );
        final first = model().detail!.record.ref;
        phase = 'first saved';
        expect(first.id, repo.managedCredentials.single.id);
        expect(repo.credentialMaterials.single.bytes, utf8.encode(secret));
        expect(model().results?.total, 1);
        await tap('credential-replace');
        await tap('credential-edit-candidate');
        nextSecret = 'SYNTHETIC_UI_REPLACEMENT_TOKEN';
        await until(() => find.text('填写').evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text('填写')));
        await t.pump();
        await tap('owner-credential-input-complete');
        await until(
          () => key('owner-credential-input-complete').evaluate().isEmpty,
        );
        await tap('credential-edit-save');
        await until(
          () =>
              key('credential-edit-save').evaluate().isEmpty &&
              repo.managedCredentials.single.version == 2,
        );
        await tap('credential-toggle');
        await tap('credential-toggle-submit');
        await until(() => !repo.managedCredentials.single.enabled);
        await tap('library-create');
        await tap('library-new-type-credential');
        await tap('credential-edit-candidate');
        await until(() => find.text('文件').evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text('文件').last));
        await t.pump();
        await tap('owner-credential-pick-file');
        await tap('owner-credential-input-complete');
        await until(
          () => key('owner-credential-input-complete').evaluate().isEmpty,
        );
        await enter('credential-edit-name', '合成联网文件凭据');
        await tap('credential-edit-save');
        await until(
          () =>
              key('credential-edit-save').evaluate().isEmpty &&
              repo.managedCredentials.length == 2 &&
              model().results?.total == 2,
        );
        expect(
          repo.credentialMaterials.last.bytes,
          utf8.encode('SYNTHETIC_UI_KEY_FILE'),
        );
        await until(() => model().detail?.record.name == '合成联网文件凭据');
        final file = model().detail!.record.ref;
        phase = 'close first app';
        await closeApp();
        phase = 'reopen app';
        await launch();
        phase = 'load reopened list';
        await until(() => model().results?.total == 2);
        final source =
            t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
                as RemoteWorkspaceSource;
        phase = 'read reopened credential';
        final reopened = await resolve(() => source.credentials.read(first));
        expect(reopened.enabled, false);
        expect(reopened.materialVersion, 2);
        phase = 'read reopened file';
        final fileDetail = await resolve(() => source.credentials.read(file));
        expect(fileDetail.filename, 'synthetic.key');
        phase = 'read reopened summaries';
        final summaries = await resolve(
          () => source.readSummaries([first, file]),
        );
        expect(summaries, hasLength(2));
        phase = 'independent ordinary catalog';
        expect(await resolve(independent.information), isEmpty);
        expect(runtime.service.owner.credentialUseRequests, isEmpty);
        // A real restricted CLI submits production templates. The normal App
        // supplies only the native password-input callback with synthetic text.
        phase = 'submit linked AI credentials';
        final device = await resolve(
          () => independent.request('POST', '/v1/owner/devices', {
            'operationId': 'proposal-device',
            'name': 'Synthetic UI CLI',
          }),
        );
        final connection = await resolve(profiles.read);
        final cli = AgentClient.remote(
          AgentConnectionProfile(
            address: independent.address,
            deviceToken: device['deviceToken'] as String,
            serverId: independent.serverId,
            certificate: connection!.certificate,
          ),
        );
        addTearDown(cli.close);
        await resolve(
          () => cli.openLifecycleSession('Synthetic inline passwords'),
        );
        Future<Map<String, dynamic>> run(
          String command, [
          Map<String, dynamic> input = const {},
        ]) => resolve(() => cli.execute({'command': command, ...input}));
        Future<Map<String, dynamic>> example(String id) async {
          final description =
              (await run('template-read', {'templateId': id}))['template']
                  as Map;
          final item = Map<String, dynamic>.from(
            ((description['submissionExample'] as Map)['items'] as List).single
                as Map,
          );
          item.remove('relations');
          return item;
        }

        final templates = (await run('template-list'))['templates'] as List;
        final serviceTemplate = templates.cast<Map>().firstWhere(
          (entry) => entry['name'] == '应用与服务',
        );
        final service = {
          ...await example(serviceTemplate['id'] as String),
          'key': 'service',
          'name': '合成提案服务',
        };
        Future<Map<String, dynamic>> password(
          String key,
          String account,
        ) async => {
          ...await example('credential.accountPassword'),
          'key': key,
          'name': '合成登录 $key',
          'credential': {
            'source': 'owner',
            'contextExposed': false,
            'account': account,
          },
          'relations': {
            'related': [
              {'kind': 'information', 'itemKey': 'service'},
            ],
          },
        };
        const firstPassword = 'SYNTHETIC_INLINE_FIRST',
            secondPassword = 'SYNTHETIC_INLINE_SECOND',
            proposalToken = 'SYNTHETIC_INLINE_AGENT_TOKEN';
        final submitted = await run('import-submit', {
          'operationId': 'whole-ui-credential-proposal',
          'items': [
            service,
            await password('first', 'first-user'),
            await password('second', 'second-user'),
            {
              ...await example('credential.token'),
              'key': 'token',
              'name': '合成提案 Token',
              'credential': {
                'source': 'agentString',
                'contextExposed': true,
                'secret': proposalToken,
              },
              'relations': {
                'related': [
                  {'kind': 'information', 'itemKey': 'service'},
                ],
              },
            },
          ],
        });
        expect(submitted['status'], 'pending', reason: jsonEncode(submitted));
        final proposalId = submitted['proposalId'] as String;
        await tap('workspace-nav-proposals');
        await until(
          () =>
              find.byType(ProposalsPage).evaluate().isNotEmpty &&
              t
                      .widget<ProposalsPage>(find.byType(ProposalsPage))
                      .controller
                      .detail
                      ?.summary
                      .id ==
                  proposalId,
        );
        final proposal = t
            .widget<ProposalsPage>(find.byType(ProposalsPage))
            .controller;
        await until(() => !proposal.loading && !proposal.reading);
        expect(proposal.detail!.items, hasLength(4));
        expect(proposal.canConfirm, false);
        final firstItem = proposal.detail!.items.singleWhere(
          (i) => i.credential?.account == 'first-user',
        );
        final secondItem = proposal.detail!.items.singleWhere(
          (i) => i.credential?.account == 'second-user',
        );
        expect(firstItem.proposed.record.type.name, isNotEmpty);
        expect(repo.items, isEmpty);
        expect(repo.managedCredentials, hasLength(2));
        Future<void> fill(String item, String value) async {
          await tap('proposal-tab-$item');
          final input = key('proposal-owner-password-$item');
          await until(
            () =>
                input.evaluate().length == 1 &&
                t.widget<DesktopTextField>(input).enabled == true,
          );
          await t.ensureVisible(input);
          final view = t.widget<AppKitView>(
            find.descendant(of: input, matching: find.byType(AppKitView)),
          );
          final id = 900 + inlineChannels.length;
          final channel = MethodChannel(
            'agent_info_manage/inline_password/$id',
          );
          inlineChannels.add(channel);
          messenger.setMockMethodCallHandler(channel, (_) async => null);
          view.onPlatformViewCreated!(id);
          await t.pump();
          final done = Completer<void>();
          await messenger.handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('changed', value),
            ),
            (_) => done.complete(),
          );
          await done.future;
          await t.pump();
          expect(t.widget<DesktopTextField>(input).controller!.text, value);
          expect(find.text(value), findsNothing);
        }

        phase = 'first inline password';
        await fill(firstItem.id, firstPassword);
        expect(proposal.canConfirm, false);
        expect(find.textContaining('first-user'), findsWidgets);
        expect(repo.managedCredentials, hasLength(2));
        phase = 'second inline password';
        await fill(secondItem.id, secondPassword);
        await until(() => proposal.canConfirm);
        await tap('proposal-password-visible-${secondItem.id}');
        expect(
          t
              .widget<MacInlinePassword>(find.byType(MacInlinePassword))
              .obscureText,
          false,
        );
        await tap('proposal-password-visible-${secondItem.id}');
        expect(
          t
              .widget<MacInlinePassword>(find.byType(MacInlinePassword))
              .obscureText,
          true,
        );
        expect(
          jsonEncode(
            proposal.draft!.items.values.map((i) => i.toJson()).toList(),
          ),
          isNot(contains('SYNTHETIC_INLINE_')),
        );
        expect(
          jsonEncode(await run('import-status', {'proposalId': proposalId})),
          isNot(contains('SYNTHETIC_INLINE_')),
        );
        phase = 'whole proposal save';
        await tap('proposal-confirm');
        await until(
          () =>
              !proposal.busy &&
              (proposal.writeFailure != null ||
                  proposal.detail?.summary.status ==
                      WorkspaceProposalStatus.completed),
        );
        expect(
          proposal.writeFailure,
          isNull,
          reason: proposal.writeFailure?.code,
        );
        expect(repo.items, hasLength(1));
        expect(repo.managedCredentials, hasLength(5));
        final serviceId = repo.items.single.id;
        final linked = repo.managedCredentials.where(
          (c) => c.name.startsWith('合成登录') || c.name == '合成提案 Token',
        );
        expect(linked, hasLength(3));
        expect(linked.every((c) => c.linkedItemIds.contains(serviceId)), true);
        final stored = repo.credentialMaterials
            .map((m) => utf8.decode(m.bytes))
            .toSet();
        expect(
          stored,
          containsAll([firstPassword, secondPassword, proposalToken]),
        );
        expect(runtime.service.owner.credentialUseRequests, isEmpty);
        phase = 'reopen accepted proposal';
        await closeApp();
        await launch();
        await until(() => model().results?.total == 6);
        final refreshed = await resolve(independent.information);
        expect(refreshed.single.id, serviceId);
        await resolve(() => cli.endLifecycleSession(cli.endCapability!));
        expect(t.takeException(), isNull);
      } finally {
        phase = 'cleanup app';
        await closeApp();
        debugDefaultTargetPlatformOverride = null;
        phase = 'cleanup server';
        var done = false;
        Object? failure;
        final closing =
            (() async {
              independent.close();
              await server.close();
              await runtime.close();
              await repo.close();
              await root.delete(recursive: true);
            })().then(
              (_) => done = true,
              onError: (Object e) {
                failure = e;
                done = true;
              },
            );
        await until(() => done);
        await closing;
        expect(failure, isNull);
      }
    },
  );
}
