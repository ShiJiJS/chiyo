import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/desktop_fonts.dart';

/// Real shared widgets rendered offscreen with Windows system fonts. This
/// evidence is explicitly not a native desktop / OS input verification.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    expect(
      await loadWindowsDesktopFonts(),
      isTrue,
      reason: 'Windows reference fonts must be available',
    );
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
    for (final dark in [false, true]) {
      testWidgets('${size.width} / ${dark ? 'dark' : 'light'}', (tester) async {
        debugDisableShadows = false;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() => debugDisableShadows = true);
        final captureKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(key: captureKey, child: const PreviewWorkspace()),
        );
        await tester.pumpAndSettle();
        if (dark) {
          await tester.tap(find.byKey(const ValueKey('preview-guide')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('preview-theme-dark')));
          await tester.pumpAndSettle();
        }
        final prefix =
            '../../build/zhiyu-ui/u01/flutter/${dark ? 'dark' : 'light'}-${size.width.toInt()}';
        final geometry = <String, Object>{};
        for (final (name, key) in [
          ('appbar', 'zhiyu-appbar'),
          ('brand', 'zhiyu-brand'),
          ('library', 'workspace-nav-library'),
          ('approvals', 'workspace-nav-approvals'),
          ('proposals', 'workspace-nav-proposals'),
          ('history', 'workspace-nav-history'),
          ('settings', 'workspace-nav-settings'),
          ('guide', 'preview-guide'),
        ]) {
          final rect = tester.getRect(find.byKey(ValueKey(key)));
          geometry[name] = {
            'x': rect.left,
            'y': rect.top,
            'width': rect.width,
            'height': rect.height,
          };
        }
        await tester.runAsync(() async {
          final file = File('$prefix-geometry.json');
          await file.parent.create(recursive: true);
          await file.writeAsString(
            const JsonEncoder.withIndent('  ').convert(geometry),
          );
        });
        Future<void> capture(String suffix) async {
          await tester.runAsync(() async {
            final boundary =
                captureKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File('$prefix-$suffix.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('shell');
        await tester.tap(find.byKey(const ValueKey('preview-guide')));
        await tester.pumpAndSettle();
        await capture('dialog');
        await tester.tap(find.text('文本'));
        await tester.pumpAndSettle();
        await capture('menu');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        debugDisableShadows = true;
      });
    }
  }
}
