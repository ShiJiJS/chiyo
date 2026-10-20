// Explicit visual evidence runner, not a native input/SQLCipher acceptance test.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import '../test/support/focused_fill_fixture.dart';

void main() {
  const directory = String.fromEnvironment('FILL_RENDER_DIRECTORY');
  if (directory.isEmpty) return;
  testWidgets(
    'render focused-fill application surfaces with real local fonts',
    (tester) async {
      await tester.runAsync(() async {
        for (final family in ['ProductSans', 'AppSans']) {
          await (FontLoader(family)..addFont(
                rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'),
              ))
              .load();
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        for (final entry in {
          'SimSun': 'simsun.ttc',
          'Georgia': 'georgia.ttf',
          'Consolas': 'consola.ttf',
        }.entries) {
          final file = File('C:/Windows/Fonts/${entry.value}');
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            await (FontLoader(
              entry.key,
            )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
          }
        }
        final output = Directory(directory);
        await output.create(recursive: true);
        for (final theme in DesktopColorTheme.values) {
          final f = await focusedFillFixture();
          final boundary = GlobalKey();
          Future<void> capture(String label, Size size) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '${output.path}/${theme.name}-$label.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          }

          try {
            await f.owner.setColorTheme(theme);
            tester.view.physicalSize = const Size(1440, 900);
            tester.view.devicePixelRatio = 1;
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: InformationApp(service: f.service, port: 0),
              ),
            );
            await capture('approval-1440', const Size(1440, 900));
            await capture('approval-1280', const Size(1280, 800));
            await tester.ensureVisible(
              find.byKey(const ValueKey('focused-fill-approve')),
            );
            await tester.tap(
              find.byKey(const ValueKey('focused-fill-approve')),
            );
            await capture('confirmation-1280', const Size(1280, 800));
            if (theme == DesktopColorTheme.mono) {
              f.repository.fail = true;
              await tester.tap(
                find.byKey(const ValueKey('fill-confirm-decision')),
              );
              await capture('save-failed-1280', const Size(1280, 800));
              f.repository.fail = false;
            }
            await tester.tap(
              find.byKey(const ValueKey('fill-confirm-decision')),
            );
            await tester.pumpAndSettle();
            f.driver.result = FocusedFillState.unknown;
            await f.fill('FILL-01');
            await tester.tap(find.byKey(const ValueKey('nav-3')));
            await capture('history-unknown-1280', const Size(1280, 800));
            await tester.ensureVisible(
              find.byKey(const ValueKey('fill-acknowledge-attention')),
            );
            await tester.tap(
              find.byKey(const ValueKey('fill-acknowledge-attention')),
            );
            await capture('attention-1280', const Size(1280, 800));
          } finally {
            await tester.pumpWidget(const SizedBox());
            await f.service.close();
          }
        }
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    },
  );
}
