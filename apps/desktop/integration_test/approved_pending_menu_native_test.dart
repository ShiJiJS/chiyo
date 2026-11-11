import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/online_desktop_runtime.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/proposals_page.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/settings_page.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:integration_test/integration_test.dart';

import 'support/preview_pending_menu_platform.dart';
import '../test/support/online_ui_harness.dart';
import 'support/native_semantics_lifetime.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const config = String.fromEnvironment('CHIYO_NATIVE_CONNECTION_FIXTURE');
  testWidgets(
    'real Mac pending menu scrolls, navigates and approves through the live workspace',
    (t) async {
      final semantics = NativeSemanticsLifetime(t);
      final fixture =
          jsonDecode(utf8.decode(base64Decode(config))) as Map<String, dynamic>;
      await loadDesktopFonts();
      final desktop = MacPreviewDesktop();
      await desktop.initialize();
      final evidence = (await MacPreviewDesktop.channel.invokeMethod<String>(
        'createEvidenceDirectory',
      ))!;
      // ignore: avoid_print
      print('PENDING_MENU_NATIVE_EVIDENCE=$evidence');
      final root = await Directory.systemTemp.createTemp('chiyo-native-menu-');
      final store = PrivateConnectionProfileStore(root.path);
      await store.save(ConnectionProfile.fromJson(fixture));
      final native = PreviewPendingMenuPlatform();
      final ui = OnlineUiHarness(t);
      RemoteWorkspaceSource? source;
      try {
        await t.pumpWidget(
          OnlineDesktopLauncher(
            profiles: store,
            desktopPlatform: native,
            deviceFilesDirectory: '${root.path}/files',
          ),
        );
        await ui.until(
          () =>
              native.state['approvalCount'] == 1 &&
              native.state['proposalCount'] == 1,
        );
        final app = t.widget<WorkspaceApp>(find.byType(WorkspaceApp));
        source = app.source as RemoteWorkspaceSource;
        final runtime = app.desktop! as OnlineDesktopRuntime;
        final live = source;
        Future<void> show() async {
          expect(await ui.resolve(() => native.native<bool>('show')), true);
        }

        Future<void> capture(
          String name, {
          bool long = false,
          bool bottom = false,
        }) async {
          Future<Map<Object?, Object?>?> bitmap() =>
              ui.resolve(() => native.native<Map<Object?, Object?>>('capture'));
          var rendered = await bitmap();
          if (rendered == null && !bottom) {
            await show();
            rendered = await bitmap();
          }
          expect(
            rendered,
            isNotNull,
            reason: 'AppKit popover should be open for $name',
          );
          expect(
            (rendered![bottom ? 'bottomInset' : 'topInset'] as num).abs(),
            lessThanOrEqualTo(2),
          );
          if (long) {
            expect(
              rendered['documentHeight'] as num,
              greaterThan(rendered['visibleHeight'] as num),
            );
          }
          await File(
            '$evidence/$name.png',
          ).writeAsBytes(rendered['png']! as Uint8List);
        }

        Future<void> activate(String title) async {
          expect(
            await ui.resolve(
              () => native.native<bool>('activate', {'title': title}),
            ),
            true,
          );
        }

        await ui.tap('workspace-nav-proposals');
        final proposals = t
            .widget<ProposalsPage>(find.byType(ProposalsPage))
            .controller;
        await ui.resolve(() => proposals.search('不匹配的过滤词'));
        expect(proposals.keyword, '不匹配的过滤词');
        await ui.until(() => runtime.preferences != null);
        await show();
        await capture('menu-light-long', long: true);
        await activate('录入提案 1');
        await capture('menu-light-proposals');
        await ui.resolve(runtime.hideWindow);
        expect(native.hidden, true);
        await show();
        await activate('查看提案');
        await ui.until(
          () =>
              find.byType(ProposalsPage).evaluate().isNotEmpty &&
              t
                      .widget<ProposalsPage>(find.byType(ProposalsPage))
                      .controller
                      .detail
                      ?.summary
                      .id ==
                  fixture['proposalId'],
        );
        expect(native.hidden, false);
        expect(proposals.keyword, isEmpty);

        await ui.tap('workspace-nav-settings');
        final settings = t
            .widget<WorkspaceSettingsPage>(find.byType(WorkspaceSettingsPage))
            .controller;
        await ui.until(
          () => settings.value != null && !settings.loading && !settings.frozen,
        );
        await ui.resolve(() => settings.setTheme(WorkspaceTheme.dark));
        await ui.until(() => native.state['dark'] == true);
        await show();
        await activate('访问审批 1');
        await capture('menu-dark-long', long: true);
        expect(await ui.resolve(() => native.native<bool>('bottom')), true);
        await capture('menu-dark-bottom', bottom: true);
        await activate('批准');
        await ui.until(() => native.state['approvalCount'] == 0);
        await capture('menu-dark-no-approvals');
        final approved = await ui.resolve(
          () => live.approvals.read(fixture['requestId'] as String),
        );
        expect(approved.request.state, WorkspaceApprovalState.approved);
        expect(
          approved.fieldExpiresAt!.difference(approved.decidedAt!),
          const Duration(hours: 2),
        );
        expect(approved.approved, hasLength(29));
        expect(
          (await ui.resolve(
            () => live.proposals.read(fixture['proposalId'] as String),
          )).summary.pending,
          true,
        );
        await activate('录入提案 1');
        await activate('查看提案');
        await ui.tap('proposal-reject');
        await ui.until(
          () =>
              native.state['proposalCount'] == 0 &&
              !proposals.frozen &&
              !proposals.loading &&
              !proposals.reading,
        );
        await show();
        await capture('menu-dark-empty');
        runtime.setMenuOffline(true);
        await ui.until(() => native.state['location'] == '连接已断开');
        await show();
        await capture('menu-dark-offline');
        expect(await ui.resolve(runtime.hideWindow), true);
        expect(native.hidden, true);
        await ui.resolve(runtime.quit);
        expect(runtime.resourcesClosed, true);
        expect(native.terminated, true);
        // ignore: avoid_print
        print('PENDING_MENU_HIDDEN_QUIT_VERIFIED');
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        await ui.resolve(() async {
          await source?.dispose();
          // Keep the integration runner alive when removing the test status item.
          await native.native<bool>('showWindow');
          await native.native<void>('reset');
          await root.delete(recursive: true);
        });
        semantics.finishAfterUnmount();
        desktop.dispose();
      }
    },
    skip: config.isEmpty,
  );
}
