@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/grant_history_page.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/file_transport.dart';
import 'package:info_desktop/workspace/recycled_attachment_preview.dart';
import 'package:info_desktop/workspace/library_file.dart';
import '../../server/test/support/device_credential_fixture.dart';
import 'support/online_ui_harness.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previous = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = previous);
  testWidgets(
    'normal online App restores content versions and directory batches and shows accurate grant history',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      t.view.physicalSize = const Size(1500, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      DeviceCredentialFixture? f;
      RemoteWorkspaceSource? live;
      late PrivateConnectionProfileStore profiles;
      late core.InformationItem item;
      late core.InformationDirectory directory;
      try {
        await t.runAsync(() async {
          f = await DeviceCredentialFixture.create();
          profiles = PrivateConnectionProfileStore(
            '${f!.root.path}/ui-profile',
          );
          await profiles.save(
            ConnectionProfile(
              address: f!.owner.address.toString(),
              token: f!.token,
              serverId: f!.owner.serverId,
              certificate: f!.certificate,
            ),
          );
          directory = await f!.runtime.run(
            () => f!.runtime.service.owner.createDirectory('合成历史目录'),
          );
          item = await f!.runtime.run(
            () => f!.runtime.service.owner.createInformation('合成版本资料', '', [
              const core.FieldInput('正文', '', 'SYNTHETIC_OLD'),
            ], directoryId: directory.id),
          );
          // Existing local-era history intentionally has no recorded item version.
          // It must display accurately rather than being rejected by the new wire.
          await f!.runtime.run(() async {
            final service = f!.runtime.service;
            final field = core.FieldRef(item.id, item.fields.single.id),
                session = service.agent.openSession('合成历史聊天');
            final requested = service.agent.request(session, '合成历史用途', [field]);
            service.owner.approve(requested.id, [field]);
            await service.agent.read(
              service.agent.claim(session, requested.id).token,
              field,
            );
            await service.owner.correctValue(field, 'SYNTHETIC_NEW');
          });
        });
        await t.pumpWidget(OnlineDesktopLauncher(profiles: profiles));
        await ui.until(() => find.byType(LibraryPage).evaluate().isNotEmpty);
        live =
            t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
                as RemoteWorkspaceSource;
        final ref = WorkspaceRecordRef(
          WorkspaceRecordKind.information,
          item.id,
        );
        ui.phase = 'select record';
        await ui.tap('library-record-${ref.key}');
        await ui.until(
          () =>
              t
                  .widget<LibraryPage>(find.byType(LibraryPage))
                  .controller
                  .detail
                  ?.version ==
              2,
        );
        ui.phase = 'version comparison';
        await ui.tap('library-record-actions');
        await ui.until(() => find.text('内容版本').evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text('内容版本').last));
        await t.pump();
        await ui.tap('library-version-1');
        await ui.until(() => find.text('当前 v2 → 恢复为 v3').evaluate().isNotEmpty);
        expect(find.textContaining('SYNTHETIC_NEW'), findsWidgets);
        expect(find.textContaining('SYNTHETIC_OLD'), findsWidgets);
        await ui.tap('library-restore-version');
        await ui.until(
          () =>
              f!.repo.items.single.version == 3 &&
              find
                  .byKey(const ValueKey('library-restore-version'))
                  .evaluate()
                  .isEmpty,
        );
        expect(f!.repo.items.single.fields.single.value, 'SYNTHETIC_OLD');
        ui.phase = 'directory recycle';
        await ui.tap('library-directory-${directory.id}');
        await ui.until(
          () =>
              t
                  .widget<LibraryPage>(find.byType(LibraryPage))
                  .controller
                  .loadState !=
              WorkspaceLoad.loading,
        );
        await ui.tap('library-directory-actions-${directory.id}');
        await ui.until(() => find.text('移到回收站').evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text('移到回收站').last));
        await t.pump();
        await ui.until(
          () => find
              .byKey(const ValueKey('batch-recycle-counts'))
              .evaluate()
              .isNotEmpty,
        );
        expect(find.textContaining('1 个目录、1 条资料、0 项凭据'), findsWidgets);
        await ui.tap('batch-recycle-confirm');
        await ui.until(
          () =>
              f!.repo.items.isEmpty &&
              find
                  .byKey(const ValueKey('batch-recycle-confirm'))
                  .evaluate()
                  .isEmpty,
        );
        ui.phase = 'recycle list and whole restore';
        await ui.tap('library-open-recycle');
        final batch = f!.runtime.service.owner.libraryRecycleBatches.single;
        await ui.tap('library-recycle-batch-${batch.id}');
        await ui.until(() => find.text('恢复目录及内容').evaluate().isNotEmpty);
        await ui.tap('batch-recycle-confirm');
        await ui.until(
          () =>
              f!.repo.items.length == 1 &&
              find
                  .byKey(const ValueKey('batch-recycle-confirm'))
                  .evaluate()
                  .isEmpty,
        );
        expect(f!.repo.items.single.directoryId, directory.id);
        expect(f!.repo.items.single.fields.single.value, 'SYNTHETIC_OLD');
        ui.phase = 'grant history';
        await ui.tap('workspace-nav-history');
        await ui.until(
          () =>
              find.byType(GrantHistoryPage).evaluate().isNotEmpty &&
              t
                      .widget<GrantHistoryPage>(find.byType(GrantHistoryPage))
                      .controller
                      .detail !=
                  null,
        );
        final detail = t
            .widget<GrantHistoryPage>(find.byType(GrantHistoryPage))
            .controller
            .detail!;
        expect(detail.summary.operationCount, 1);
        expect(detail.scopes.every((s) => !s.active), true);
        expect(find.textContaining('SYNTHETIC_OLD'), findsNothing);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        // The widget starts async disposal. Drain the same source before
        // shutting down its HTTPS fixture or checking fake-clock timers.
        if (live != null) await ui.resolve(live.dispose);
        if (f != null) await ui.resolve(() => f!.dispose());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
  testWidgets(
    'real recycled file preview renders exact bytes and clears when its entry is purged',
    (t) async {
      final ui = OnlineUiHarness(t);
      final f = (await ui.resolve(DeviceCredentialFixture.create));
      RemoteWorkspaceSource? source;
      try {
        source = await ui.resolve(
          () async => RemoteWorkspaceSource(
            await OwnerClient.connect(
              address: f.owner.address,
              token: f.token,
              trust: f.trust,
            ),
          ),
        );
        final candidate = await ui.resolve(
          () async => fileCandidateFromJson(
            (await f.owner.request('POST', '/v1/owner/files/uploads', {
              'operationId': 'recycled-ui-input',
              'originalName': 'recycled-ui.txt',
              'mediaType': 'text/plain',
              'bytes': base64Encode(utf8.encode('SYNTHETIC_RECYCLED_UI')),
            }))['candidate'],
          ),
        );
        final record = await ui.resolve(
          () => source!.importFile(
            WorkspaceFileImport(
              operationId: 'recycled-ui-create',
              selectionId: candidate.selectionId,
              name: 'Synthetic recycled file',
            ),
          ),
        );
        final detail = await ui.resolve(() => source!.readDetail(record));
        final deletion = await ui.resolve(
          () => source!.changeRecord(
            WorkspaceRecordChange(
              operationId: 'recycled-ui-delete',
              ref: record,
              expectedVersion: detail.version,
              action: WorkspaceRecordAction.recycle,
            ),
          ),
        );
        final entry = (await ui.resolve(
          () => source!.queryRecycled(),
        )).items.single;
        expect(entry.id, deletion.entryId);
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: RecycledAttachmentPreview(
                  source: source!,
                  entryId: entry.id,
                  fieldKey: detail.fieldIds.keys.single,
                ),
              ),
            ),
          ),
        );
        await ui.until(
          () => find.byType(LibraryFilePreviewView).evaluate().isNotEmpty,
        );
        expect(find.textContaining('recycled-ui.txt'), findsOneWidget);
        expect(
          t
              .widget<LibraryFilePreviewView>(
                find.byType(LibraryFilePreviewView),
              )
              .preview
              .text,
          'SYNTHETIC_RECYCLED_UI',
        );
        await ui.resolve(
          () => source!.changeRecord(
            WorkspaceRecordChange(
              operationId: 'recycled-ui-purge',
              ref: record,
              expectedVersion: entry.version,
              entryId: entry.id,
              action: WorkspaceRecordAction.purge,
            ),
          ),
        );
        await ui.until(
          () =>
              find.byType(LibraryFilePreviewView).evaluate().isEmpty &&
              find.text('重新读取附件').evaluate().isNotEmpty,
        );
        expect(find.textContaining('SYNTHETIC_RECYCLED_UI'), findsNothing);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (source != null) await ui.resolve(source.dispose);
        await ui.resolve(f.dispose);
      }
    },
  );
}
