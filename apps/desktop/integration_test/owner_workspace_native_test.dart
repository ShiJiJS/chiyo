// Isolated native rendering/widget-input check. Use check-owner-native.py;
// this is not a physical keyboard, Keychain or installed-app acceptance test.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/workspace/workspace_app.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 49);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('synthetic key only');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('native owner UI saves and reloads real encrypted information', (
    t,
  ) async {
    expect(Platform.isMacOS, isTrue);
    expect(const bool.fromEnvironment('OWNER_NATIVE_SYNTHETIC'), isTrue);
    final fonts = await loadDesktopFonts();
    expect(fonts.keys, containsAll(['Zhiyu System', 'PingFang SC', 'Menlo']));
    final root = await Directory.systemTemp.createTemp('owner-native-');
    DesktopBootstrap? bootstrap;
    EncryptedInformationRepository? repo;
    final boundary = GlobalKey();
    Future<void> settle() async {
      await t.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      expect(t.takeException(), isNull);
    }

    Future<void> stop() async {
      await t.pumpWidget(const SizedBox());
      await settle();
      await bootstrap?.runtime?.stop();
      bootstrap?.runtime?.dispose();
      bootstrap?.dispose();
      bootstrap = null;
    }

    Future<void> open() async {
      repo = await EncryptedInformationRepository.open(root.path, _Keys());
      bootstrap = DesktopBootstrap(
        port: 0,
        platform: NativeDesktopPlatform(),
        openLibrary: () async => DesktopLibrary(
          service: InformationService(repository: repo!),
          close: repo!.close,
          backups: repo!.backups,
        ),
      );
      await bootstrap!.start();
      expect(bootstrap!.state, DesktopStartupState.ready);
      await t.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: DesktopLauncher(bootstrap: bootstrap!, useWorkspace: true),
        ),
      );
      await settle();
      expect(find.byType(WorkspaceApp), findsOneWidget);
    }

    Future<void> tap(Finder finder) async {
      await t.ensureVisible(finder);
      await t.tap(finder);
      await settle();
    }

    Future<void> enter(String key, String text) async {
      final finder = find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      );
      await t.ensureVisible(finder);
      await t.enterText(finder, text);
      await settle();
    }

    try {
      await open();
      expect(repo!.items, isEmpty);
      await tap(find.byTooltip('添加资料').first);
      await tap(find.text('通用资料').last);
      await enter('library-edit-name', '原生合成资料');
      await enter('library-edit-body', 'synthetic native content');
      await tap(find.byKey(const ValueKey('library-edit-save')));
      final original = repo!.items.single;
      expect(original.name, '原生合成资料');
      expect(original.fields.single.value, 'synthetic native content');
      expect(find.text('原生合成资料'), findsWidgets);
      await stop();
      await open();
      final restored = repo!.items.single;
      expect(restored.id, original.id);
      expect(restored.fields.single.id, original.fields.single.id);
      expect(restored.fields.single.value, original.fields.single.value);
      expect(find.text('原生合成资料'), findsWidgets);
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final picture = await render.toImage(pixelRatio: 1);
      final png = await picture.toByteData(format: ui.ImageByteFormat.png);
      picture.dispose();
      binding.reportData = {
        'runtime': {'platform': Platform.operatingSystem, 'debugMode': true},
        'checks': [
          'real-native-runner',
          'real-sqlcipher',
          'formal-launcher',
          'widget-input-save',
          'library-reopen-identity',
          'mac-system-fonts',
        ],
        'scope':
            'native Debug rendering and synthetic widget input; same-process library reopen',
        'imagePngBase64': base64Encode(png!.buffer.asUint8List()),
      };
    } finally {
      await stop();
      await root.delete(recursive: true);
    }
  });
}
