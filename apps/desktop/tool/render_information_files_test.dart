// Explicit visual evidence, separate from native dialogs and encrypted IO QA.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_shell.dart';
import 'package:info_desktop/information_files.dart';
import 'package:info_desktop/library.dart';
import 'package:info_desktop/ui.dart';

class _Picker implements InformationFilePicker {
  @override
  Future<String?> choose() async => null;
  @override
  Future<String?> saveAs(String originalName) async => null;
}

void main() {
  const directory = String.fromEnvironment('ATTACHMENT_RENDER_DIRECTORY');
  if (directory.isEmpty) return;
  testWidgets('render the real typed-file library and owner editor', (
    tester,
  ) async {
    await tester.runAsync(() async {
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
        final bytes = await File(
          'C:/Windows/Fonts/${font.value}',
        ).readAsBytes();
        await (FontLoader(
          font.key,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      final output = Directory(directory);
      await output.create(recursive: true);
      final temp = await Directory.systemTemp.createTemp('file-editor-render-');
      final source = File('${temp.path}/林予安的个人简历与项目经历.pdf');
      await source.writeAsBytes(Uint8List(248320));
      debugDisableShadows = false;
      try {
        for (final theme in DesktopColorTheme.values) {
          final repository = MemoryInformationRepository();
          final service = InformationService(
            repository: repository,
            clock: () => DateTime.utc(2026, 10, 19, 7),
          );
          final owner = service.owner;
          final personal = await owner.createDirectory('个人');
          final career = await owner.createDirectory(
            '求职',
            parentId: personal.id,
          );
          final tag = await owner.createTag('个人');
          final form = await owner.beginInformationFileDraft();
          final stage = await owner.stageInformationFile(
            form,
            source.path,
            mediaType: 'application/pdf',
          );
          final item = await owner.commitInformationDraft(
            form,
            'create',
            InformationDraftInput(
              name: '求职资料',
              description: '求职时需要的基本信息和简历',
              directoryId: career.id,
              tagIds: [tag.id],
              fields: [
                const InformationDraftField.text('姓名', '填写个人资料', '林予安'),
                const InformationDraftField.text(
                  '求职说明',
                  '个人偏好及补充说明',
                  '优先考虑远程工作机会。',
                  kind: FieldKind.textNote,
                ),
                InformationDraftField.stagedFile('简历', '可领取的简历原文件', stage.id),
              ],
            ),
          );
          await owner.releaseInformationFileDraft(form);
          for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            final boundary = GlobalKey();
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
                '${output.path}/${theme.name}-${size.width.toInt()}-$state.png',
              ).writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            }

            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: informationTheme(theme),
                  home: Scaffold(
                    body: DesktopShell(
                      service: service,
                      port: 0,
                      index: 1,
                      onSelected: (_) {},
                      hasBackups: false,
                      colorTheme: theme,
                      onThemeChanged: (_) {},
                      child: InformationLibrary(
                        owner: owner,
                        initialItemId: item.id,
                        files: _Picker(),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await capture('library');
            await tester.tap(
              find.byKey(const ValueKey('edit-information-description')),
            );
            await tester.pumpAndSettle();
            await tester.ensureVisible(
              find.byKey(const ValueKey('choose-file-2')),
            );
            await capture('file-editor');
            if (theme == DesktopColorTheme.purple && size.width == 1280) {
              tester.platformDispatcher.textScaleFactorTestValue = 2;
              await tester.pumpAndSettle();
              await tester.ensureVisible(
                find.byKey(const ValueKey('choose-file-2')),
              );
              await capture('file-editor-text-200');
              tester.platformDispatcher.clearTextScaleFactorTestValue();
              await tester.pumpAndSettle();
            }
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('new-information')));
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byKey(const ValueKey('item-name')),
              '求职资料',
            );
            await tester.enterText(
              find.byKey(const ValueKey('field-name-0')),
              '简历',
            );
            await tester.tap(find.byKey(const ValueKey('field-kind-0')));
            await tester.pumpAndSettle();
            await tester.tap(find.text('文件').last);
            await tester.pumpAndSettle();
            await tester.ensureVisible(
              find.byKey(const ValueKey('choose-file-0')),
            );
            await capture('empty-file');
            await tester.tap(find.byKey(const ValueKey('save-information')));
            await capture('missing-file');
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('放弃更改'));
            await tester.pumpAndSettle();
            await tester.pumpWidget(const SizedBox.shrink());
          }
          await service.close();
        }
      } finally {
        await source.delete();
        await temp.delete();
        debugDisableShadows = true;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  });
}
