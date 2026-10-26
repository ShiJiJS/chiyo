import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'support/native_frame_recording.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'isolated Zhiyu native controls, motion, large text and reduced motion',
    (tester) async {
      var directory = const String.fromEnvironment('UI_EVIDENCE_DIR');
      const python = String.fromEnvironment('VIDEO_PYTHON_EXECUTABLE');
      const encoderScript = String.fromEnvironment('VIDEO_ENCODER_SCRIPT');
      if ((!Platform.isWindows && !Platform.isMacOS) ||
          (Platform.isWindows &&
              (directory.isEmpty || python.isEmpty || encoderScript.isEmpty))) {
        throw StateError(
          'Desktop platform and explicit evidence/encoder paths are required',
        );
      }
      final fonts = await loadDesktopFonts();
      final desktop = Platform.isMacOS ? MacPreviewDesktop() : null;
      final nativeState = await desktop?.initialize();
      if (desktop != null) {
        directory = (await MacPreviewDesktop.channel.invokeMethod<String>(
          'createEvidenceDirectory',
        ))!;
        for (final name in [
          'database_key',
          'tool_directories',
          'backup_files',
          'desktop',
        ]) {
          await expectLater(
            MethodChannel('agent_info_manage/$name').invokeMethod<void>('read'),
            throwsA(isA<MissingPluginException>()),
            reason: 'Production channel $name must be absent in preview',
          );
        }
      }
      final root = Directory(directory);
      await root.create(recursive: true);
      final boundary = GlobalKey();
      final checks = <String>[];
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: PreviewWorkspace(desktop: desktop),
        ),
      );
      await tester.pumpAndSettle();
      final initial = tester.element(
        find.byKey(const ValueKey('preview-guide')),
      );
      final nativeDpr = tester.view.devicePixelRatio;
      final nativeSize = tester.view.physicalSize;
      final initialScale = MediaQuery.textScalerOf(initial).scale(14) / 14;

      Future<void> tap(Finder target) async {
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> guide() => tap(find.byKey(const ValueKey('preview-guide')));
      Future<void> key(LogicalKeyboardKey value) async {
        await tester.sendKeyEvent(value);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$directory/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      final recording = NativeFrameRecording(
        boundary,
        root,
        python,
        encoderScript,
      );
      addTearDown(recording.dispose);
      await recording.start();
      recording.mark('light-hover');
      final pointer = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await pointer.addPointer(location: Offset.zero);
      await pointer.moveTo(
        tester.getCenter(find.byKey(const ValueKey('workspace-nav-approvals'))),
      );
      await tester.pumpAndSettle();
      recording.mark('switch-page');
      await tap(find.byKey(const ValueKey('workspace-nav-approvals')));
      recording.mark('open-dialog');
      await guide();
      await screenshot('light-dialog');
      recording.mark('open-menu');
      await tap(find.text('文本'));
      await screenshot('light-menu');
      await key(LogicalKeyboardKey.arrowDown);
      await key(LogicalKeyboardKey.enter);
      expect(find.text('多行文本'), findsOneWidget);
      checks.add('light-menu-keyboard-selection');
      recording.mark('save-feedback');
      await tap(find.byKey(const ValueKey('preview-action')));
      expect(find.text('已保存到预览资料'), findsOneWidget);
      await key(LogicalKeyboardKey.escape);
      expect(find.byType(DesktopDialog), findsNothing);
      final focus = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<DesktopButton>();
      expect(focus?.key, const ValueKey('preview-guide'));
      checks.add('dialog-escape-restores-focus');
      recording.mark('rapid-open-close');
      await tester.tap(find.byKey(const ValueKey('preview-guide')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopDialog), findsNothing);
      checks.add('rapid-close-removes-modal');
      await guide();
      recording.mark('dark-theme');
      await tap(find.byKey(const ValueKey('preview-theme-dark')));
      await guide();
      await tap(find.text('文本'));
      await screenshot('dark-menu');
      await key(LogicalKeyboardKey.escape);
      await key(LogicalKeyboardKey.escape);
      checks.add('dark-menu-and-modal');
      await pointer.removePointer();
      await tester.pumpAndSettle();
      await recording.stop('native-controls');

      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      await guide();
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(DesktopDialog)),
        ).scale(14),
        28,
      );
      await tester.ensureVisible(find.text('字段形式'));
      await screenshot('dark-large-text');
      final viewport = tester.getRect(find.byType(DesktopDialog));
      final done = tester.getRect(find.text('完成'));
      expect(done.bottom, lessThanOrEqualTo(viewport.bottom));
      await tap(find.text('完成'));
      checks.add('native-rendered-200-percent-text-scroll-and-actions');

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpAndSettle();
      await guide();
      expect(
        MediaQuery.disableAnimationsOf(
          tester.element(find.byType(DesktopDialog)),
        ),
        isTrue,
      );
      await tap(find.text('文本'));
      await key(LogicalKeyboardKey.escape);
      await key(LogicalKeyboardKey.escape);
      expect(find.byType(DesktopDialog), findsNothing);
      checks.add('reduced-motion-still-operable');

      await File('$directory/native-checks.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'platform': Platform.operatingSystem,
          'fonts': fonts,
          'nativeIsolationChecked': desktop != null,
          'nativePreview': nativeState,
          'physicalSize': {
            'width': nativeSize.width,
            'height': nativeSize.height,
          },
          'actualSystemDpr': nativeDpr,
          'initialTextScale': initialScale,
          'largeTextMethod':
              'test platform text scaler; not a system DPI change',
          'checks': checks,
          'productionBootstrapUsed': false,
          'databaseOpened': false,
          'inputScope':
              'native Flutter widget-input integration; OS input smoke recorded separately',
        }),
      );
      // The host collects precisely this self-created directory after the app
      // exits, encodes the recording, and removes the temporary source.
      // ignore: avoid_print
      print('ZHIYU_NATIVE_EVIDENCE=$directory');
      await tester.pumpWidget(const SizedBox());
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
