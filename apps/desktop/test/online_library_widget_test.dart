import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'support/online_ui_harness.dart';
import 'package:info_desktop/workspace/classification_page.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_move_controller.dart';
import 'package:info_desktop/workspace/library_drag.dart';
import 'package:flutter/gestures.dart';
import 'package:info_desktop/workspace/proposals_page.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previous = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = previous);
  testWidgets(
    'normal online App manages hierarchy and tags, moves multiple rows, drags manual order and approves scoped organization',
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
      RemoteWorkspaceSource? source;
      final ui = OnlineUiHarness(t);
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
          'Online library UI did not complete: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().join(' | ')}',
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

      await t.runAsync(() async {
        root = await Directory.systemTemp.createTemp(
          'chiyo-online-library-ui-',
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
        late String one, two;
        await t.runAsync(() async {
          Future<String> save(String operationId, String name) async =>
              (await independent.request(
                    'POST',
                    '/v1/owner/saves/ui-$operationId',
                    {
                      'name': name,
                      'description': '',
                      'fields': [
                        {
                          'name': '正文',
                          'description': '',
                          'text': 'PRIVATE_$name',
                        },
                      ],
                    },
                  ))['itemId']
                  as String;
          one = await save('one', '合成甲');
          two = await save('two', '合成乙');
        });
        Future<void> enter(String id, String value) async {
          await until(() => key(id).evaluate().isNotEmpty);
          final target = key(id).evaluate().single.widget is TextField
              ? key(id)
              : find.descendant(of: key(id), matching: find.byType(TextField));
          await t.enterText(target, value);
          await t.pump();
        }

        LibraryController model() =>
            t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
        await t.pumpWidget(OnlineDesktopLauncher(profiles: profiles));
        await until(
          () =>
              find.byType(LibraryPage).evaluate().isNotEmpty &&
              model().results?.total == 2,
        );
        source = model().source as RemoteWorkspaceSource;
        await tap('workspace-nav-settings');
        await tap('settings-section-classifications');
        await until(
          () => find.byType(ClassificationPage).evaluate().isNotEmpty,
        );
        await tap('classification-create');
        await enter('library-directory-name', '工作');
        await tap('library-directory-save');
        await until(() => key('library-directory-save').evaluate().isEmpty);
        late String parent, child;
        await t.runAsync(() async {
          parent = runtime.service.owner.directories
              .singleWhere((d) => d.name == '工作')
              .id;
        });
        await tap('classification-child-$parent');
        await enter('library-directory-name', '配置');
        await tap('library-directory-save');
        await until(() => key('library-directory-save').evaluate().isEmpty);
        await t.runAsync(() async {
          child = runtime.service.owner.directories
              .singleWhere((d) => d.name == '配置')
              .id;
        });
        await tap('classification-edit-$parent');
        await enter('library-directory-name', '设备');
        await tap('library-directory-save');
        await until(() => key('library-directory-save').evaluate().isEmpty);
        await tap('classification-kind-tag');
        await tap('classification-create');
        await enter('classification-tag-name', '待整理');
        await tap('classification-tag-save');
        await until(() => key('classification-tag-save').evaluate().isEmpty);
        await tap('workspace-nav-library');
        await until(
          () =>
              find.byType(LibraryPage).evaluate().isNotEmpty &&
              model().results?.total == 2 &&
              model().loadState == WorkspaceLoad.ready &&
              model().catalog!.directories.any((d) => d.id == child) &&
              model().catalog!.tags.any((t) => t.name == '待整理'),
        );
        expect(
          model().catalog!.directories
              .singleWhere((d) => d.id == child)
              .parentId,
          parent,
        );
        await tap('library-select-mode');
        await tap('library-record-information:$one');
        await tap('library-record-information:$two');
        expect(model().selectedCount, 2);
        await tap('library-selection-move');
        await tap('library-move-pick-target');
        await until(() => find.text('设备 / 配置').evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text('设备 / 配置')));
        await t.pumpAndSettle();
        await until(() {
          final builder = find
              .ancestor(
                of: key('library-move-confirm'),
                matching: find.byType(ListenableBuilder),
              )
              .first;
          final move =
              t.widget<ListenableBuilder>(builder).listenable
                  as LibraryMoveController;
          return move.preview?.targetId == child && move.canSave;
        });
        await t.pump();
        await tap('library-move-confirm');
        await until(
          () =>
              key('library-move-confirm').evaluate().isEmpty &&
              !model().selecting,
        );
        await t.runAsync(() async {
          final all = await independent.information();
          expect(all.every((i) => i.directoryId == child), isTrue);
        });
        await tap('library-sort');
        await t.runAsync(() => t.tap(find.text('手动顺序')));
        await t.pump();
        await until(
          () =>
              model().query.sort == WorkspaceSort.manual &&
              model().loadState == WorkspaceLoad.ready,
        );
        final from = key('library-record-information:$two'),
            dest = key('library-record-information:$one');
        await until(() {
          final handle = find.ancestor(
            of: from,
            matching: find.byType(LibraryDragHandle),
          );
          return handle.evaluate().isNotEmpty &&
              t.widget<LibraryDragHandle>(handle.first).enabled;
        });
        await t.ensureVisible(from);
        await t.pump();
        final gesture = await t.startGesture(
          t.getCenter(from),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveBy(const Offset(24, 0));
        await t.pump();
        await gesture.moveTo(t.getRect(dest).topCenter + const Offset(0, 10));
        await t.pump(const Duration(milliseconds: 50));
        expect(key('library-drop-hint'), findsOneWidget);
        await t.runAsync(gesture.up);
        await until(
          () =>
              model().loadState == WorkspaceLoad.ready &&
              model().results!.items.first.ref.id == two,
        );
        expect(key('library-move-confirm'), findsNothing);
        await t.pumpWidget(const SizedBox());
        await ui.resolve(() => source!.dispose());
        source = null;
        await t.pumpWidget(
          OnlineDesktopLauncher(
            key: const ValueKey('reopened-library'),
            profiles: profiles,
          ),
        );
        await until(
          () =>
              find.byType(LibraryPage).evaluate().isNotEmpty &&
              model().results?.total == 2,
        );
        source = model().source as RemoteWorkspaceSource;
        expect(model().query.sort, WorkspaceSort.manual);
        expect(model().results!.items.first.ref.id, two);
        expect(
          model().catalog!.directories.singleWhere((d) => d.id == parent).name,
          '设备',
        );
        expect(model().catalog!.tags.single.name, '待整理');
        late String taskId;
        await t.runAsync(() async {
          final task = await cli.execute({
            'command': 'organize-request',
            'purpose': '整理合成分类',
            'itemIds': [one, two],
          });
          expect(task['status'], 'pending');
          taskId = task['taskId'] as String;
        });
        await tap('workspace-nav-approvals');
        await until(() => key('approval-select-$taskId').evaluate().isNotEmpty);
        await tap('approval-select-$taskId');
        await until(() => key('approval-scope-$two').evaluate().isNotEmpty);
        await tap('approval-scope-$two');
        await tap('approval-approve');
        await until(() => key('approval-approve').evaluate().isEmpty);
        await t.runAsync(() async {
          final meta = await cli.execute({
            'command': 'organize-metadata',
            'taskId': taskId,
          });
          expect(meta['status'], 'ok');
          expect((meta['items'] as List).single['id'], one);
          expect(jsonEncode(meta), isNot(contains('PRIVATE_')));
          final change = core.OrganizationChange(
            itemId: one,
            baseVersion: (meta['items'] as List).single['version'] as int,
            directoryId: child,
            tagNames: ['已整理'],
          );
          expect(
            (await cli.execute({
              'command': 'organize-submit',
              'taskId': taskId,
              'changes': [change.toJson()],
            }))['status'],
            'confirmed',
          );
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
                  taskId,
        );
        final report = t
            .widget<ProposalsPage>(find.byType(ProposalsPage))
            .controller
            .detail!;
        expect(report.summary.kind, WorkspaceProposalKind.organization);
        expect(report.organization, isNotNull);
        expect(find.textContaining('已整理'), findsWidgets);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (source != null) await ui.resolve(() => source!.dispose());
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
