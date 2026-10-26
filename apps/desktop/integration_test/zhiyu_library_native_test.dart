import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'support/native_frame_recording.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'Mac library query, edit failure, related return and viewport matrix',
    (tester) async {
      if (!Platform.isMacOS) {
        throw StateError('This isolated check requires macOS.');
      }
      final fonts = await loadDesktopFonts(), desktop = MacPreviewDesktop();
      final native = await desktop.initialize();
      final directory = (await MacPreviewDesktop.channel.invokeMethod<String>(
        'createEvidenceDirectory',
      ))!;
      // ignore: avoid_print
      print('ZHIYU_NATIVE_EVIDENCE=$directory');
      final root = Directory(directory),
          boundary = GlobalKey(),
          checks = <String>[];
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: PreviewWorkspace(desktop: desktop),
        ),
      );
      await tester.pumpAndSettle();
      final model = tester
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller;
      Future<void> tap(Finder target) async {
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> enter(String key, String text) async {
        final target = find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(TextField),
        );
        await tester.ensureVisible(target);
        await tester.enterText(target, text);
        await tester.pumpAndSettle();
      }

      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$directory/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      Future<void> resize(Size size) async {
        await MacPreviewDesktop.channel.invokeMethod<void>('setContentSize', {
          'width': size.width,
          'height': size.height,
        });
        for (var frame = 0; frame < 60; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (tester.view.physicalSize / tester.view.devicePixelRatio == size) {
            break;
          }
        }
        expect(tester.view.physicalSize / tester.view.devicePixelRatio, size);
        await tester.pumpAndSettle();
      }

      await resize(const Size(1440, 900));
      expect(
        await MacPreviewDesktop.channel.invokeMethod<bool>(
          'activateMenu',
          'settings',
        ),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(
        await MacPreviewDesktop.channel.invokeMethod<bool>(
          'activateMenu',
          'search',
        ),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('library-search')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      checks.add('native-search-menu-opens-library-and-focuses-search');
      final recording = NativeFrameRecording(boundary, root, '', '');
      addTearDown(recording.dispose);
      await recording.start();
      recording.mark('query-server-and-tag');
      await tap(find.byKey(const ValueKey('library-type-filter')));
      await tap(find.text('服务器信息').last);
      await tap(find.byKey(const ValueKey('library-tag-filter')));
      await tap(find.text('生产环境').last);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        '日本',
      );
      await tester.pumpAndSettle();
      expect(model.results!.total, 1);
      expect(model.selection?.id, 'azure');
      await screenshot('filtered-1440-light');
      checks.add('native-widget-filter-intersection');
      recording.mark('failed-save-preserves-draft');
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('offline', '保存失败，请重试。');
      await tap(find.text('编辑信息'));
      expect(
        await MacPreviewDesktop.channel.invokeMethod<bool>(
          'activateMenu',
          'settings',
        ),
        isFalse,
      );
      await enter('library-edit-description', '公网入口与 Mac 编辑核对');
      await tap(find.byKey(const ValueKey('library-edit-save')));
      expect(find.text('保存失败，请重试。'), findsOneWidget);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('library-edit-status')))
            .bottom,
        lessThan(
          tester.getRect(find.byKey(const ValueKey('library-edit-save'))).top,
        ),
      );
      await screenshot('edit-failure-light');
      await tap(find.byKey(const ValueKey('library-edit-save')));
      expect(find.byType(DesktopDialog), findsNothing);
      expect(model.detail!.record.description, '公网入口与 Mac 编辑核对');
      checks.add('native-widget-save-failure-draft-and-success-readback');
      recording.mark('open-related-and-return');
      await tap(
        find.byKey(const ValueKey('library-relation-information:aliyun')),
      );
      expect(model.selection?.id, 'aliyun');
      expect(model.query.typeId, 'server');
      expect(model.query.keyword, '');
      await tap(find.byKey(const ValueKey('library-back')));
      expect(model.selection?.id, 'azure');
      expect(model.query.keyword, '日本');
      checks.add('native-widget-related-query-return');
      await recording.stop('native-controls');
      final viewports = <Map<String, Object>>[];
      (model.source as SampleWorkspaceSource).reset();
      await model.apply(const WorkspaceQuery(directoryId: 'selfhost'));
      await tester.pumpAndSettle();
      for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
        await resize(size);
        for (final dark in [false, true]) {
          await tap(find.byKey(const ValueKey('preview-guide')));
          await tap(
            find.byKey(ValueKey('preview-theme-${dark ? 'dark' : 'light'}')),
          );
          tester
              .state<ScrollableState>(
                find
                    .descendant(
                      of: find.byKey(const ValueKey('library-detail-scroll')),
                      matching: find.byType(Scrollable),
                    )
                    .first,
              )
              .position
              .jumpTo(0);
          await screenshot(
            '${dark ? 'dark' : 'light'}-${size.width.toInt()}-library',
          );
          viewports.add({
            'width': size.width,
            'height': size.height,
            'dark': dark,
            'devicePixelRatio': tester.view.devicePixelRatio,
            'nativeWindowResized': true,
          });
        }
      }
      checks.add('native-window-two-content-viewports-and-both-themes');
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      await screenshot('dark-1280-large-text');
      await tap(find.text('编辑信息'));
      await enter('library-edit-name', 'Mac 放大文字核对');
      await tap(find.byKey(const ValueKey('library-edit-save')));
      expect(find.byType(DesktopDialog), findsNothing);
      checks.add('native-rendered-large-text-edit-and-save');
      await File('$directory/native-checks.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'platform': 'macos',
          'fonts': fonts,
          'nativeIsolationChecked': true,
          'nativePreview': native,
          'checks': checks,
          'contentViewports': viewports,
          'productionBootstrapUsed': false,
          'databaseOpened': false,
          'inputScope':
              'native Flutter framebuffer and Widget input; own AppKit window/menu only; no global OS input',
          'status':
              'in-progress; directory/tag operations, relation editing, revisions/recycle and final fidelity audit still pending',
        }),
      );
      await tester.pumpWidget(const SizedBox());
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
