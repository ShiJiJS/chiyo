import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import '../test/support/workspace_fixtures.dart';

// Runs only through the isolated preview identity. Production storage and
// credential channels are not registered by that identity.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('approved workspace layout on a native Mac window', (t) async {
    expect(Platform.isMacOS, true);
    await loadDesktopFonts();
    final desktop = MacPreviewDesktop();
    await desktop.initialize();
    final output = (await MacPreviewDesktop.channel.invokeMethod<String>(
      'createEvidenceDirectory',
    ))!;
    // ignore: avoid_print
    print('APPROVED_UI_EVIDENCE=$output');
    final boundary = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: PreviewWorkspace(desktop: desktop, inputsBuilder: fixtureInputs),
      ),
    );
    await t.pumpAndSettle();
    Future<void> tap(Finder f) async {
      if (await prepareFixtureAction(t, f)) return;
      await t.ensureVisible(f);
      await t.tap(f);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }

    Future<void> capture(String name) async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }

    for (final width in [1440.0, 1000.0]) {
      await MacPreviewDesktop.channel.invokeMethod<void>('setContentSize', {
        'width': width,
        'height': 900.0,
      });
      for (var i = 0; i < 60; i++) {
        await t.pump(const Duration(milliseconds: 16));
        if (t.view.physicalSize.width / t.view.devicePixelRatio == width) break;
      }
      expect(t.view.physicalSize.width / t.view.devicePixelRatio, width);
      for (final dark in [false, true]) {
        await tap(find.byKey(const ValueKey('preview-guide')));
        await tap(
          find.byKey(ValueKey('preview-theme-${dark ? 'dark' : 'light'}')),
        );
        for (final page in [
          'library',
          'approvals',
          'proposals',
          'history',
          'settings',
        ]) {
          await tap(find.byKey(ValueKey('workspace-nav-$page')));
          expect(find.byKey(const ValueKey('workspace-back')), findsNothing);
          await capture('${width.toInt()}-${dark ? 'dark' : 'light'}-$page');
        }
      }
    }
    await t.pumpWidget(const SizedBox());
  });
}
