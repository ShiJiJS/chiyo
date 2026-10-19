// Opt-in: inspect the exact SQLCipher backup widget flow and capacity states.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import '../test/information_file_backup_test.dart' as checks;

void main() {
  const directory = String.fromEnvironment(
    'ATTACHMENT_BACKUP_RENDER_DIRECTORY',
  );
  if (directory.isEmpty) return;
  const themeName = String.fromEnvironment(
    'ATTACHMENT_RENDER_THEME',
    defaultValue: 'purple',
  );
  final theme = DesktopColorTheme.values.firstWhere((v) => v.name == themeName);
  final boundary = GlobalKey();
  setUpAll(() async {
    for (final family in ['ProductSans', 'AppSans']) {
      await (FontLoader(family)
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf')))
          .load();
    }
    for (final font in {
      'SimSun': 'simsun.ttc',
      'Georgia': 'georgia.ttf',
      'Consolas': 'consola.ttf',
    }.entries) {
      final bytes = await File('C:/Windows/Fonts/${font.value}').readAsBytes();
      await (FontLoader(
        font.key,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    await Directory(directory).create(recursive: true);
  });
  checks.main(
    theme: theme,
    wrapApp: (app) => RepaintBoundary(key: boundary, child: app),
    capture: (tester, state) async {
      final target = state == 'settings-capacity'
          ? find.text('普通附件容量')
          : state == 'backup-restored'
          ? find.textContaining('资料已恢复')
          : state.startsWith('backup-')
          ? find.textContaining('普通附件：')
          : null;
      if (target != null && target.evaluate().isNotEmpty) {
        await tester.ensureVisible(target.first);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final picture =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$directory/$themeName-$state.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      picture.dispose();
    },
  );
}
