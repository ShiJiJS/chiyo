import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/desktop_controls.dart';

// Current application, fake data only. Archived Round05 captures are not changed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final name in ['ProductSans', 'AppSans']) {
      await (FontLoader(name)
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf')))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final face in {
      'SimSun': 'simsun.ttc',
      'Georgia': 'georgia.ttf',
      'Consolas': 'consola.ttf',
    }.entries) {
      await (FontLoader(face.key)..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  '${Platform.environment['WINDIR']}/Fonts/${face.value}',
                ).readAsBytes(),
              ),
            ),
          ))
          .load();
    }
  });
  for (final theme in DesktopColorTheme.values) {
    for (final (scale, ratio) in [(1.0, 1.0), (1.0, 1.5), (2.0, 1.0)]) {
      testWidgets(
        '${theme.name} public controls at ${scale * 100}% text / DPR $ratio',
        (tester) async {
          debugDisableShadows = false;
          tester.view.physicalSize = Size(1280 * ratio, 800 * ratio);
          tester.view.devicePixelRatio = ratio;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          addTearDown(() => debugDisableShadows = true);
          final service = InformationService(
            repository: MemoryInformationRepository(),
          );
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            final closing = service.close();
            await tester.pump();
            await closing;
          });
          final owner = service.owner;
          await owner.setColorTheme(theme);
          final root = await owner.createDirectory('工作');
          var parent = root.id;
          for (final name in ['北辰项目', '服务', '运维']) {
            parent = (await owner.createDirectory(name, parentId: parent)).id;
          }
          for (var i = 0; i < 50; i++) {
            await owner.createDirectory(
              '项目 ${i.toString().padLeft(2, '0')} · 连接与部署资料',
              parentId: root.id,
            );
          }
          for (var i = 0; i < 100; i++) {
            await owner.createTag('标签 ${i.toString().padLeft(3, '0')}');
          }
          final docs = await owner
              .createInformation('文档服务', '项目文档入口与部署位置。', const [
                FieldInput('访问地址', '文档站入口', 'https://docs.beichen.example'),
                FieldInput('部署目录', '服务器上的位置', '/srv/beichen/docs'),
              ], directoryId: parent);
          final refs = docs.fields.map((f) => FieldRef(docs.id, f.id)).toList();
          for (var i = 0; i < 24; i++) {
            final session = service.agent.openSession('Codex');
            final request = service.agent.request(
              session,
              '检查项目服务 ${i + 1}',
              refs,
            );
            if (i < 18) owner.approve(request.id, refs);
          }
          await owner.createStringCredential(
            name: 'GitHub 访问令牌',
            publicPurpose: '代码仓库维护',
            suggestedBinding: 'GH_TOKEN',
            secret: 'fictional-capture-only',
          );
          await owner.createTemplate('服务器', '连接配置', const [
            TemplateFieldInput('地址', '服务器入口'),
          ]);
          await service.agent.submitImport(service.agent.openSession('Codex'), [
            ImportItemInput('个人介绍', '个人网站资料', const [
              FieldInput('简介', '', '个人网站介绍'),
            ]),
          ]);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: InformationApp(service: service, port: 0),
            ),
          );
          await tester.pumpAndSettle();
          Future<void> shot(String name) async {
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await render.toImage(pixelRatio: ratio);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                '../../build/library-ux/flutter/states/${theme.name}-${scale.toInt()}${ratio == 1 ? '' : '-dpr150'}-$name.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }

          Future<void> tap(Finder finder) async {
            await tester.ensureVisible(finder);
            await tester.pumpAndSettle();
            await tester.tap(finder);
            await tester.pumpAndSettle();
          }

          await shot('approval');
          await tap(find.byKey(const ValueKey('nav-1')));
          await shot('library');
          final mouse = await tester.createGesture(
            kind: ui.PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(
            tester.getCenter(find.byKey(ValueKey('directory-$parent'))),
          );
          await shot('tree-hover');
          final rowPoint = tester.getCenter(
            find.byKey(ValueKey('directory-$parent')),
          );
          await mouse.down(rowPoint);
          await shot('tree-pressed');
          await mouse.moveTo(const Offset(1100, 80));
          await mouse.up();
          await mouse.moveTo(
            tester.getCenter(find.byKey(const ValueKey('new-directory'))),
          );
          await tester.pump(const Duration(milliseconds: 650));
          await shot('tooltip');
          await tap(find.byKey(const ValueKey('new-directory')));
          await shot('directory');
          await tap(find.text('取消'));
          await tap(find.byKey(const ValueKey('library-tag-filter')));
          await shot('tag-filter');
          await tap(find.text('管理标签'));
          await shot('tag-manager');
          await tap(find.text('完成'));
          await tap(find.byKey(const ValueKey('library-credentials-mode')));
          await shot('credentials');
          await tap(find.byKey(const ValueKey('nav-2')));
          await shot('proposals');
          await tap(find.byKey(const ValueKey('nav-3')));
          await mouse.moveTo(
            tester.getCenter(find.byKey(const ValueKey('history-filter-1'))),
          );
          await shot('history-hover');
          await tap(find.byKey(const ValueKey('nav-4')));
          await tap(find.byKey(const ValueKey('settings-section-templates')));
          await tap(find.text('新建模板').last);
          await shot('template-editor');
          await tap(find.byType(DesktopSelect<FieldKind>).first);
          await shot('template-field-kind');
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          await tap(find.text('取消'));
          // At 200% the settings ListView has recycled rows above the selected
          // Templates entry. Build that row before ensureVisible can find it.
          final records = find.byKey(
            const ValueKey('settings-section-records'),
          );
          if (records.evaluate().isEmpty) {
            await tester.scrollUntilVisible(
              records,
              -200,
              scrollable: find
                  .ancestor(
                    of: find.byKey(
                      const ValueKey('settings-section-templates'),
                    ),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
          }
          await tap(find.byKey(const ValueKey('settings-section-records')));
          await tap(find.byKey(const ValueKey('timeout-30')));
          await shot('dropdown');
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          await tap(find.byKey(const ValueKey('settings-section-application')));
          await shot('settings');
          if (scale == 2) {
            final sidebar = find
                .ancestor(
                  of: find.byKey(
                    const ValueKey('settings-section-application'),
                  ),
                  matching: find.byType(Scrollable),
                )
                .first;
            final position = tester.state<ScrollableState>(sidebar).position;
            expect(position.maxScrollExtent, greaterThan(0));
            final viewport = tester.getRect(sidebar);
            final button = tester.getRect(
              find.byKey(const ValueKey('settings-section-application')),
            );
            expect(viewport.right - button.right, greaterThanOrEqualTo(16));
            final point = Offset(viewport.right - 4, viewport.center.dy);
            await mouse.moveTo(point);
            await shot('scrollbar-hover');
            await mouse.down(point);
            await mouse.moveBy(const Offset(0, -30));
            await shot('scrollbar-drag');
            await mouse.up();
          }
          await mouse.removePointer();
          debugDisableShadows = true;
        },
      );
    }
  }
}
