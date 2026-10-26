import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_page.dart';

/// Real shared widgets rendered offscreen with installed platform fonts. This
/// evidence is explicitly not a native desktop / OS input verification.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = await loadDesktopFonts();
    const configured = String.fromEnvironment('UI_EVIDENCE_DIR');
    final output = Directory(
      configured.isEmpty
          ? '../../build/zhiyu-ui/u01/${Platform.operatingSystem}/offscreen'
          : configured,
    );
    await output.create(recursive: true);
    await File('${output.path}/fonts.json').writeAsString(jsonEncode(fonts));
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
        const configured = String.fromEnvironment('UI_EVIDENCE_DIR');
        final directory = configured.isEmpty
            ? '../../build/zhiyu-ui/u01/${Platform.operatingSystem}/offscreen'
            : configured;
        final prefix =
            '$directory/${dark ? 'dark' : 'light'}-${size.width.toInt()}';
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
        final libraryGeometry = <String, Object>{};
        for (final key in [
          'library-directory-pane',
          'library-results-pane',
          'library-detail-pane',
          'library-detail-title',
          'library-search',
          'library-record-information:azure',
        ]) {
          final target = find.byKey(ValueKey(key));
          if (target.evaluate().isEmpty) continue;
          final rect = tester.getRect(
            key == 'library-detail-pane'
                ? find
                      .descendant(
                        of: target,
                        matching: find.byType(DecoratedBox),
                      )
                      .first
                : target,
          );
          libraryGeometry[key] = {
            'x': rect.left,
            'y': rect.top,
            'width': rect.width,
            'height': rect.height,
          };
        }
        for (final label in ['连接概览', '登录凭据', 'tokyo.beichen.example']) {
          final target = find.text(label);
          if (target.evaluate().length != 1) continue;
          final rect = tester.getRect(target);
          libraryGeometry[label] = {
            'x': rect.left,
            'y': rect.top,
            'width': rect.width,
            'height': rect.height,
          };
        }
        final model = tester
            .widget<LibraryPage>(find.byType(LibraryPage))
            .controller;
        final record = model.results!.items.singleWhere(
          (r) => r.ref.id == 'azure',
        );
        final row = find.byKey(
          const ValueKey('library-record-information:azure'),
        );
        for (final entry in {
          'row-name': record.name,
          'row-summary': record.description,
          'row-type': record.type.name,
          'row-tag': record.tags.first.name,
        }.entries) {
          final target = find.descendant(
            of: row,
            matching: find.text(entry.value),
          );
          final rect = tester.getRect(target);
          libraryGeometry[entry.key] = {
            'x': rect.left,
            'y': rect.top,
            'width': rect.width,
            'height': rect.height,
          };
        }
        if (libraryGeometry.isNotEmpty) {
          await tester.runAsync(
            () => File('$prefix-library-geometry.json').writeAsString(
              const JsonEncoder.withIndent('  ').convert(libraryGeometry),
            ),
          );
        }
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

        await tester.tap(find.byKey(const ValueKey('library-type-filter')));
        await tester.pumpAndSettle();
        final popup = find.byWidgetPredicate(
          (w) =>
              w is Material &&
              w.clipBehavior == Clip.antiAlias &&
              w.shape is RoundedRectangleBorder &&
              (w.shape! as RoundedRectangleBorder).borderRadius
                      .resolve(TextDirection.ltr)
                      .topLeft ==
                  const Radius.circular(8),
        );
        expect(popup, findsOneWidget);
        final menuRect = tester.getRect(popup),
            anchorRect = tester.getRect(
              find.byKey(const ValueKey('library-type-filter')),
            );
        await tester.runAsync(
          () => File('$prefix-library-menu-geometry.json').writeAsString(
            jsonEncode({
              'menu': {
                'x': menuRect.left,
                'y': menuRect.top,
                'width': menuRect.width,
                'height': menuRect.height,
              },
              'anchor': {
                'x': anchorRect.left,
                'y': anchorRect.top,
                'width': anchorRect.width,
                'height': anchorRect.height,
              },
            }),
          ),
        );
        await capture('library-type-menu');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('preview-guide')));
        await tester.pumpAndSettle();
        await capture('dialog');
        await tester.ensureVisible(find.text('文本'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('文本'));
        await tester.pumpAndSettle();
        expect(find.text('多行文本'), findsOneWidget);
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
