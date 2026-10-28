import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/library_file.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  const output = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (!Platform.isMacOS) return;
    await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    if (output.isNotEmpty) await Directory(output).create(recursive: true);
  });
  for (final large in [false, true]) {
    testWidgets(
      'file filter includes resumes and ordinary import keeps failure draft and type large=$large',
      (t) async {
        final size = large ? const Size(1280, 800) : const Size(1440, 900);
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.textScaleFactorTestValue = large ? 2 : 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        Finder key(String id) => find.byKey(ValueKey(id));
        Future<void> ready(bool Function() predicate) async {
          for (var i = 0; i < 200; i++) {
            await t.pumpAndSettle();
            if (predicate()) return;
            await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 2)),
            );
          }
          fail('File flow did not reach the expected state');
        }

        Future<void> tap(Finder target) async {
          if (target.hitTestable().evaluate().isEmpty) {
            await t.ensureVisible(target);
          }
          await t.pumpAndSettle();
          await t.tap(target, kind: ui.PointerDeviceKind.mouse);
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
        }

        Future<void> typeFilter(String label) async {
          await tap(key('library-type-filter'));
          await tap(find.text(label).last);
        }

        await t.pumpWidget(
          const RepaintBoundary(
            key: ValueKey('file-type-capture'),
            child: PreviewWorkspace(),
          ),
        );
        await t.pumpAndSettle();
        if (large) {
          await tap(key('preview-guide'));
          await tap(key('preview-theme-dark'));
        }
        await tap(key('library-directory-all'));
        final model = t
            .widget<LibraryPage>(find.byType(LibraryPage))
            .controller;
        await typeFilter('文件');
        expect(model.results!.total, 6);
        await tap(key('library-record-information:resume'));
        expect(model.detail!.record.type.id, 'resume');
        expect(model.detail!.fieldIds['file'], isNotNull);
        await tap(key('library-create'));
        await tap(key('library-new-type-file'));
        await ready(
          () => key('library-file-choice-pdf-v2').evaluate().isNotEmpty,
        );
        await tap(key('library-file-choice-pdf-v2'));
        expect(find.text('导入文件'), findsOneWidget);
        await t.enterText(key('library-file-import-name'), '申请材料');
        await t.pumpAndSettle();
        (model.source as SampleWorkspaceSource).nextSaveFailure =
            const WorkspaceFailure('offline', '合成导入失败，请重试。');
        await tap(key('library-file-import-submit'));
        expect(find.text('合成导入失败，请重试。'), findsOneWidget);
        expect(
          t
              .widget<DesktopTextField>(key('library-file-import-name'))
              .controller!
              .text,
          '申请材料',
        );
        expect((await model.source.loadSummary()).records, 31);
        if (output.isNotEmpty) {
          await t.runAsync(() async {
            final boundary = t.renderObject<RenderRepaintBoundary>(
              key('file-type-capture'),
            );
            final image = await boundary.toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '$output/file-type-${large ? 'dark-1280-200' : 'light-1440-100'}-failure.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tap(key('library-file-import-submit'));
        await ready(() => find.byType(LibraryFile).evaluate().isNotEmpty);
        final ref = model.selection!;
        expect(model.detail!.record.name, '申请材料');
        expect(model.detail!.record.type.id, 'file');
        expect(model.results!.total, 7);
        expect(
          (await model.source.loadFileHistory(ref, 'file')).current.ref.version,
          1,
        );
        (model.source as SampleWorkspaceSource).cancelNextFileAction = true;
        await tap(key('library-file-actions-file'));
        await tap(key('library-file-save-file'));
        expect(
          (await model.source.loadFileHistory(ref, 'file')).current.ref.version,
          1,
        );
        await typeFilter('文件');
        expect(model.results!.total, 7);
        expect(model.selection, ref);
        expect(model.detail!.record.type.name, '文件');
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
      skip: !Platform.isMacOS,
    );
  }
}
