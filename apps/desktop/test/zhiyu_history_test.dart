import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';

const ref = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await Directory(evidence).create(recursive: true);
  });
  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    final boundary = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('history-capture')),
    );
    await t.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<LibraryController> start(
    WidgetTester t, {
    bool dark = false,
    double scale = 1,
    double width = 1280,
  }) async {
    t.view.physicalSize = Size(width, width == 1440 ? 900 : 800);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('history-capture'),
        child: PreviewWorkspace(),
      ),
    );
    await t.pumpAndSettle();
    if (dark) {
      await t.tap(find.byKey(const ValueKey('preview-guide')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('preview-theme-dark')));
      await t.pumpAndSettle();
    }
    final model = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
    await model.select(ref);
    await t.pumpAndSettle();
    return model;
  }

  Future<void> action(WidgetTester t, String text) async {
    await t.tap(find.byKey(const ValueKey('library-record-actions')));
    await t.pumpAndSettle();
    await t.tap(find.text(text));
    await t.pumpAndSettle();
  }

  Future<void> saveEdit(WidgetTester t, LibraryController model) async {
    final original = await model.source.readDetail(ref);
    await model.source.saveRecord(
      WorkspaceEdit(
        operationId: 'widget-edit',
        expectedVersion: original.version,
        record: original.record.copyWith(description: '新的服务器用途'),
        values: {'host': 'changed.example'},
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets(
    'real library menu compares full versions, keeps failure visible and restores a new version',
    (t) async {
      final model = await start(t);
      final original = await model.source.readDetail(ref);
      await saveEdit(t, model);
      await action(t, '内容版本');
      await t.tap(find.byKey(const ValueKey('library-version-1')));
      await t.pumpAndSettle();
      expect(find.text('当前 v2 → 恢复为 v3'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(DesktopDialog),
          matching: find.text('changed.example'),
        ),
        findsOneWidget,
      );
      await capture(t, 'history-compare-1280-light');
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('unavailable', '合成恢复失败');
      await t.tap(find.byKey(const ValueKey('library-restore-version')));
      await t.pumpAndSettle();
      expect(find.text('合成恢复失败'), findsOneWidget);
      expect((await model.source.readDetail(ref)).version, 2);
      await capture(t, 'history-failure-1280-light');
      await t.tap(find.byKey(const ValueKey('library-restore-version')));
      await t.pumpAndSettle();
      expect(find.byType(DesktopDialog), findsNothing);
      final restored = await model.source.readDetail(ref);
      expect(restored.version, 3);
      expect(restored.values, original.values);
      expect(model.detail!.values, original.values);
      expect((await model.source.loadRevisions(ref)).length, 2);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'recycle and restore from actual sidebar retain the original query and reread restored content',
    (t) async {
      final model = await start(t);
      final directory = model.query.directoryId;
      await action(t, '移到回收站');
      await t.tap(find.byKey(const ValueKey('library-recycle-submit')));
      await t.pumpAndSettle();
      expect((await model.source.loadSummary()).records, 30);
      await t.tap(find.byKey(const ValueKey('library-open-recycle')));
      await t.pumpAndSettle();
      final entry = (await model.source.queryRecycled()).items.single;
      await capture(t, 'recycle-list-1280-light');
      await t.tap(find.byKey(ValueKey('library-recycle-view-${entry.id}')));
      await t.pumpAndSettle();
      expect(find.text('回收内容'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('library-recycle-submit')));
      await t.pumpAndSettle();
      expect((await model.source.readDetail(ref)).version, 3);
      await t.tap(find.byKey(const ValueKey('library-recycle-back')));
      await t.pumpAndSettle();
      expect(model.query.directoryId, directory);
      expect((await model.source.queryRecycled()).total, 0);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'permanent purge needs a second explicit action, and a failed submission retains the snapshot',
    (t) async {
      final model = await start(t, dark: true, scale: 2);
      await action(t, '移到回收站');
      await capture(t, 'recycle-confirm-1280-dark-200');
      await t.tap(find.byKey(const ValueKey('library-recycle-submit')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('library-open-recycle')));
      await t.pumpAndSettle();
      final entry = (await model.source.queryRecycled()).items.single;
      await t.tap(find.byKey(ValueKey('library-recycle-view-${entry.id}')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('library-recycle-purge')));
      await t.pumpAndSettle();
      expect(find.text('确认永久清理'), findsOneWidget);
      final dialogName = find.descendant(
        of: find.byType(DesktopDialog),
        matching: find.text('Azure 日本服务器'),
      );
      expect(dialogName, findsOneWidget);
      final nameBounds = t.getRect(dialogName),
          dialogBounds = t.getRect(find.byType(DesktopDialog));
      expect(dialogBounds.contains(nameBounds.center), isTrue);
      expect((await model.source.queryRecycled()).total, 1);
      await capture(t, 'purge-confirm-1280-dark-200');
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('unavailable', '合成清理失败');
      await t.tap(find.byKey(const ValueKey('library-recycle-submit')));
      await t.pumpAndSettle();
      expect(find.text('合成清理失败'), findsOneWidget);
      expect(
        (await model.source.readRecycled(entry.id)).detail.record.ref,
        ref,
      );
      await t.tap(find.widgetWithText(DesktopButton, '重新读取'));
      await t.pumpAndSettle();
      // Reload deliberately requires a new explicit purge confirmation.
      await t.tap(find.byKey(const ValueKey('library-recycle-purge')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('library-recycle-submit')));
      await t.pumpAndSettle();
      expect(find.text('回收站为空'), findsOneWidget);
      expect((await model.source.queryRecycled()).total, 0);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'dark large-text comparison keeps actions reachable and stale restore requires rereading',
    (t) async {
      final model = await start(t, dark: true, scale: 2, width: 1440);
      await saveEdit(t, model);
      await action(t, '内容版本');
      await t.tap(find.byKey(const ValueKey('library-version-1')));
      await t.pumpAndSettle();
      await capture(t, 'history-compare-1440-dark-200');
      final current = await model.source.readDetail(ref);
      await model.source.saveRecord(
        WorkspaceEdit(
          operationId: 'concurrent',
          expectedVersion: current.version,
          record: current.record,
          values: {'host': 'newer.example'},
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('library-restore-version')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-history-error')),
        findsOneWidget,
      );
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('library-restore-version')),
            )
            .onPressed,
        isNull,
      );
      expect((await model.source.readDetail(ref)).version, 3);
      await t.tap(find.widgetWithText(DesktopButton, '重新读取版本'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-version-2')), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
