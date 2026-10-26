import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_file.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const resume = WorkspaceRecordRef(WorkspaceRecordKind.information, 'resume');
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
        find.byKey(const ValueKey('content-states-capture')),
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
        key: ValueKey('content-states-capture'),
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

  Finder dialogChild(Finder child) =>
      find.descendant(of: find.byType(DesktopDialog), matching: child);
  Future<void> historyReady(WidgetTester t) => ready(
    t,
    () =>
        dialogChild(
          find.byType(LibraryFilePreviewView),
        ).evaluate().isNotEmpty &&
        dialogChild(find.byType(Image)).evaluate().every(
          (e) => find
              .descendant(
                of: find.byWidget(e.widget),
                matching: find.byWidgetPredicate(
                  (w) => w is RawImage && w.image != null,
                ),
              )
              .evaluate()
              .isNotEmpty,
        ),
  );
  LibraryFilePreviewView historical(WidgetTester t) =>
      t.widget<LibraryFilePreviewView>(
        dialogChild(find.byType(LibraryFilePreviewView)),
      );
  for (final dark in [false, true]) {
    check(
      'history paging keeps zoom/text through waiting/error/retry and resets only at version change dark=$dark',
      (t) async {
        final stem = dark
            ? 'file-history-1280-dark-200'
            : 'file-history-1440-light';
        final model = await start(
          t,
          '服务端开发简历',
          dark: dark,
          scale: dark ? 2 : 1,
          width: dark ? 1280 : 1440,
        );
        await fileReady(t);
        expect(preview(t).preview.file.ref.version, 2);
        await tap(t, find.byKey(const ValueKey('library-file-versions-file')));
        await historyReady(t);
        final initialWidth = t.getSize(dialogChild(find.byType(Image))).width;
        await tap(
          t,
          dialogChild(find.byKey(const ValueKey('library-file-zoom-in'))),
        );
        expect(
          t.getSize(dialogChild(find.byType(Image))).width,
          closeTo(initialWidth * 1.5, .1),
        );
        await tap(
          t,
          dialogChild(find.byKey(const ValueKey('library-file-text-mode'))),
        );
        expect(
          dialogChild(
            find.byKey(const ValueKey('library-file-extracted-text')),
          ),
          findsOneWidget,
        );
        final source = model.source as SampleWorkspaceSource;
        source.setScenario(SampleWorkspaceScenario.waiting);
        await tap(
          t,
          dialogChild(find.byKey(const ValueKey('library-file-page-next'))),
        );
        expect(find.text('正在读取版本预览…'), findsOneWidget);
        expect(dialogChild(value('林予安-服务端开发-v2.pdf')), findsOneWidget);
        expect(dialogChild(find.byType(LibraryFilePreviewView)), findsNothing);
        await capture(t, '$stem-waiting');
        source.setScenario(SampleWorkspaceScenario.ready);
        await ready(t, () => find.text('已切换预览状态。').evaluate().isNotEmpty);
        await tap(t, find.text('重新读取版本'));
        await historyReady(t);
        expect(historical(t).preview.page, 1);
        expect(
          dialogChild(value('ADDITIONAL PROJECT DETAILS')),
          findsOneWidget,
        );
        await capture(t, '$stem-text-page2');
        source.nextFilePreviewFailure = const WorkspaceFailure(
          'preview_unavailable',
          '历史页面读取失败，请重试。',
        );
        await tap(
          t,
          dialogChild(find.byKey(const ValueKey('library-file-page-back'))),
        );
        expect(find.text('历史页面读取失败，请重试。'), findsOneWidget);
        expect(dialogChild(value('林予安-服务端开发-v2.pdf')), findsOneWidget);
        expect(dialogChild(find.byType(LibraryFilePreviewView)), findsNothing);
        await capture(t, '$stem-read-failure');
        await tap(t, find.text('重新读取版本'));
        await historyReady(t);
        expect(historical(t).preview.page, 0);
        expect(
          dialogChild(
            find.byKey(const ValueKey('library-file-extracted-text')),
          ),
          findsOneWidget,
        );
        await tap(
          t,
          dialogChild(find.byKey(const ValueKey('library-file-text-mode'))),
        );
        await historyReady(t);
        expect(
          t.getSize(dialogChild(find.byType(Image))).width,
          closeTo(initialWidth * 1.5, .1),
        );
        await tap(t, find.byKey(const ValueKey('library-file-version-1')));
        await historyReady(t);
        expect(historical(t).preview.file.ref.version, 1);
        expect(
          dialogChild(
            find.byKey(const ValueKey('library-file-extracted-text')),
          ),
          findsNothing,
        );
        expect(
          t
              .widget<DesktopButton>(
                dialogChild(
                  find.byKey(const ValueKey('library-file-zoom-out')),
                ),
              )
              .onPressed,
          isNull,
        );
        expect(
          (await model.source.loadFileHistory(
            resume,
            'file',
          )).current.ref.version,
          2,
        );
        await tap(t, find.text('关闭').last);
        expect(model.selection, resume);
      },
    );
  }
}
