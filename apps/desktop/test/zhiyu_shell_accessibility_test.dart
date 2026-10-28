import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/zhiyu_shell.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    final fonts = await loadDesktopFonts();
    await Directory(evidence).create(recursive: true);
    await File('$evidence/fonts.json').writeAsString(jsonEncode(fonts));
  });
  for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        final name =
            'shell-${size.width.toInt()}-${brightness.name}-${scale.toInt()}00';
        testWidgets(
          '$name count text fits at actual scale and all destinations remain reachable',
          (t) async {
            t.view.physicalSize = size;
            t.view.devicePixelRatio = 1;
            t.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(t.view.resetPhysicalSize);
            addTearDown(t.view.resetDevicePixelRatio);
            addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
            WorkspacePage? selected;
            await t.pumpWidget(
              RepaintBoundary(
                key: const ValueKey('shell-capture'),
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: zhiyuTheme(brightness),
                  home: ZhiyuShell(
                    page: WorkspacePage.settings,
                    summary: const WorkspaceSummary(
                      records: 31,
                      pending: 1234,
                      proposals: 12,
                    ),
                    onNavigate: (p) => selected = p,
                    child: const SizedBox(),
                  ),
                ),
              ),
            );
            await t.pumpAndSettle();
            final geometry = <String, Object>{};
            for (final page in [
              WorkspacePage.approvals,
              WorkspacePage.proposals,
            ]) {
              final badge = find.byKey(
                    ValueKey('workspace-count-${page.name}'),
                  ),
                  rich = find.descendant(
                    of: badge,
                    matching: find.byType(RichText),
                  ),
                  paragraph = t.renderObject<RenderParagraph>(rich),
                  rect = t.getRect(badge);
              final painter = TextPainter(
                text: paragraph.text,
                textDirection: paragraph.textDirection,
                textScaler: paragraph.textScaler,
                maxLines: paragraph.maxLines,
                strutStyle: paragraph.strutStyle,
                locale: paragraph.locale,
                textHeightBehavior: paragraph.textHeightBehavior,
              )..layout();
              geometry[page.name] = {
                'x': rect.left,
                'y': rect.top,
                'width': rect.width,
                'height': rect.height,
                'requiredTextHeight': painter.height,
              };
              // Preserve the complete selected text line, not just the widget's constrained size.
              expect(
                rect.height,
                greaterThanOrEqualTo(painter.height - 0.01),
                reason:
                    '${page.name}: fixed badge height must not clip scaled count text',
              );
              final label = find.descendant(
                of: find.byKey(ValueKey('workspace-nav-${page.name}')),
                matching: find.text(page.label),
              );
              expect(
                (t.getCenter(label).dy - rect.center.dy).abs(),
                lessThan(1),
              );
              if (scale == 1) expect(rect.height, 20);
              painter.dispose();
            }
            final bar = t.getRect(find.byKey(const ValueKey('zhiyu-appbar')));
            if (scale == 1) expect(bar.height, 66);
            if (evidence.isNotEmpty) {
              await t.runAsync(() async {
                final boundary = t.renderObject<RenderRepaintBoundary>(
                      find.byKey(const ValueKey('shell-capture')),
                    ),
                    image = await boundary.toImage(pixelRatio: 1),
                    bytes = await image.toByteData(
                      format: ui.ImageByteFormat.png,
                    );
                await File(
                  '$evidence/$name.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
                await File(
                  '$evidence/$name.json',
                ).writeAsString(jsonEncode(geometry));
              });
            }
            for (final page in WorkspacePage.values) {
              final nav = find.byKey(ValueKey('workspace-nav-${page.name}'));
              await t.ensureVisible(nav);
              await t.tap(nav);
              await t.pumpAndSettle();
              expect(selected, page);
            }
            expect(t.takeException(), isNull);
          },
        );
      }
    }
  }
}
