import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_entries.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_entries.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const profile = WorkspaceRecordRef(WorkspaceRecordKind.information, 'profile');
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
  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    await t.runAsync(() async {
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('profile-capture')),
      );
      final frame = await boundary.toImage(pixelRatio: 1);
      final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      frame.dispose();
    });
  }

  Future<void> tap(WidgetTester t, Finder target) async {
    await t.ensureVisible(target);
    await t.pumpAndSettle();
    await t.tap(target);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> enter(WidgetTester t, Finder target, String value) async {
    await t.ensureVisible(target);
    await t.pumpAndSettle();
    await t.enterText(target, value);
    await t.pumpAndSettle();
  }

  Future<LibraryController> start(
    WidgetTester t, {
    double width = 1280,
    bool dark = false,
  }) async {
    if (evidence.isNotEmpty) {
      debugDisableShadows = false;
    }
    t.view.physicalSize = Size(width, width == 1280 ? 800 : 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    t.platformDispatcher.textScaleFactorTestValue = dark ? 2 : 1;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('profile-capture'),
        child: PreviewWorkspace(),
      ),
    );
    await t.pumpAndSettle();
    if (dark) {
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-theme-dark')));
    }
    await tap(t, find.byKey(const ValueKey('library-directory-all')));
    await enter(t, find.byKey(const ValueKey('library-search')), '个人档案');
    await tap(
      t,
      find.byKey(const ValueKey('library-record-information:profile')),
    );
    return t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
  }

  List<WorkspaceRepeatedEntry> draft(WidgetTester t) => t
      .widget<LibraryEntriesEditor>(
        find.byKey(const ValueKey('library-entries-education')),
      )
      .entries;
  Finder field(String id, String part) =>
      find.byKey(ValueKey('library-entry-education-$id-$part'));

  void profileWidgets(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (t) async {
      final originalShadows = debugDisableShadows;
      try {
        await body(t);
      } finally {
        // Painting invariants are checked before addTearDown callbacks.
        debugDisableShadows = originalShadows;
      }
    });
  }

  for (final width in [1440.0, 1280.0]) {
    for (final dark in [false, true]) {
      profileWidgets(
        'profile entry add/move/remove and failed save retain draft at $width dark=$dark',
        (t) async {
          final model = await start(t, width: width, dark: dark);
          final before = await model.source.readDetail(profile);
          final original = WorkspaceRepeatedEntry.read(
            before.values['education'],
          );
          final stem = '${width.toInt()}-${dark ? 'dark-200' : 'light'}';
          await capture(t, '$stem-reading');
          await tap(t, find.text('编辑信息'));
          await tap(
            t,
            find.byKey(const ValueKey('library-entry-add-education')),
          );
          final id = draft(t).last.id;
          await enter(t, field(id, 'title'), '北辰研究院 · 虚构研修经历');
          await enter(t, field(id, 'period'), '2027.01 — 2027.06');
          await enter(t, field(id, 'detail'), '这段说明用于验证编辑、排序与失败后的草稿保留。');
          final controller = t
              .widget<DesktopTextField>(field(id, 'title'))
              .controller;
          await tap(t, find.byKey(ValueKey('library-entry-up-$id')));
          expect(
            identical(
              t.widget<DesktopTextField>(field(id, 'title')).controller,
              controller,
            ),
            isTrue,
          );
          expect(draft(t).map((e) => e.id), [
            original.first.id,
            id,
            original.last.id,
          ]);
          await tap(
            t,
            find.byKey(ValueKey('library-entry-remove-${original.first.id}')),
          );
          expect(draft(t).map((e) => e.id), [id, original.last.id]);
          (model.source as SampleWorkspaceSource).nextSaveFailure =
              const WorkspaceFailure('offline', '档案暂时无法保存，请稍后重试。');
          await tap(t, find.byKey(const ValueKey('library-edit-save')));
          expect(find.text('档案暂时无法保存，请稍后重试。'), findsOneWidget);
          expect(
            (await model.source.readDetail(profile)).values,
            before.values,
          );
          expect(controller!.text, '北辰研究院 · 虚构研修经历');
          await t.ensureVisible(field(id, 'title'));
          await t.pumpAndSettle();
          await capture(t, '$stem-edit-failure');
          await tap(t, find.byKey(const ValueKey('library-edit-save')));
          expect(find.byType(DesktopDialog), findsNothing);
          final saved = WorkspaceRepeatedEntry.read(
            (await model.source.readDetail(profile)).values['education'],
          );
          expect(saved.map((e) => e.id), [id, original.last.id]);
          expect(saved.last.fieldIds, original.last.fieldIds);
          expect(saved.first.title, '北辰研究院 · 虚构研修经历');
          expect(model.selection, profile);
          final timeline = find.byKey(ValueKey('library-timeline-$id'));
          await t.ensureVisible(timeline);
          await t.pumpAndSettle();
          await capture(t, '$stem-saved-timeline');
          expect(t.takeException(), isNull);
        },
      );
    }
  }
  profileWidgets(
    'record name errors do not mark the separate personal name field',
    (t) async {
      await start(t);
      await tap(t, find.text('编辑信息'));
      await enter(t, find.byKey(const ValueKey('library-edit-name')), '');
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(
        t
            .widget<DesktopTextField>(
              find.byKey(const ValueKey('library-edit-name')),
            )
            .decoration
            .errorText,
        isNotNull,
      );
      expect(
        t
            .widget<DesktopTextField>(
              find.byKey(const ValueKey('library-edit-value-name')),
            )
            .decoration
            .errorText,
        isNull,
      );
      expect(t.takeException(), isNull);
    },
  );

  profileWidgets(
    'blank new entry shows its own field error and retains the original profile',
    (t) async {
      final model = await start(t);
      final before = await model.source.readDetail(profile);
      await tap(t, find.text('编辑信息'));
      await tap(t, find.byKey(const ValueKey('library-entry-add-education')));
      final id = draft(t).last.id;
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      final input = t.widget<DesktopTextField>(field(id, 'title'));
      expect(input.decoration.errorText, '请填写1–160字的经历名称。');
      expect(draft(t).last.id, id);
      expect((await model.source.readDetail(profile)).values, before.values);
      expect(t.takeException(), isNull);
    },
  );

  profileWidgets('cancelling an entry removal discards the draft only', (
    t,
  ) async {
    final model = await start(t);
    final before = await model.source.readDetail(profile);
    final first = WorkspaceRepeatedEntry.read(before.values['education']).first;
    await tap(t, find.text('编辑信息'));
    await tap(t, find.byKey(ValueKey('library-entry-remove-${first.id}')));
    await tap(t, find.text('取消'));
    expect(find.text('放弃修改'), findsOneWidget);
    await tap(t, find.text('放弃修改'));
    expect(find.byType(DesktopDialog), findsNothing);
    expect((await model.source.readDetail(profile)).values, before.values);
    expect(await model.source.loadRevisions(profile), isEmpty);
    expect(t.takeException(), isNull);
  });
  profileWidgets(
    'profile create is available from common add entry and supports an empty collection',
    (t) async {
      final model = await start(t);
      await tap(t, find.byKey(const ValueKey('library-create')));
      await tap(t, find.byKey(const ValueKey('library-new-type-profile')));
      expect(draft(t), isEmpty);
      await enter(t, find.byKey(const ValueKey('library-edit-name')), '新个人档案');
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(find.byType(DesktopDialog), findsNothing);
      final result = await model.source.queryRecords(
        const WorkspaceQuery(keyword: '新个人档案'),
      );
      expect(result.items, hasLength(1));
      expect(
        (await model.source.readDetail(
          result.items.single.ref,
        )).values['education'],
        isEmpty,
      );
      expect(t.takeException(), isNull);
    },
  );
}
