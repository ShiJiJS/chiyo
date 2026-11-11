import 'dart:io';
import 'dart:ui' as image;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/platform/local_library.dart';
import 'package:info_desktop/storage_desktop_launcher.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/settings_page.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_storage/info_storage.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/online_ui_harness.dart';
import 'support/native_semantics_lifetime.dart';
import 'support/preview_pending_menu_platform.dart';

class _SyntheticKeys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'local encrypted workspace uses the approved native UI and survives a normal restart',
    (t) async {
      final semantics = NativeSemanticsLifetime(t);
      await loadDesktopFonts();
      final preview = MacPreviewDesktop();
      await preview.initialize();
      final output = (await MacPreviewDesktop.channel.invokeMethod<String>(
        'createEvidenceDirectory',
      ))!;
      // ignore: avoid_print
      print('LOCAL_WORKSPACE_EVIDENCE=$output');
      final root = await Directory.systemTemp.createTemp('chiyo-native-local-');
      final keys = _SyntheticKeys();
      final boundary = GlobalKey();
      final native = PreviewPendingMenuPlatform();
      await native.showWindow();
      final ui = OnlineUiHarness(t);
      DesktopBootstrap? boot;
      Widget launcher(int generation) => RepaintBoundary(
        key: boundary,
        child: StorageDesktopLauncher(
          key: ValueKey(generation),
          profiles: PrivateConnectionProfileStore(root.path),
          platform: native,
          openLocal: (config, _) => openLocalLibrary(config, keyStore: keys),
          localBuilder: (value) {
            boot = value;
            return DesktopLauncher(bootstrap: value, useWorkspace: true);
          },
        ),
      );
      Future<void> capture(String name) async {
        await t.pumpAndSettle();
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final bitmap = await render.toImage(pixelRatio: 1);
        final data = await bitmap.toByteData(format: image.ImageByteFormat.png);
        await File(
          '$output/$name.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        bitmap.dispose();
      }

      try {
        await t.pumpWidget(launcher(1));
        await ui.until(() => find.byTooltip('添加资料').evaluate().isNotEmpty);
        await MacPreviewDesktop.channel.invokeMethod<void>('setContentSize', {
          'width': 1440.0,
          'height': 900.0,
        });
        await ui.until(
          () => t.view.physicalSize.width / t.view.devicePixelRatio == 1440,
        );
        expect(find.text('本地模式'), findsWidgets);
        await capture('local-empty');
        await ui.tap('library-create');
        await ui.until(() => find.text('通用资料').evaluate().isNotEmpty);
        await t.tap(find.text('通用资料').last);
        await ui.until(() => ui.key('library-edit-name').evaluate().isNotEmpty);
        Future<void> enter(String id, String value) => t.enterText(
          find.descendant(of: ui.key(id), matching: find.byType(TextField)),
          value,
        );
        await enter('library-edit-name', '本地验收资料');
        await enter('library-edit-body', '此条由原生 App 界面保存，重启后从加密数据库读回。');
        await ui.tap('library-edit-save');
        await ui.until(
          () => boot!.library!.service.owner.information.length == 1,
        );
        await capture('local-information');
        await ui.tap('workspace-nav-settings');
        final settings = t
            .widget<WorkspaceSettingsPage>(find.byType(WorkspaceSettingsPage))
            .controller;
        await ui.until(
          () => settings.value != null && !settings.loading && !settings.frozen,
        );
        await ui.resolve(() => settings.setTheme(WorkspaceTheme.dark));
        await ui.tap('settings-section-connection');
        await ui.until(() => find.text('资料保存在本机。').evaluate().isNotEmpty);
        await capture('local-settings-dark');
        await t.tap(find.text('返回工作区'));
        await t.pumpAndSettle();
        await ui.resolve(
          () => boot!.runtime!.handleEvent(DesktopEvent.closeWindow),
        );
        expect(native.hidden, true);
        expect(boot!.runtime!.stopped, false);
        await ui.resolve(native.showWindow);
        final old = boot!;
        await t.pumpWidget(const SizedBox());
        await ui.resolve(old.close);
        await t.pumpWidget(launcher(2));
        await ui.until(() => find.byTooltip('添加资料').evaluate().isNotEmpty);
        expect(boot!.library!.service.owner.information.single.name, '本地验收资料');
        await capture('local-restarted-dark');
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (boot != null) await ui.resolve(boot!.close);
        await ui.resolve(() => root.delete(recursive: true));
        preview.dispose();
        semantics.finishAfterUnmount();
      }
    },
  );
}
