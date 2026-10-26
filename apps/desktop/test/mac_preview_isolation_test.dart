import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

// Keep the binding's existing real-IO/fake-frame clocks. The policy guard
// normalizes paths without calling File factories, which would recurse.
final class _PreviewFiles extends IOOverrides {
  _PreviewFiles(this.root);
  final String root;
  final files = <String>[], directories = <String>[], rejected = <String>[];
  bool permitted(String path) {
    final normalized = Uri.file(
      path.startsWith('/') ? path : '$root/$path',
    ).normalizePath().toFilePath();
    return normalized.startsWith('/System/Library/Fonts/') ||
        normalized.startsWith(
          '/System/Library/AssetsV2/com_apple_MobileAsset_Font8/',
        ) ||
        normalized == '/System/Library/AssetsV2/com_apple_MobileAsset_Font8' ||
        normalized.startsWith('$root/assets/zhiyu_files/') ||
        normalized.startsWith('$root/build/unit_test_assets/') ||
        normalized.startsWith(
          '$root/test/',
        ); // Failure source diagnostics only.
  }

  void check(String path) {
    if (!permitted(path)) {
      rejected.add(path);
      throw StateError('Unexpected filesystem access');
    }
  }

  @override
  File createFile(String path) {
    check(path);
    files.add(path);
    return super.createFile(path);
  }

  @override
  Directory createDirectory(String path) {
    check(path);
    directories.add(path);
    return super.createDirectory(path);
  }
}

final class _PreviewNetwork extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('Network is outside UI preview');
  }
}

void main() {
  testWidgets(
    'Mac preview composition and U03 UI avoid production channels, network and personal paths',
    (t) async {
      final previousIo = IOOverrides.current,
          previousHttp = HttpOverrides.current;
      final filesystem = _PreviewFiles(Directory.current.absolute.path),
          network = _PreviewNetwork();
      IOOverrides.global = filesystem;
      HttpOverrides.global = network;
      addTearDown(() {
        IOOverrides.global = previousIo;
        HttpOverrides.global = previousHttp;
      });
      final forbidden = <String>[], calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channels = [
        'agent_info_manage/database_key',
        'agent_info_manage/backup_files',
        'agent_info_manage/desktop',
        'agent_info_manage/tool_directories',
        'agent_info_manage/focused_fill',
        'agent_info_manage/secret_editor',
      ];
      for (final name in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
          forbidden.add('$name/${call.method}');
          throw StateError('Production capability requested');
        });
      }
      messenger.setMockMethodCallHandler(MacPreviewDesktop.channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'initialize') {
          return {
            'isolated': true,
            'productionServices': false,
            'savedDirectories': false,
            'title': MacPreviewDesktop.windowTitle,
          };
        }
        if (call.method == 'setNavigationEnabled') return null;
        forbidden.add('preview/${call.method}');
        throw StateError('Unexpected native action');
      });
      addTearDown(() {
        for (final name in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(name), null);
        }
        messenger.setMockMethodCallHandler(MacPreviewDesktop.channel, null);
      });
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.runAsync(loadDesktopFonts);
      final desktop = MacPreviewDesktop();
      await desktop.initialize();
      await t.pumpWidget(PreviewWorkspace(desktop: desktop));
      await t.pumpAndSettle();
      final controller = t
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller;
      final source = controller.source;
      expect((await source.loadSummary()).records, 31);
      for (final name in ['个人档案', '域名与 HTTPS', '服务端开发简历', 'Azure SSH 私钥']) {
        await t.tap(find.byKey(const ValueKey('library-directory-all')));
        await t.pumpAndSettle();
        await t.enterText(find.byKey(const ValueKey('library-search')), name);
        await t.pumpAndSettle();
        final result = controller.results!.items.singleWhere(
          (r) => r.name == name,
        );
        await t.tap(find.byKey(ValueKey('library-record-${result.ref.key}')));
        await t.pumpAndSettle();
        expect(controller.detail?.record.ref, result.ref);
      }
      await t.tap(find.text('编辑信息'));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const ValueKey('credential-edit-note')),
        '隔离检查的合成备注',
      );
      await t.tap(find.byKey(const ValueKey('credential-edit-save')));
      await t.pumpAndSettle();
      const ssh = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
      expect((await source.credentials.read(ssh)).privateNote, '隔离检查的合成备注');
      expect((await source.readDetail(ssh)).values, isEmpty);
      await t.tap(find.byKey(const ValueKey('preview-guide')));
      await t.pumpAndSettle();
      await t.tap(find.text('重置预览资料'));
      await t.pumpAndSettle();
      expect((await source.credentials.read(ssh)).privateNote, isEmpty);
      expect((await source.loadSummary()).records, 31);
      expect(forbidden, isEmpty);
      expect(network.calls, 0);
      expect(filesystem.rejected, isEmpty);
      expect(filesystem.files, contains('/System/Library/Fonts/SFNS.ttf'));
      expect(calls.first.method, 'initialize');
      expect(
        calls.every(
          (c) => ['initialize', 'setNavigationEnabled'].contains(c.method),
        ),
        isTrue,
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
