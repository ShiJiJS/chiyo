import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/backup_page.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_remote/connection_profile.dart';
import '../../server/test/support/device_credential_fixture.dart';
import 'support/online_ui_harness.dart';
import 'support/synthetic_backup_picker.dart';

class _Http extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previous = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _Http());
  tearDownAll(() => HttpOverrides.global = previous);
  testWidgets(
    'normal online App backup settings export and restore using the original controls and real native publication',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      t.view.physicalSize = const Size(1500, 1150);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      final fixtures = <DeviceCredentialFixture>[];
      RemoteWorkspaceSource? live;
      late DeviceCredentialFixture origin, target;
      late String recovery, archive;
      Future<PrivateConnectionProfileStore> profile(
        DeviceCredentialFixture f,
      ) async {
        final p = PrivateConnectionProfileStore('${f.root.path}/ui-profile');
        await p.save(
          ConnectionProfile(
            address: f.owner.address.toString(),
            token: f.token,
            serverId: f.owner.serverId,
            certificate: f.certificate,
          ),
        );
        return p;
      }

      Future<void> settings() async {
        await ui.until(() => find.byType(LibraryPage).evaluate().isNotEmpty);
        live =
            t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
                as RemoteWorkspaceSource;
        await ui.tap('workspace-nav-settings');
        await ui.tap('settings-section-backups');
        await ui.until(
          () =>
              find.byType(WorkspaceBackupPage).evaluate().isNotEmpty &&
              t
                  .widget<WorkspaceBackupPage>(find.byType(WorkspaceBackupPage))
                  .controller
                  .available,
        );
      }

      Future<void> detach() async {
        final source = live;
        live = null;
        await t.pumpWidget(const SizedBox());
        if (source != null) await ui.resolve(source.dispose);
      }

      try {
        final sourceProfile = await ui.resolve(() async {
          origin = await DeviceCredentialFixture.create();
          fixtures.add(origin);
          final root = await origin.root.resolveSymbolicLinks();
          recovery = '$root/UI 独立恢复密钥.key';
          archive = '$root/UI 完整备份.aimbackup';
          await origin.runtime.run(
            () => origin.runtime.service.owner.createInformation('界面合成资料', '', [
              const core.FieldInput('正文', '', 'SYNTHETIC_UI_BACKUP'),
            ]),
          );
          return profile(origin);
        });
        final output = SyntheticBackupPicker()
          ..keyOutput = recovery
          ..archiveOutput = archive;
        await t.pumpWidget(
          OnlineDesktopLauncher(profiles: sourceProfile, outputPicker: output),
        );
        ui.phase = 'backup settings';
        await settings();
        await ui.tap('backup-open-export');
        await ui.tap('backup-enable');
        await ui.until(
          () => find
              .byKey(const ValueKey('backup-save-key'))
              .evaluate()
              .isNotEmpty,
        );
        await ui.tap('backup-pick-keyOutput');
        await ui.tap('backup-save-key');
        await ui.until(
          () =>
              find.text('恢复密钥已独立保存。').evaluate().isNotEmpty ||
              t
                      .widget<WorkspaceBackupPage>(
                        find.byType(WorkspaceBackupPage),
                      )
                      .controller
                      .value
                      ?.keySaved ==
                  true,
        );
        ui.phase = 'native archive publication';
        await ui.tap('backup-pick-archiveOutput');
        await ui.tap('backup-export');
        await ui.until(
          () =>
              t
                  .widget<WorkspaceBackupPage>(find.byType(WorkspaceBackupPage))
                  .controller
                  .result
                  ?.action
                  .name ==
              'export',
        );
        expect(await ui.resolve(() => File(recovery).exists()), isTrue);
        expect(
          await ui.resolve(() => File(archive).length()),
          greaterThan(4096),
        );
        expect(output.stages, 2);
        expect(t.takeException(), isNull);
        await ui.tap('backup-flow-close');
        await detach();

        final targetProfile = await ui.resolve(() async {
          target = await DeviceCredentialFixture.create();
          fixtures.add(target);
          return profile(target);
        });
        final input = SyntheticBackupPicker()
          ..archiveInput = archive
          ..keyInput = recovery;
        await t.pumpWidget(
          OnlineDesktopLauncher(profiles: targetProfile, outputPicker: input),
        );
        ui.phase = 'restore settings';
        await settings();
        await ui.tap('backup-open-restore');
        await ui.tap('backup-pick-archiveInput');
        await ui.tap('backup-pick-keyInput');
        await ui.tap('backup-inspect');
        await ui.until(
          () =>
              find.byKey(const ValueKey('backup-counts')).evaluate().isNotEmpty,
        );
        expect(
          t
              .widget<WorkspaceBackupPage>(find.byType(WorkspaceBackupPage))
              .controller
              .preview!
              .counts
              .values
              .values
              .any((n) => n > 0),
          isTrue,
        );
        ui.phase = 'restore and return to library';
        await ui.tap('backup-restore');
        await ui.until(
          () =>
              t
                  .widget<WorkspaceBackupPage>(find.byType(WorkspaceBackupPage))
                  .controller
                  .result
                  ?.action
                  .name ==
              'restore',
        );
        await ui.tap('backup-open-library');
        await ui.until(
          () =>
              find.byType(LibraryPage).evaluate().isNotEmpty &&
              find.text('界面合成资料').evaluate().isNotEmpty,
        );
        expect(
          target.repo.items.single.fields.single.value,
          'SYNTHETIC_UI_BACKUP',
        );
        expect(t.takeException(), isNull);
      } finally {
        await detach();
        for (final f in fixtures.reversed) {
          await ui.resolve(f.dispose);
        }
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
