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
import 'package:info_desktop/desktop_motion.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'support/native_frame_recording.dart';
import 'support/native_motion_probe.dart';
import 'support/native_runtime.dart';

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
      final runtime = recordNativeRuntime(binding, directory);
      await root.create(recursive: true);
      // ignore: avoid_print
      print('ZHIYU_NATIVE_EVIDENCE=$directory');
      final boundary = GlobalKey();
      final checks = <String>[];
      final recording = NativeFrameRecording(
        boundary,
        root,
        python,
        encoderScript,
      );
      addTearDown(recording.dispose);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: PreviewWorkspace(desktop: desktop),
        ),
      );
      await tester.pumpAndSettle();
      final startupWindowSize = tester.view.physicalSize;
      if (desktop != null) {
        // List rows are lazy. Fix the S5 content viewport before looking up
        // rows; an inherited small window may never construct the target.
        const contentSize = Size(1440, 900);
        await MacPreviewDesktop.channel.invokeMethod<void>('setContentSize', {
          'width': contentSize.width,
          'height': contentSize.height,
        });
        for (var frame = 0; frame < 60; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (tester.view.physicalSize / tester.view.devicePixelRatio ==
              contentSize) {
            break;
          }
        }
        expect(
          tester.view.physicalSize / tester.view.devicePixelRatio,
          contentSize,
        );
        await tester.pumpAndSettle();
      }
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
        final physical = {
          LogicalKeyboardKey.escape: PhysicalKeyboardKey.escape,
          LogicalKeyboardKey.arrowDown: PhysicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.enter: PhysicalKeyboardKey.enter,
        }[value];
        if (physical == null) {
          throw UnsupportedError('Unmapped native test key');
        }
        // SDK name-based inference uses debugName, which is absent in AOT.
        await tester.sendKeyEvent(value, physicalKey: physical);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        if (Platform.isMacOS) {
          await recording.saveStill(name);
          return;
        }
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

      final nativeMotion = <String, Object>{};
      final motionFailures = <String>[];
      final windowStates = <String, Object?>{};
      Element? Function() observeElement(Finder target) {
        Element? current;
        return () {
          if (current == null || !current!.mounted) {
            final matches = target.evaluate().toList(growable: false);
            if (matches.isEmpty) return null;
            // Keep the same unique-target requirement as Finder.single.
            current = matches.single;
          }
          return current;
        };
      }

      double opacity(Element target) {
        var value = 1.0;
        target.visitAncestorElements((element) {
          if (element.widget case Opacity(:final opacity)) value *= opacity;
          if (element.widget case FadeTransition(:final opacity)) {
            value *= opacity.value;
          }
          return true;
        });
        return value;
      }

      Future<void> checkTrace(
        String name,
        List<Map<String, Object>> samples,
        int duration, {
        double? displacement,
      }) async {
        final frameError = (samples.last['frameMs']! as num) - duration;
        final wallError = (samples.last['wallMs']! as num) - duration;
        final translation = displacement == null
            ? null
            : (samples.first['y']! as double) - (samples.last['y']! as double);
        final passed =
            frameError.abs() <= 20 &&
            wallError.abs() <= 20 &&
            (translation == null || (translation - displacement!).abs() <= .2);
        nativeMotion[name] = {
          'targetMs': duration,
          'frameErrorMs': frameError,
          'wallErrorMs': wallError,
          'translation': translation,
          'passed': passed,
          'readWallDurationMs': samples.last['readWallMs'],
          'maximumFrameReadDelayMs': samples
              .map((s) => s['frameReadDelayMs']! as num)
              .reduce((a, b) => a > b ? a : b),
          'maximumObserverReadMs': samples
              .map((s) => s['observerReadMs']! as num)
              .reduce((a, b) => a > b ? a : b),
          'samples': samples,
        };
        windowStates[name] = await MacPreviewDesktop.channel
            .invokeMapMethod<String, Object?>('windowState');
        await File('$directory/native-motion.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert(nativeMotion),
        );
        // Preserve every stage and the recording before failing the same
        // timing/translation contract. A cold-frame miss must stay observable.
        if (!passed) {
          motionFailures.add(
            '$name: frame error $frameError ms, wall error $wallError ms, '
            'translation $translation (target $displacement)',
          );
        }
      }

      Future<void> traceOpacity(
        String name,
        Finder target,
        Future<void> Function() trigger,
        int duration,
        double displacement,
      ) async {
        // Keep the stage in failed receipts as well as successful traces.
        // ignore: avoid_print
        print('ZHIYU_NATIVE_MOTION=$name');
        final observed = observeElement(target);
        final pending = traceNativeMotion(
          read: () {
            final element = observed();
            final box = element?.findRenderObject();
            if (element == null || box is! RenderBox || !box.attached) {
              return null;
            }
            return {
              'opacity': opacity(element),
              'y': box.localToGlobal(Offset.zero).dy,
            };
          },
          complete: (sample) => (sample['opacity']! as double) >= 1 - .000001,
        );
        await trigger();
        await tester.pumpAndSettle();
        await checkTrace(
          name,
          await pending,
          duration,
          displacement: displacement,
        );
      }

      Future<void> nativeMotionChecks() async {
        windowStates['before'] = await MacPreviewDesktop.channel
            .invokeMapMethod<String, Object?>('windowState');
        await const MethodChannel(
          'agent_info_manage/secret_editor',
        ).invokeMethod<void>('cancel', {
          'requestId': 'synthetic-preview-no-draft',
        });
        expect(
          await MacPreviewDesktop.channel.invokeMethod<bool>(
            'activateMenu',
            'settings',
          ),
          isTrue,
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DesktopButton>(
                find.byKey(const ValueKey('workspace-nav-settings')),
              )
              .selected,
          isTrue,
        );
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
              .widget<DesktopButton>(
                find.byKey(const ValueKey('workspace-nav-library')),
              )
              .selected,
          isTrue,
        );
        await guide();
        expect(
          await MacPreviewDesktop.channel.invokeMethod<bool>(
            'activateMenu',
            'settings',
          ),
          isFalse,
        );
        await key(LogicalKeyboardKey.escape);
        checks.add('native-AppKit-menu-dispatch-and-modal-gating');
        checks.add('secure-editor-local-UI-channel-preserved');
        // U02 replaced the old foundation placeholder. Observe the real
        // record-specific entrance, not the approvals sidebar's static title.
        final azure = find.byKey(
          const ValueKey('library-record-information:azure'),
        );
        final aliyun = find.byKey(
          const ValueKey('library-record-information:aliyun'),
        );
        await tap(azure);
        await tester.ensureVisible(aliyun);
        await tester.pumpAndSettle();
        await traceOpacity(
          'detail',
          find.descendant(
            of: find.byWidgetPredicate(
              (widget) =>
                  widget is DesktopEntrance &&
                  widget.key ==
                      const ValueKey(
                        WorkspaceRecordRef(
                          WorkspaceRecordKind.information,
                          'aliyun',
                        ),
                      ),
            ),
            matching: find.byKey(const ValueKey('library-detail-title')),
          ),
          () async {
            await tester.tap(aliyun);
            await tester.pump();
          },
          180,
          3,
        );
        await traceOpacity(
          'dialog',
          find.text('设计说明与界面检查'),
          () async {
            await tester.tap(find.byKey(const ValueKey('preview-guide')));
            await tester.pump();
          },
          180,
          7,
        );
        await tester.ensureVisible(find.text('文本'));
        await tester.pumpAndSettle();
        await traceOpacity(
          'menu',
          find.text('文件'),
          () async {
            await tester.tap(find.text('文本'));
            await tester.pump();
          },
          120,
          -3,
        );
        await key(LogicalKeyboardKey.escape);
        final save = find.byKey(const ValueKey('preview-action'));
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        final observedBackground = observeElement(
          find.descendant(of: save, matching: find.byType(DecoratedBox)).first,
        );
        final hover = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await hover.addPointer(location: Offset.zero);
        await tester.pumpAndSettle();
        final hovering = traceNativeMotion(
          read: () {
            final box = observedBackground()?.findRenderObject();
            if (box is! RenderDecoratedBox || !box.attached) return null;
            final color = (box.decoration as BoxDecoration).color!;
            return {'argb': color.toARGB32(), 'red': color.r};
          },
          complete: (sample) =>
              ((sample['red']! as double) - const Color(0xffe9ecf1).r).abs() <
              .000000001,
        );
        await hover.moveTo(tester.getCenter(save));
        await tester.pumpAndSettle();
        await checkTrace('hover', await hovering, 150);
        final label = find.text('保存');
        final observedLabel = observeElement(label);
        final y = (observedLabel()!.findRenderObject()! as RenderBox)
            .localToGlobal(Offset.zero)
            .dy;
        final pressing = traceNativeMotion(
          read: () {
            final box = observedLabel()?.findRenderObject();
            if (box is! RenderBox || !box.attached) return null;
            return {'y': box.localToGlobal(Offset.zero).dy};
          },
          complete: (sample) => (sample['y']! as double) - y >= 1 - .000001,
        );
        final press = await tester.startGesture(
          tester.getCenter(save),
          kind: ui.PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        final pressed = await pressing;
        await checkTrace('pressed', pressed, 150, displacement: -1);
        await traceOpacity(
          'feedback',
          find.text('已保存到预览资料'),
          () async {
            await press.up();
            await tester.pump();
          },
          180,
          6,
        );
        await hover.removePointer();
        await key(LogicalKeyboardKey.escape);
        for (
          var frame = 0;
          frame < 40 && find.text('已保存到预览资料').evaluate().isNotEmpty;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('已保存到预览资料'), findsNothing);
        if (motionFailures.isEmpty) {
          checks.add('native-frame-and-wall-clock-motion-contract');
        }
      }

      if (desktop != null) {
        if (runtime['profileMode'] == true) {
          // This scope ends before framebuffer capture begins. Engine timing
          // is diagnostic; the original per-motion 20ms gates remain intact.
          await binding.watchPerformance(
            nativeMotionChecks,
            reportKey: 'unrecorded-native-motion',
          );
        } else {
          await nativeMotionChecks();
        }
      }

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
      // Match the deterministic rapid-close contract: dispatch during the
      // entrance (40ms of 180ms), after the new route has acquired focus.
      await tester.pump(const Duration(milliseconds: 40));
      await tester.sendKeyEvent(
        LogicalKeyboardKey.escape,
        physicalKey: PhysicalKeyboardKey.escape,
      );
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

      final contentViewports = <Map<String, Object>>[];
      if (desktop != null) {
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
        for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
          await MacPreviewDesktop.channel.invokeMethod<void>('setContentSize', {
            'width': size.width,
            'height': size.height,
          });
          for (var frame = 0; frame < 60; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            if (tester.view.physicalSize / tester.view.devicePixelRatio ==
                size) {
              break;
            }
          }
          expect(tester.view.physicalSize / tester.view.devicePixelRatio, size);
          await tester.pumpAndSettle();
          for (final dark in [false, true]) {
            await guide();
            await tap(
              find.byKey(ValueKey('preview-theme-${dark ? 'dark' : 'light'}')),
            );
            final prefix = '${dark ? 'dark' : 'light'}-${size.width.toInt()}';
            await screenshot('$prefix-shell');
            await guide();
            await screenshot('$prefix-dialog');
            await tap(find.text('文本'));
            await screenshot('$prefix-menu');
            await key(LogicalKeyboardKey.escape);
            await key(LogicalKeyboardKey.escape);
            contentViewports.add({
              'width': size.width,
              'height': size.height,
              'theme': dark ? 'dark' : 'light',
              'devicePixelRatio': tester.view.devicePixelRatio,
              'nativeWindowResized': true,
            });
          }
        }
        checks.add('native-NSWindow-resized-two-viewports-and-two-themes');
      }

      await File('$directory/native-checks.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'platform': Platform.operatingSystem,
          'startupWindowPhysicalSize': {
            'width': startupWindowSize.width,
            'height': startupWindowSize.height,
          },
          'runtime': runtime,
          'nativeWindowStates': windowStates,
          'unrecordedNativeMotionPerformance':
              binding.reportData?['unrecorded-native-motion'],
          'fonts': fonts,
          'nativeIsolationChecked': desktop != null,
          'nativePreview': nativeState,
          'physicalSize': {
            'width': nativeSize.width,
            'height': nativeSize.height,
          },
          'actualSystemDpr': nativeDpr,
          'initialTextScale': initialScale,
          'contentViewports': contentViewports,
          'largeTextMethod':
              'test platform text scaler; not a system DPI change',
          'checks': checks,
          'motionFailures': motionFailures,
          'productionBootstrapUsed': false,
          'databaseOpened': false,
          'inputScope':
              'native Flutter widget-input integration; OS input smoke recorded separately',
        }),
      );
      // The host collects precisely this self-created directory after the app
      // exits, encodes the recording, and removes the temporary source.
      await tester.pumpWidget(const SizedBox());
      expect(motionFailures, isEmpty, reason: 'Native motion contract');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
