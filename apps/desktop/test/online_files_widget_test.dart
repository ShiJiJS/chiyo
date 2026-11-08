import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'support/native_file_actions_fixture.dart';
import 'package:info_desktop/information_files.dart';
import 'package:info_desktop/workspace/library_document.dart';
import 'package:info_desktop/workspace/proposals_page.dart';
import 'package:info_desktop/workspace/proposal_original_reading.dart';
import 'package:info_workspace/file_transport.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_move_controller.dart';
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

class _RealHttp extends HttpOverrides {}

class _FilePicker implements InformationFilePicker {
  String? next;
  @override
  Future<String?> choose() async => next;
  @override
  Future<String?> saveAs(String name) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previous = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = previous);
  testWidgets(
    'normal online App uploads, previews, replaces and restores a file through server and reopens exact versions',
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
      final picker = _FilePicker();
      final output = SyntheticOutputPicker();
      final dispatcher = SyntheticOpenDispatcher();
      Future<void> until(bool Function() ready) async {
        for (var n = 0; n < 350; n++) {
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump(const Duration(milliseconds: 80));
        }
        final moveButtons = find.byKey(const ValueKey('library-move-confirm'));
        if (moveButtons.evaluate().isNotEmpty) {
          final builder = find
              .ancestor(
                of: moveButtons,
                matching: find.byType(ListenableBuilder),
              )
              .first;
          final move =
              (t.widget<ListenableBuilder>(builder).listenable
                  as LibraryMoveController);
          debugPrint(
            'Move state: save=${move.canSave}, reading=${move.reading}, busy=${move.busy}, review=${move.needsReview}, failure=${move.failure?.code}, receipt=${move.receipt?.operationId}',
          );
        }
        fail(
          'Online file UI did not complete: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().join(' | ')}',
        );
      }

      Finder key(String id) => find.byKey(ValueKey(id));
      Future<void> tap(String id) async {
        bool enabled() {
          if (key(id).evaluate().isEmpty) return false;
          final widget = key(id).evaluate().single.widget;
          return widget is! DesktopButton ||
              (widget.onPressed != null && !widget.busy);
        }

        await until(enabled);
        await t.ensureVisible(key(id));
        await t.pump();
        await until(enabled);
        final buttons = find.descendant(
          of: key(id),
          matching: find.byType(TextButton),
        );
        await t.runAsync(
          () => t.tap(buttons.evaluate().length == 1 ? buttons : key(id)),
        );
        await t.pump(const Duration(milliseconds: 250));
      }

      Future<void> unmount() async {
        final app = find.byType(WorkspaceApp);
        final source = app.evaluate().isEmpty
            ? null
            : t.widget<WorkspaceApp>(app).source as RemoteWorkspaceSource;
        await t.pumpWidget(const SizedBox());
        if (source != null) {
          var closed = false;
          Object? failure;
          await t.runAsync(() async {
            source.dispose().then(
              (_) => closed = true,
              onError: (Object e) {
                failure = e;
                closed = true;
              },
            );
          });
          await until(() => closed);
          expect(failure, isNull);
        }
        await t.pump();
      }

      await t.runAsync(() async {
        root = await Directory.systemTemp.createTemp('chiyo-online-files-ui-');
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
        late File original, replacement;
        await t.runAsync(() async {
          original = File('${root.path}/synthetic-original.md');
          replacement = File('${root.path}/synthetic-replacement.md');
          await original.writeAsString('## 合成文件第一版\n\n- 第一版原文。');
          await replacement.writeAsString('## 合成文件第二版\n\n- 第二版原文。');
        });
        LibraryController model() =>
            t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
        await t.pumpWidget(
          OnlineDesktopLauncher(
            profiles: profiles,
            filePicker: picker,
            outputPicker: output,
            openDispatcher: dispatcher,
          ),
        );
        await until(
          () =>
              find.byType(LibraryPage).evaluate().isNotEmpty &&
              model().loadState == WorkspaceLoad.empty,
        );
        picker.next = original.path;
        await tap('library-create');
        await until(() => find.text('普通文件').evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text('普通文件').last));
        await until(
          () => key('library-file-import-submit').evaluate().isNotEmpty,
        );
        await tap('library-file-import-submit');
        await until(
          () =>
              key('library-file-import-submit').evaluate().isEmpty &&
              model().results?.total == 1 &&
              model().detail?.record.type.id == 'file',
        );
        await until(
          () =>
              key('library-file-preview-file').evaluate().isNotEmpty &&
              find.byType(LibraryDocument).evaluate().isNotEmpty,
        );
        expect(find.text('## 合成文件第一版'), findsNothing);
        expect(
          t.widget<LibraryDocument>(find.byType(LibraryDocument).last).format,
          'markdown',
        );
        final record = model().detail!.record.ref;
        picker.next = replacement.path;
        await tap('library-file-actions-file');
        await tap('library-file-replace-file');
        await until(
          () => key('library-file-change-target').evaluate().isNotEmpty,
        );
        await tap('library-file-change-submit');
        await until(
          () =>
              key('library-file-change-submit').evaluate().isEmpty &&
              model().detail?.version == 2,
        );
        await tap('library-file-versions-file');
        await tap('library-file-version-1');
        await until(() => key('library-file-restore').evaluate().isNotEmpty);
        await tap('library-file-restore');
        await until(
          () => key('library-file-change-target').evaluate().isNotEmpty,
        );
        await tap('library-file-change-submit');
        await until(
          () =>
              key('library-file-change-submit').evaluate().isEmpty &&
              model().detail?.version == 3,
        );
        await t.runAsync(() async {
          final history = fileHistoryFromJson(
            await independent.request('POST', '/v1/owner/files/history', {
              'record': recordRefToJson(record),
              'fieldKey': 'file',
            }),
          );
          expect(history.versions, hasLength(3));
          expect(history.current.ref.version, 3);
          for (final version in [1, 3]) {
            final fetched = fileOriginalFromJson(
              await independent.request('POST', '/v1/owner/files/read', {
                'record': recordRefToJson(record),
                'fieldKey': 'file',
                'version': version,
              }),
            );
            expect(fetched.bytes, await original.readAsBytes());
          }
          expect((await repo.informationFileStagingUsage()).files, 0);
        });
        await unmount();
        await t.pumpWidget(
          OnlineDesktopLauncher(
            key: const ValueKey('reopened-files'),
            profiles: profiles,
            filePicker: picker,
            outputPicker: output,
            openDispatcher: dispatcher,
          ),
        );
        await until(
          () =>
              find.byType(LibraryPage).evaluate().isNotEmpty &&
              model().detail?.version == 3,
        );
        await until(
          () =>
              key('library-file-preview-file').evaluate().isNotEmpty &&
              find.byType(LibraryDocument).evaluate().isNotEmpty,
        );
        expect(model().detail!.record.ref, record);
        expect(find.text('文件'), findsWidgets);
        expect(t.takeException(), isNull);
        final ownerCopy = File('${root.path}/owner-copy.md');
        output.output = ownerCopy.path;
        await tap('library-file-actions-file');
        await tap('library-file-save-file');
        await until(() => find.text('已另存 owner-copy.md').evaluate().isNotEmpty);
        await t.runAsync(() async {
          expect(await ownerCopy.readAsBytes(), await original.readAsBytes());
        });
        await tap('library-file-actions-file');
        await tap('library-file-open-file');
        await until(() => find.text('结束使用并清理本机打开副本').evaluate().isNotEmpty);
        expect(dispatcher.launches, 1);
        await t.runAsync(() async {
          expect(
            await File(dispatcher.leases.single.filePath).readAsBytes(),
            await original.readAsBytes(),
          );
        });
        await t.runAsync(() => t.tap(find.text('结束使用并清理本机打开副本')));
        await until(() => find.text('结束使用并清理本机打开副本').evaluate().isEmpty);
        await t.runAsync(() async {
          expect(await File(dispatcher.leases.single.filePath).exists(), false);
          expect(await ownerCopy.readAsBytes(), await original.readAsBytes());
        });
        late String proposalId, secondText;
        await t.runAsync(() async {
          secondText = await replacement.readAsString();
          final template =
              (await cli.execute({
                    'command': 'template-read',
                    'templateId': 'file',
                  }))['template']
                  as Map;
          final example = Map<String, dynamic>.from(
            ((template['submissionExample'] as Map)['items'] as List).single
                as Map,
          );
          final submitted = await cli.execute({
            'command': 'import-submit',
            'operationId': 'app-file-proposal',
            'items': [
              {
                ...example,
                'key': 'material',
                'name': 'AI 整理的合成文件',
                'attachments': [
                  {
                    'key': 'primary',
                    'name': '原文件',
                    'templateField': 'file',
                    'currentVersion': 2,
                    'versions': [
                      {'filePath': original.path},
                      {'filePath': replacement.path},
                    ],
                  },
                ],
              },
            ],
          });
          expect(submitted['status'], 'pending');
          proposalId = submitted['proposalId'] as String;
          expect(await independent.information(), hasLength(1));
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
        await until(
          () =>
              find.byType(ProposalOriginalReading).evaluate().isNotEmpty &&
              t
                  .widgetList<LibraryDocument>(find.byType(LibraryDocument))
                  .any((d) => d.body == secondText),
        );
        expect(
          t
              .widgetList<LibraryDocument>(find.byType(LibraryDocument))
              .every((d) => d.format == 'markdown'),
          isTrue,
        );
        final proposal = t
            .widget<ProposalsPage>(find.byType(ProposalsPage))
            .controller;
        await until(() => proposal.canConfirm);
        await tap('proposal-confirm');
        await until(
          () =>
              proposal.detail?.summary.status ==
                  WorkspaceProposalStatus.completed &&
              !proposal.busy,
        );
        await t.runAsync(() async {
          final items = await independent.information();
          expect(items, hasLength(2));
          final item = items.singleWhere((i) => i.id != record.id);
          final fetched = fileOriginalFromJson(
            await independent.request('POST', '/v1/owner/files/read', {
              'record': recordRefToJson(
                WorkspaceRecordRef(WorkspaceRecordKind.information, item.id),
              ),
              'fieldKey': 'file',
              'version': 2,
            }),
          );
          expect(fetched.bytes, await replacement.readAsBytes());
        });
        expect(t.takeException(), isNull);
      } finally {
        await unmount();
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
