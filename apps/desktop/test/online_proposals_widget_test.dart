import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/library_document.dart';
import 'package:info_desktop/workspace/proposals_page.dart';
import 'package:info_desktop/workspace/template_record_content.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/tls_fixture.dart';
import 'support/online_ui_harness.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previous = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = previous);
  testWidgets(
    'normal online App previews typed linked rows, corrects and saves once, then reopens to compare an AI update',
    (t) async {
      t.view.physicalSize = const Size(1500, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late Directory root;
      late EncryptedInformationRepository repo;
      late core.OnlineInformationRuntime runtime;
      late OnlineServer server;
      late PrivateConnectionProfileStore profiles;
      late AgentClient cli;
      late OwnerClient independent;
      late Map<String, Map<String, dynamic>> templates;
      final ui = OnlineUiHarness(t);
      Future<void> closeApp() async {
        final app = find.byType(WorkspaceApp);
        final source = app.evaluate().isEmpty
            ? null
            : t.widget<WorkspaceApp>(app).source as RemoteWorkspaceSource;
        await t.pumpWidget(const SizedBox());
        if (source != null) await ui.resolve(source.dispose);
      }

      Future<void> until(bool Function() ready) async {
        for (var n = 0; n < 350; n++) {
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump(const Duration(milliseconds: 80));
        }
        fail(
          'Online proposal UI did not complete: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().join(' | ')}',
        );
      }

      Finder key(String id) => find.byKey(ValueKey(id));
      Future<void> tap(String id) async {
        await until(() {
          if (key(id).evaluate().isEmpty) return false;
          final widget = key(id).evaluate().single.widget;
          return widget is! DesktopButton || widget.onPressed != null;
        });
        await t.ensureVisible(key(id));
        await t.pump();
        await t.runAsync(() => t.tap(key(id)));
        await t.pump(const Duration(milliseconds: 250));
      }

      await t.runAsync(() async {
        root = await Directory.systemTemp.createTemp(
          'chiyo-online-proposal-ui-',
        );
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
          serverId: 'online-proposal-ui-synthetic',
        );
        independent = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${server.port}'),
          token: token,
          trust: trust,
        );
        final enrolled = await independent.request(
          'POST',
          '/v1/owner/devices',
          {'operationId': 'enroll', 'name': 'Synthetic UI CLI'},
        );
        cli = AgentClient.remote(
          AgentConnectionProfile(
            address: independent.address,
            deviceToken: enrolled['deviceToken'] as String,
            serverId: independent.serverId,
            certificate: await File(fixture.ca).readAsString(),
          ),
        );
        expect(
          (await cli.execute({
            'command': 'session',
            'chatLabel': 'Online proposal UI',
          }))['status'],
          'ok',
        );
        templates = {
          for (final id in ['server', 'service', 'document'])
            id: Map<String, dynamic>.from(
              (await cli.execute({
                    'command': 'template-read',
                    'templateId': id,
                  }))['template']
                  as Map,
            ),
        };
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
      try {
        await t.pumpWidget(OnlineDesktopLauncher(profiles: profiles));
        await until(() => find.byType(LibraryPage).evaluate().isNotEmpty);
        late String proposalId;
        await t.runAsync(() async {
          Map<String, Object?> item(
            String templateId,
            String name,
            String key,
            String directory, {
            Map<String, Object?> relations = const {},
          }) => {
            ...Map<String, Object?>.from(
              ((templates[templateId]!['submissionExample'] as Map)['items']
                          as List)
                      .single
                  as Map,
            ),
            'key': key,
            'name': name,
            'suggestedDirectory': directory,
            'relations': relations,
          };
          final note = item(
            'document',
            '合成设备配置',
            'config',
            '工作/配置',
            relations: {
              'related': [
                {'kind': 'information', 'itemKey': 'app'},
              ],
            },
          );
          note['values'] = {
            'bodyFormat': 'markdown',
            'body': '## 合成配置\n\n- 连接已记录的应用入口。',
          };
          final result = await cli.execute({
            'command': 'import-submit',
            'operationId': 'three-rows',
            'items': [
              item('server', '合成服务器', 'host', '工作/服务器'),
              item(
                'service',
                '合成应用',
                'app',
                '工作/应用',
                relations: {
                  'hostedOn': [
                    {'kind': 'information', 'itemKey': 'host'},
                  ],
                  'docs': [
                    {'kind': 'information', 'itemKey': 'config'},
                  ],
                },
              ),
              note,
            ],
          });
          expect(result['status'], 'pending');
          proposalId = result['proposalId'] as String;
        });
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
        final model = t
            .widget<ProposalsPage>(find.byType(ProposalsPage))
            .controller;
        await until(() => model.canConfirm);
        expect(model.detail!.items, hasLength(3));
        expect(runtime.service.owner.information, isEmpty);
        expect(find.byType(TemplateRecordContent), findsWidgets);
        final app = model.detail!.items.singleWhere(
          (i) => i.proposed.record.type.id == 'service',
        );
        final note = model.detail!.items.singleWhere(
          (i) => i.proposed.record.type.id == 'document',
        );
        final host = model.detail!.items.singleWhere(
          (i) => i.proposed.record.type.id == 'server',
        );
        await tap('proposal-tab-${app.id}');
        expect(find.text('应用与服务'), findsWidgets);
        expect(find.textContaining('工作'), findsWidgets);
        await until(() => find.text('合成服务器（待入库）').evaluate().isNotEmpty);
        await t.ensureVisible(find.text('合成服务器（待入库）'));
        await t.tap(find.text('合成服务器（待入库）'));
        await t.pump();
        await until(() => model.activeItemId == host.id);
        expect(find.byType(LibraryPage), findsNothing);
        expect(runtime.service.owner.information, isEmpty);
        await tap('proposal-tab-${note.id}');
        await until(() => find.byType(LibraryDocument).evaluate().isNotEmpty);
        expect(
          t.widget<LibraryDocument>(find.byType(LibraryDocument)).format,
          'markdown',
        );
        expect(find.text('## 合成配置'), findsNothing);
        await tap('proposal-edit-${note.id}');
        await until(() => key('proposal-edit-body').evaluate().isNotEmpty);
        await t.enterText(
          key('proposal-edit-body'),
          '## 用户修正后的配置\n\n- 使用同份提案中的应用。',
        );
        await tap('proposal-edit-keep');
        await until(() => key('proposal-edit-keep').evaluate().isEmpty);
        expect(runtime.service.owner.information, isEmpty);
        await tap('proposal-confirm');
        await until(
          () =>
              model.detail?.summary.status ==
                  WorkspaceProposalStatus.completed &&
              !model.busy,
        );
        await t.runAsync(() async {
          final records = await independent.information();
          expect(records, hasLength(3));
          final savedNote = records.singleWhere(
            (i) => i.layout?.typeId == 'document',
          );
          expect(
            savedNote.fields.any((f) => f.value.contains('用户修正后的配置')),
            true,
          );
          expect(
            runtime.service.owner.directories
                .map((d) => d.name)
                .where((n) => n == '工作'),
            hasLength(1),
          );
          expect(
            records
                .singleWhere((i) => i.layout?.typeId == 'service')
                .layout!
                .relations['hostedOn']!
                .single
                .id,
            records.singleWhere((i) => i.layout?.typeId == 'server').id,
          );
        });
        // Ordinary App exit does not stop the host or CLI session.
        await closeApp();
        late String updateId;
        await t.runAsync(() async {
          final record = (await independent.information()).singleWhere(
            (i) => i.layout?.typeId == 'document',
          );
          final result = await cli.execute({
            'command': 'update-submit',
            'operationId': 'app-closed-update',
            'update': {
              'itemId': record.id,
              'baseVersion': record.version,
              'templateId': 'document',
              'templateVersion': templates['document']!['version'],
              'templateDigest': templates['document']!['digest'],
              'values': {
                'bodyFormat': 'markdown',
                'body': '## AI 修改后\n\n- 新的合成配置。',
              },
            },
          });
          expect(result['status'], 'pending');
          updateId = result['proposalId'] as String;
        });
        await t.pumpWidget(
          OnlineDesktopLauncher(
            key: const ValueKey('reopened-proposal-app'),
            profiles: profiles,
          ),
        );
        await until(() => find.byType(LibraryPage).evaluate().isNotEmpty);
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
                  updateId,
        );
        final reopened = t
            .widget<ProposalsPage>(find.byType(ProposalsPage))
            .controller;
        await until(() => reopened.canConfirm);
        expect(
          reopened.detail!.items.single.before!.values['body'],
          contains('用户修正后的配置'),
        );
        expect(find.text('修改前'), findsWidgets);
        expect(find.text('修改后'), findsWidgets);
        expect(find.byType(LibraryPage), findsNothing);
        await tap('proposal-confirm');
        await until(
          () =>
              reopened.detail?.summary.status ==
                  WorkspaceProposalStatus.completed &&
              !reopened.busy,
        );
        await t.runAsync(() async {
          final record = (await independent.information()).singleWhere(
            (i) => i.layout?.typeId == 'document',
          );
          expect(record.version, 2);
          expect(record.fields.any((f) => f.value.contains('AI 修改后')), true);
          expect(
            (await cli.execute({
              'command': 'update-status',
              'operationId': 'app-closed-update',
            }))['status'],
            'confirmed',
          );
        });
        expect(t.takeException(), isNull);
      } finally {
        await closeApp();
        await t.runAsync(() async {
          cli.close();
          independent.close();
          await server.close();
          await runtime.close();
          await repo.close();
          await root.delete(recursive: true);
        });
      }
    },
  );
}
