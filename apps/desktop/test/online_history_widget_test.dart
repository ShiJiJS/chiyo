import 'dart:io';
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
}
