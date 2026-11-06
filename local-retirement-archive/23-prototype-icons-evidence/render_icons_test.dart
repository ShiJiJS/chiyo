import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'file:///C:/Project/network_config/info-manage-worktrees/23-prototype-icons/apps/desktop/lib/prototype_icons.dart';

void main() {
  testWidgets('Render actual Flutter icon contact sheet', (tester) async {
    tester.view.physicalSize = const Size(1248, 288);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: boundaryKey,
          child: ColoredBox(
            color: const Color(0xffffffff),
            child: IconTheme(
              data: const IconThemeData(color: Color(0xff000000)),
              child: Column(
                children: [
                  for (final size in <double>[18, 26, 72])
                    Row(
                      children: [
                        for (final glyph in PrototypeIconGlyph.values)
                          SizedBox(
                            width: 96,
                            height: 96,
                            child: Center(
                              child: PrototypeIcon(glyph, size: size),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary = boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        'C:/Project/network_config/info-manage-worktrees/23-prototype-icons-evidence/flutter-icons.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
