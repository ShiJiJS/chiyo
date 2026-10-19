// Opt-in visual inspection; Memory storage and synthetic ordinary file bytes.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_shell.dart';
import 'package:info_desktop/import_proposals.dart';
import 'package:info_desktop/library.dart';
import 'package:info_desktop/ui.dart';
import '../test/support/information_attachment_fixture.dart';

void main() {
  const directory = String.fromEnvironment(
    'ATTACHMENT_CONSUMERS_RENDER_DIRECTORY',
  );
  if (directory.isEmpty) return;
  testWidgets(
    'inspect file revision, recycle and proposal consumers in the existing shell',
    (tester) async {
      await tester.runAsync(() async {
        for (final family in ['ProductSans', 'AppSans']) {
          await (FontLoader(family)..addFont(
                rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'),
              ))
              .load();
        }
        for (final font in {
          'SimSun': 'simsun.ttc',
          'Georgia': 'georgia.ttf',
          'Consolas': 'consola.ttf',
        }.entries) {
          final bytes = await File(
            'C:/Windows/Fonts/${font.value}',
          ).readAsBytes();
          await (FontLoader(
            font.key,
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        }
        await Directory(directory).create(recursive: true);
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        debugDisableShadows = false;
        try {
          for (final theme in DesktopColorTheme.values) {
            final f = await AttachmentUiFixture.create();
            final boundary = GlobalKey();
            Future<void> mount(Widget body, int index) async {
              await tester.pumpWidget(
                RepaintBoundary(
                  key: boundary,
                  child: MaterialApp(
                    key: UniqueKey(),
                    debugShowCheckedModeBanner: false,
                    theme: informationTheme(theme),
                    home: Scaffold(
                      body: DesktopShell(
                        service: f.service,
                        port: 0,
                        index: index,
                        onSelected: (_) {},
                        hasBackups: false,
                        colorTheme: theme,
                        onThemeChanged: (_) {},
                        child: body,
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
            }

            Future<void> capture(String state) async {
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              final image =
                  await (boundary.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage(pixelRatio: 1);
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$directory/${theme.name}-$state.png',
              ).writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            }

            try {
              await f.replace([0, 255, 8, 9]);
              await mount(
                InformationLibrary(owner: f.owner, initialItemId: f.item.id),
                1,
              );
              await tester.tap(find.text('修改历史 ↗'));
              await capture('revision-list');
              await tester.tap(find.text('恢复为新版本'));
              await capture('revision-compare');
              if (theme == DesktopColorTheme.purple) {
                tester.platformDispatcher.textScaleFactorTestValue = 2;
                await capture('revision-compare-text-200');
                tester.platformDispatcher.clearTextScaleFactorTestValue();
              }
              await tester.tap(find.text('取消'));
              await tester.pumpAndSettle();
              await tester.tap(find.text('×'));
              await tester.pumpAndSettle();
              await f.owner.deleteInformation(
                f.item.id,
                f.item.version,
                fieldId: f.item.fields.last.id,
              );
              await mount(
                InformationLibrary(owner: f.owner, initialItemId: f.item.id),
                1,
              );
              await tester.tap(find.text('回收站'));
              await capture('recycle-list');
              await tester.tap(find.text('查看内容'));
              await capture('recycle-preview');
              await tester.tap(find.text('关闭'));
              await tester.pumpAndSettle();
              await tester.tap(find.text('×'));
              await tester.pumpAndSettle();
              await f.owner.restoreRecycled(f.owner.recycleEntries.single.id);
              f.item = f.owner.information.single;
              await f.service.agent.submitUpdate(
                f.service.agent.openSession('核对求职资料'),
                UpdateInput(f.item.id, f.item.version, [
                  FieldChange.correct(f.item.fields.first.id, '更新后的姓名'),
                ]),
              );
              await mount(ImportProposalsPage(owner: f.owner), 2);
              await capture('proposal-retained-file');
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              await f.close();
            }
          }
        } finally {
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          debugDisableShadows = true;
        }
      });
    },
  );
}
