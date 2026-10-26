import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const document = WorkspaceRecordRef(WorkspaceRecordKind.information, 'https');
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
  Future<void> tap(WidgetTester t, Finder target) async {
    await t.ensureVisible(target);
    await t.pumpAndSettle();
    await t.tap(target);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    final boundary = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('receipt-capture')),
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

  Future<LibraryController> start(WidgetTester t, {bool dark = false}) async {
    t.view.physicalSize = dark ? const Size(1280, 800) : const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = dark ? 2 : 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('receipt-capture'),
        child: PreviewWorkspace(),
      ),
    );
    await t.pumpAndSettle();
    if (dark) {
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-theme-dark')));
    }
    final model = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
    await model.select(document);
    await t.pumpAndSettle();
    return model;
  }

  Future<void> menu(WidgetTester t, String label) async {
    await tap(t, find.byKey(const ValueKey('library-record-actions')));
    await tap(t, find.text(label));
  }

  void disabled(WidgetTester t, String key) {
    expect(
      t.widget<DesktopButton>(find.byKey(ValueKey(key))).onPressed,
      isNull,
    );
  }

  testWidgets(
    'committed document edit freezes the original draft through failed receipt lookup and reads back once',
    (t) async {
      final model = await start(t), s = model.source as SampleWorkspaceSource;
      await tap(t, find.text('编辑信息'));
      final body = find.byKey(const ValueKey('library-edit-body'));
      await t.ensureVisible(body);
      await t.enterText(body, '## 本次合成修改');
      s.loseNextRecordReply = true;
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      disabled(t, 'library-edit-save');
      expect(t.widget<DesktopTextField>(body).enabled, isFalse);
      expect(t.widget<DesktopTextField>(body).controller!.text, '## 本次合成修改');
      expect((await s.readDetail(document)).version, 2);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(DesktopDialog), findsOneWidget);
      disabled(t, 'library-edit-save');
      await capture(t, 'edit-unknown-1440-light');
      s.setScenario(SampleWorkspaceScenario.failure);
      await tap(t, find.byKey(const ValueKey('library-edit-reconcile')));
      disabled(t, 'library-edit-save');
      expect(find.text('仍无法确认结果，请稍后核对。'), findsOneWidget);
      s.setScenario(SampleWorkspaceScenario.ready);
      await tap(t, find.byKey(const ValueKey('library-edit-reconcile')));
      expect(find.byType(DesktopDialog), findsNothing);
      expect(model.detail!.values['body'], '## 本次合成修改');
      expect(model.detail!.version, 2);
      expect(await s.loadRevisions(document), hasLength(1));
    },
  );

  testWidgets(
    'uncommitted creation keeps fields, confirms absence, and only saves after an explicit retry',
    (t) async {
      final model = await start(t), s = model.source as SampleWorkspaceSource;
      await tap(t, find.byTooltip('添加资料'));
      await tap(t, find.byKey(const ValueKey('library-new-type-document')));
      await t.enterText(
        find.byKey(const ValueKey('library-edit-name')),
        '新建回执测试文档',
      );
      final body = find.byKey(const ValueKey('library-edit-body'));
      await t.ensureVisible(body);
      await t.enterText(body, '保留的合成草稿');
      s.nextSaveFailure = const WorkspaceFailure('unknown_outcome', '结果未确认');
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      disabled(t, 'library-edit-save');
      expect((await s.loadSummary()).records, 31);
      await tap(t, find.byKey(const ValueKey('library-edit-reconcile')));
      expect(find.text('已确认尚未提交。草稿已保留，可修改或重新保存。'), findsOneWidget);
      expect((await s.loadSummary()).records, 31);
      expect(t.widget<DesktopTextField>(body).controller!.text, '保留的合成草稿');
      await capture(t, 'create-absence-1440-light');
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(find.byType(DesktopDialog), findsNothing);
      expect((await s.loadSummary()).records, 32);
      expect(model.detail!.record.name, '新建回执测试文档');
      expect(model.detail!.values['body'], '保留的合成草稿');
    },
  );

  testWidgets(
    'lost revision restore reply cannot be replaced by reload or another version',
    (t) async {
      final model = await start(t), s = model.source as SampleWorkspaceSource;
      final original = await s.readDetail(document);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'setup-edit',
          expectedVersion: original.version,
          record: original.record,
          values: {'body': 'later body'},
        ),
      );
      await t.pumpAndSettle();
      await menu(t, '内容版本');
      await tap(t, find.byKey(const ValueKey('library-version-1')));
      s.loseNextRecordReply = true;
      await tap(t, find.byKey(const ValueKey('library-restore-version')));
      disabled(t, 'library-restore-version');
      expect(
        t
            .widget<DesktopButton>(find.widgetWithText(DesktopButton, '重新读取版本'))
            .onPressed,
        isNull,
      );
      expect((await s.readDetail(document)).version, 3);
      await capture(t, 'restore-unknown-1440-light');
      await tap(t, find.byKey(const ValueKey('library-history-reconcile')));
      expect(find.byType(DesktopDialog), findsNothing);
      expect(model.detail!.version, 3);
      expect(model.detail!.values, original.values);
      expect(await s.loadRevisions(document), hasLength(2));
    },
  );

  testWidgets(
    'recycle, restore and two-step purge reconcile their own lost replies in dark 200 percent',
    (t) async {
      final model = await start(t, dark: true),
          s = model.source as SampleWorkspaceSource;
      await menu(t, '移到回收站');
      s.loseNextRecordReply = true;
      await tap(t, find.byKey(const ValueKey('library-recycle-submit')));
      disabled(t, 'library-recycle-submit');
      await capture(t, 'recycle-unknown-1280-dark-200');
      await tap(t, find.byKey(const ValueKey('library-recycle-reconcile')));
      await tap(t, find.byKey(const ValueKey('library-open-recycle')));
      Future<void> open() async {
        final entry = (await s.queryRecycled()).items.singleWhere(
          (e) => e.record.ref == document,
        );
        await tap(t, find.byKey(ValueKey('library-recycle-view-${entry.id}')));
      }

      await open();
      s.loseNextRecordReply = true;
      await tap(t, find.byKey(const ValueKey('library-recycle-submit')));
      disabled(t, 'library-recycle-purge');
      await tap(t, find.byKey(const ValueKey('library-recycle-reconcile')));
      expect((await s.readDetail(document)).version, 3);
      // Repeat through the actual library entry to prepare the purge branch.
      await tap(t, find.byKey(const ValueKey('library-recycle-back')));
      await model.select(document);
      await t.pumpAndSettle();
      await menu(t, '移到回收站');
      await tap(t, find.byKey(const ValueKey('library-recycle-submit')));
      await tap(t, find.byKey(const ValueKey('library-open-recycle')));
      await open();
      await tap(t, find.byKey(const ValueKey('library-recycle-purge')));
      s.loseNextRecordReply = true;
      await tap(t, find.byKey(const ValueKey('library-recycle-submit')));
      disabled(t, 'library-recycle-submit');
      expect(
        t
            .widget<DesktopButton>(find.widgetWithText(DesktopButton, '返回查看'))
            .onPressed,
        isNull,
      );
      await capture(t, 'purge-unknown-1280-dark-200');
      await tap(t, find.byKey(const ValueKey('library-recycle-reconcile')));
      expect(find.byType(DesktopDialog), findsNothing);
      expect(
        (await s.queryRecycled()).items.where((e) => e.record.ref == document),
        isEmpty,
      );
      await expectLater(
        s.readDetail(document),
        throwsA(isA<WorkspaceFailure>()),
      );
    },
  );
  testWidgets(
    'committed creation whose object is later purged reports the receipt without resurrecting content',
    (t) async {
      final model = await start(t), s = model.source as SampleWorkspaceSource;
      await tap(t, find.byKey(const ValueKey('library-create')));
      await tap(t, find.byKey(const ValueKey('library-new-type-document')));
      await t.enterText(
        find.byKey(const ValueKey('library-edit-name')),
        '随后清理的合成文档',
      );
      s.loseNextRecordReply = true;
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      final created = (await s.queryRecords(
        WorkspaceQuery(keyword: '随后清理的合成文档'),
      )).items.single;
      final current = await s.readDetail(created.ref);
      final recycle = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'external-recycle',
          ref: created.ref,
          expectedVersion: current.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'external-purge',
          ref: created.ref,
          expectedVersion: recycle.version,
          entryId: recycle.entryId,
          action: WorkspaceRecordAction.purge,
        ),
      );
      await t.pumpAndSettle();
      await tap(t, find.byKey(const ValueKey('library-edit-reconcile')));
      expect(find.byType(DesktopDialog), findsNothing);
      expect(find.text('操作已提交，当前资料暂不可用，请查看读取结果。'), findsOneWidget);
      expect(
        (await s.queryRecords(WorkspaceQuery(keyword: '随后清理的合成文档'))).items,
        isEmpty,
      );
      expect((await s.loadSummary()).records, 31);
    },
  );

  testWidgets(
    'uncommitted purge keeps its second confirmation and retries only after confirmed absence',
    (t) async {
      final model = await start(t), s = model.source as SampleWorkspaceSource;
      await menu(t, '移到回收站');
      await tap(t, find.byKey(const ValueKey('library-recycle-submit')));
      await tap(t, find.byKey(const ValueKey('library-open-recycle')));
      final entry = (await s.queryRecycled()).items.singleWhere(
        (e) => e.record.ref == document,
      );
      await tap(t, find.byKey(ValueKey('library-recycle-view-${entry.id}')));
      await tap(t, find.byKey(const ValueKey('library-recycle-purge')));
      s.nextSaveFailure = const WorkspaceFailure('unknown_outcome', '未知');
      await tap(t, find.byKey(const ValueKey('library-recycle-submit')));
      disabled(t, 'library-recycle-submit');
      await tap(t, find.byKey(const ValueKey('library-recycle-reconcile')));
      expect(find.text('确认永久清理'), findsOneWidget);
      expect(
        (await s.queryRecycled()).items.any((e) => e.id == entry.id),
        isTrue,
      );
      expect(find.text('已确认尚未提交，可重新执行已核对的操作。'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('library-recycle-submit')));
      expect(find.byType(DesktopDialog), findsNothing);
      expect(
        (await s.queryRecycled()).items.any((e) => e.id == entry.id),
        isFalse,
      );
    },
  );
}
