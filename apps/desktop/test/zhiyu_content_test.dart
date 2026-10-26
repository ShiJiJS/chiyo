import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_document.dart';
import 'package:info_desktop/workspace/library_file.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const resume = WorkspaceRecordRef(WorkspaceRecordKind.information, 'resume');
const https = WorkspaceRecordRef(WorkspaceRecordKind.information, 'https');
void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    final fonts = await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await Directory(evidence).create(recursive: true);
    await File('$evidence/fonts.json').writeAsString(jsonEncode(fonts));
  });
  void check(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (t) async {
      final original = debugDisableShadows;
      try {
        if (evidence.isNotEmpty) debugDisableShadows = false;
        await body(t);
      } finally {
        debugDisableShadows = original;
      }
    });
  }

  Future<void> ready(WidgetTester t, bool Function() predicate) async {
    for (var i = 0; i < 200; i++) {
      await t.pumpAndSettle();
      if (predicate()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    fail('Expected visible content did not finish loading.');
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    await ready(
      t,
      () => find
          .byType(Image)
          .evaluate()
          .every(
            (element) => find
                .descendant(
                  of: find.byWidget(element.widget),
                  matching: find.byWidgetPredicate(
                    (w) => w is RawImage && w.image != null,
                  ),
                )
                .evaluate()
                .isNotEmpty,
          ),
    );
    await t.runAsync(() async {
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('content-capture')),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> tap(WidgetTester t, Finder target) async {
    await t.ensureVisible(target);
    await t.pumpAndSettle();
    await t.tap(target);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> enter(WidgetTester t, Finder target, String text) async {
    await t.ensureVisible(target);
    await t.pumpAndSettle();
    await t.enterText(target, text);
    await t.pumpAndSettle();
  }

  Future<LibraryController> start(
    WidgetTester t,
    String name, {
    bool dark = false,
    double scale = 1,
    double width = 1280,
  }) async {
    t.view.physicalSize = Size(width, width == 1280 ? 800 : 900);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('content-capture'),
        child: PreviewWorkspace(),
      ),
    );
    await t.pumpAndSettle();
    if (dark) {
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-theme-dark')));
    }
    await tap(t, find.byKey(const ValueKey('library-directory-all')));
    await enter(t, find.byKey(const ValueKey('library-search')), name);
    final model = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
    final target = model.results!.items.singleWhere((r) => r.name == name).ref;
    await tap(t, find.byKey(ValueKey('library-record-${target.key}')));
    return model;
  }

  LibraryFilePreviewView preview(WidgetTester t) =>
      t.widget<LibraryFilePreviewView>(
        find.byType(LibraryFilePreviewView).first,
      );
  Future<void> fileReady(WidgetTester t) => ready(
    t,
    () =>
        find.byType(LibraryFilePreviewView).evaluate().isNotEmpty &&
        find
            .byType(Image)
            .evaluate()
            .every(
              (element) => find
                  .descendant(
                    of: find.byWidget(element.widget),
                    matching: find.byWidgetPredicate(
                      (w) => w is RawImage && w.image != null,
                    ),
                  )
                  .evaluate()
                  .isNotEmpty,
            ),
  );
  Finder value(String text) => find.byWidgetPredicate(
    (w) =>
        w is SelectableText &&
        (w.data ?? w.textSpan?.toPlainText() ?? '').contains(text),
  );

  check(
    'closed Markdown renderer shows rich content and inert HTML/links/images without network',
    (t) async {
      var network = 0;
      const body =
          '## 阅读标题\n\n**重点**与`代码`\n\n| 服务 | 状态 |\n| --- | --- |\n| API | 正常 |\n\n![远程图](https://example.invalid/image.png)\n\n[危险链接](javascript:alert(1))\n\n<script>doNotRun()</script>';
      await HttpOverrides.runZoned(
        () async {
          await t.pumpWidget(
            const MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: LibraryDocument(body: body, format: 'markdown'),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          expect(value('阅读标题'), findsOneWidget);
          expect(find.byType(Table), findsOneWidget);
          expect(value('图片：远程图'), findsOneWidget);
          expect(value('<script>doNotRun()</script>'), findsOneWidget);
          expect(find.byType(Image), findsNothing);
          expect(network, 0);
          await tap(t, find.byKey(const ValueKey('library-document-raw')));
          expect(
            t
                .widget<SelectableText>(
                  find.byKey(const ValueKey('library-document-text')),
                )
                .data,
            body,
          );
          expect(network, 0);
          expect(t.takeException(), isNull);
        },
        createHttpClient: (_) {
          network++;
          throw StateError('Network is forbidden in document rendering');
        },
      );
    },
  );
  check(
    'document editing preserves failed draft and saves plain text/Markdown as distinct versioned facts',
    (t) async {
      final model = await start(t, '域名与 HTTPS', width: 1440);
      expect(model.selection, https);
      expect(find.byType(LibraryDocument), findsOneWidget);
      expect(find.byType(Table), findsOneWidget);
      await capture(t, 'document-1440-light-reading');
      await tap(t, find.text('编辑信息'));
      const body = '## 保存后的正文\n\n**维护记录**，仅作为文字保存。';
      await enter(t, find.byKey(const ValueKey('library-edit-body')), body);
      await tap(t, find.byKey(const ValueKey('library-edit-bodyFormat')));
      await tap(t, find.text('纯文本').last);
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('offline', '文档保存失败，草稿已保留。');
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(find.text('文档保存失败，草稿已保留。'), findsOneWidget);
      expect(
        t
            .widget<DesktopTextField>(
              find.byKey(const ValueKey('library-edit-body')),
            )
            .controller!
            .text,
        body,
      );
      await capture(t, 'document-1440-light-edit-failure');
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(find.byType(DesktopDialog), findsNothing);
      final saved = await model.source.readDetail(https);
      expect(saved.values['bodyFormat'], 'plain');
      expect(saved.values['body'], body);
      expect(
        t
            .widget<SelectableText>(
              find.byKey(const ValueKey('library-document-text')),
            )
            .data,
        body,
      );
      expect(await model.source.loadRevisions(https), hasLength(1));
    },
  );
  check(
    'PDF current pages, text alternative and preview retry keep metadata/actions available',
    (t) async {
      final model = await start(t, '服务端开发简历');
      await fileReady(t);
      expect(preview(t).preview.pageCount, 2);
      expect(preview(t).preview.file.ref.version, 2);
      final image = find.byType(Image).first;
      await t.ensureVisible(image);
      await t.pumpAndSettle();
      await capture(t, 'file-1280-light-pdf');
      await tap(t, find.byKey(const ValueKey('library-file-page-next')));
      await fileReady(t);
      expect(preview(t).preview.page, 1);
      expect(preview(t).preview.text, contains('PROJECT NOTES'));
      await tap(t, find.byKey(const ValueKey('library-file-text-mode')));
      expect(value('ADDITIONAL PROJECT DETAILS'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-file-error')));
      await tap(
        t,
        find.byKey(const ValueKey('library-file-preview-refresh-file')),
      );
      await ready(
        t,
        () => find
            .byKey(const ValueKey('library-file-preview-retry-file'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey('library-file-save-file')),
        findsOneWidget,
      );
      expect(find.text('文件预览失败，文件信息仍可查看。'), findsOneWidget);
      await t.ensureVisible(
        find.byKey(const ValueKey('library-file-save-file')),
      );
      await t.pumpAndSettle();
      await capture(t, 'file-1280-light-preview-failure');
      await tap(
        t,
        find.byKey(const ValueKey('library-file-preview-retry-file')),
      );
      await fileReady(t);
      expect(preview(t).preview.page, 1);
      expect(model.selection, resume);
    },
  );
  check(
    'file replace failure retains selected file; historical restore creates a new current head',
    (t) async {
      final model = await start(t, '服务端开发简历', dark: true, scale: 2);
      await fileReady(t);
      await tap(t, find.byKey(const ValueKey('library-file-replace-file')));
      await ready(
        t,
        () => find
            .byKey(const ValueKey('library-file-choice-pdf-v1'))
            .evaluate()
            .isNotEmpty,
      );
      await tap(t, find.byKey(const ValueKey('library-file-choice-pdf-v1')));
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('offline', '替换失败，已选文件仍保留。');
      await tap(t, find.byKey(const ValueKey('library-file-change-submit')));
      expect(find.text('替换失败，已选文件仍保留。'), findsOneWidget);
      expect(
        (await model.source.loadFileHistory(
          resume,
          'file',
        )).current.ref.version,
        2,
      );
      await capture(t, 'file-1280-dark-200-replace-failure');
      await tap(t, find.byKey(const ValueKey('library-file-change-submit')));
      await fileReady(t);
      expect(find.byType(DesktopDialog), findsNothing);
      expect(preview(t).preview.file.ref.version, 3);
      expect(preview(t).preview.pageCount, 1);
      await tap(t, find.byKey(const ValueKey('library-file-versions-file')));
      await tap(t, find.byKey(const ValueKey('library-file-version-2')));
      await ready(
        t,
        () => find
            .byType(LibraryFilePreviewView)
            .evaluate()
            .where(
              (e) =>
                  (e.widget as LibraryFilePreviewView)
                      .preview
                      .file
                      .ref
                      .version ==
                  2,
            )
            .isNotEmpty,
      );
      await capture(t, 'file-1280-dark-200-history');
      await tap(t, find.byKey(const ValueKey('library-file-restore')));
      await tap(t, find.byKey(const ValueKey('library-file-change-submit')));
      await fileReady(t);
      expect(find.byType(DesktopDialog), findsNothing);
      expect(preview(t).preview.file.ref.version, 4);
      expect(preview(t).preview.pageCount, 2);
    },
  );
  check('new document starts empty and saves through the common add entry', (
    t,
  ) async {
    final model = await start(t, '域名与 HTTPS', dark: true, width: 1440);
    await tap(t, find.byKey(const ValueKey('library-create')));
    await tap(t, find.byKey(const ValueKey('library-new-type-document')));
    await enter(t, find.byKey(const ValueKey('library-edit-name')), '新的空白文档');
    expect(
      t
          .widget<DesktopTextField>(
            find.byKey(const ValueKey('library-edit-body')),
          )
          .controller!
          .text,
      isEmpty,
    );
    await tap(t, find.byKey(const ValueKey('library-edit-save')));
    expect(find.text('尚未填写正文。'), findsOneWidget);
    final detail = await model.source.readDetail(model.selection!);
    expect(detail.values['body'], '');
    expect(detail.values['bodyFormat'], 'markdown');
    await capture(t, 'document-1440-dark-empty');
  });
  check(
    'PNG and plain text use their own bytes through the same file replacement entry',
    (t) async {
      await start(t, '服务端开发简历');
      await fileReady(t);
      for (final selection in ['image', 'text']) {
        await tap(t, find.byKey(const ValueKey('library-file-replace-file')));
        await ready(
          t,
          () => find
              .byKey(ValueKey('library-file-choice-$selection'))
              .evaluate()
              .isNotEmpty,
        );
        await tap(t, find.byKey(ValueKey('library-file-choice-$selection')));
        await tap(t, find.byKey(const ValueKey('library-file-change-submit')));
        await fileReady(t);
        expect(preview(t).preview.pageCount, 1);
        if (selection == 'image') {
          expect(preview(t).preview.file.mediaType, 'image/png');
          expect(find.byType(Image), findsOneWidget);
          await capture(t, 'file-1280-light-png');
        } else {
          expect(preview(t).preview.file.mediaType, 'text/plain');
          expect(value('Maintenance checklist'), findsOneWidget);
          expect(find.byType(Image), findsNothing);
          expect(preview(t).preview.file.ref.version, 4);
        }
        expect(t.takeException(), isNull);
      }
    },
  );
  check(
    'file import reviews metadata, resolves unknown result before retry and leaves unknown-format save/open usable',
    (t) async {
      final model = await start(t, '服务端开发简历', width: 1440);
      await tap(t, find.byKey(const ValueKey('library-create')));
      await tap(t, find.byKey(const ValueKey('library-new-type-file')));
      await ready(
        t,
        () => find
            .byKey(const ValueKey('library-file-choice-unknown'))
            .evaluate()
            .isNotEmpty,
      );
      await tap(t, find.byKey(const ValueKey('library-file-choice-unknown')));
      await enter(
        t,
        find.byKey(const ValueKey('library-file-import-name')),
        '未知格式附件',
      );
      await enter(
        t,
        find.byKey(const ValueKey('library-file-import-description')),
        '仅用于格式与失败恢复检查',
      );
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('unknown_outcome', '请先核对导入结果。');
      await tap(t, find.byKey(const ValueKey('library-file-import-submit')));
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('library-file-import-submit')),
            )
            .onPressed,
        isNull,
      );
      expect((await model.source.loadSummary()).records, 31);
      await capture(t, 'file-1440-light-import-unknown');
      await tap(t, find.text('核对导入结果'));
      await tap(t, find.byKey(const ValueKey('library-file-import-submit')));
      await ready(
        t,
        () => find.text('此文件格式暂不支持预览，可另存或用本机程序打开。').evaluate().isNotEmpty,
      );
      expect((await model.source.loadSummary()).records, 32);
      final source = model.source as SampleWorkspaceSource;
      source.cancelNextFileAction = true;
      await tap(t, find.byKey(const ValueKey('library-file-save-file')));
      source.nextFileActionFailure = const WorkspaceFailure(
        'unknown_outcome',
        '另存结果未知，请核对。',
      );
      await tap(t, find.byKey(const ValueKey('library-file-save-file')));
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('library-file-save-file')),
            )
            .onPressed,
        isNull,
      );
      await tap(t, find.text('核对此次操作'));
      await tap(t, find.byKey(const ValueKey('library-file-save-file')));
      expect(find.text('已另存 unsupported.bin'), findsOneWidget);
      await capture(t, 'file-1440-light-unknown-format');
      expect(t.takeException(), isNull);
    },
  );
}
