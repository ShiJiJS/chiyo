import 'support/workspace_fixtures.dart';
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

const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
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
      find.byKey(const ValueKey('stress-capture')),
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

  Future<void> guide(WidgetTester t) async {
    await fixtureTap(t, find.byKey(const ValueKey('preview-guide')));
    await t.pumpAndSettle();
  }

  Future<void> dataset(WidgetTester t, bool stress) async {
    await guide(t);
    final button = find.byKey(
      ValueKey('preview-dataset-${stress ? 'stress' : 'reference'}'),
    );
    await fixtureTap(t, button);
    await t.pumpAndSettle();
  }

  Future<LibraryController> start(
    WidgetTester t, {
    double scale = 1,
    bool dark = false,
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
        key: ValueKey('stress-capture'),
        child: PreviewWorkspace(inputsBuilder: fixtureInputs),
      ),
    );
    await t.pumpAndSettle();
    if (dark) {
      await guide(t);
      await fixtureTap(t, find.byKey(const ValueKey('preview-theme-dark')));
      await t.pumpAndSettle();
    }
    await dataset(t, true);
    return t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
  }

  Future<void> tapVisible(
    WidgetTester t,
    Finder target,
    Finder viewport,
  ) async {
    if (await prepareFixtureAction(t, target)) return;
    await t.pumpAndSettle();
    final visible = t.getRect(target).intersect(t.getRect(viewport));
    expect(visible.width, greaterThan(10));
    expect(visible.height, greaterThan(10));
    await t.tapAt(visible.center);
    await t.pumpAndSettle();
  }

  Finder optionsSearch() => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == '搜索选项',
  );

  testWidgets(
    'real pressure switch, pagination, related navigation and return preserve selected row and list scroll',
    (t) async {
      final model = await start(t);
      expect(model.results!.total, 208);
      expect(model.query.directoryId, isNull);
      await t.tap(find.byTooltip('下一页'));
      await t.pumpAndSettle();
      expect(model.query.offset, 50);
      final record = model.results!.items.lastWhere(
        (r) => r.ref.id.startsWith('stress-info-'),
      );
      final row = find.byKey(ValueKey('library-record-${record.ref.key}'));
      await t.scrollUntilVisible(
        row,
        400,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('library-results-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tapVisible(
        t,
        row,
        find.byKey(const ValueKey('library-results-scroll')),
      );
      expect(model.selection, record.ref);
      final scroll = model.scrollOffset;
      expect(scroll, greaterThan(100));
      await capture(t, 'stress-page-selection-1280-light');
      await t.tap(find.text('关联资料'));
      await t.pumpAndSettle();
      final related = find.byKey(
        const ValueKey('library-relation-information:azure'),
      );
      await t.ensureVisible(related);
      await t.tap(related);
      await t.pumpAndSettle();
      expect(model.selection, azure);
      expect(model.query.offset, isNot(50));
      await t.tap(find.byKey(const ValueKey('library-back')));
      await t.pumpAndSettle();
      expect(model.query.offset, 50);
      expect(model.selection, record.ref);
      expect(model.scrollOffset, closeTo(scroll, 1));
      expect(t.takeException(), isNull);
    },
  );

  for (final width in [1280.0, 1440.0]) {
    testWidgets(
      '50-directory tree and 100-tag menu remain usable with a long title and 200% dark text at $width',
      (t) async {
        final model = await start(t, scale: 2, dark: true, width: width);
        const long = WorkspaceRecordRef(
          WorkspaceRecordKind.information,
          'stress-info-024',
        );
        await model.openRelated(long);
        await t.pumpAndSettle();
        expect(model.selection, long);
        await capture(t, 'stress-long-detail-${width.toInt()}-dark-200');
        final directory = find.byKey(
          const ValueKey('library-directory-stress-directory-49'),
        );
        await t.scrollUntilVisible(
          directory,
          220,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('library-directory-pane')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tapVisible(
          t,
          directory,
          find.descendant(
            of: find.byKey(const ValueKey('library-directory-pane')),
            matching: find.byType(ListView),
          ),
        );
        expect(model.query.directoryId, 'stress-directory-49');
        await capture(t, 'stress-directory-tail-${width.toInt()}-dark-200');
        await t.tap(find.byKey(const ValueKey('library-tag-filter')));
        await t.pumpAndSettle();
        final longTag = model.catalog!.tags.singleWhere(
          (t) => t.name.startsWith('跨设备维护记录'),
        );
        await t.enterText(optionsSearch(), '跨设备维护记录');
        await t.pumpAndSettle();
        await capture(t, 'stress-tag-menu-${width.toInt()}-dark-200');
        await t.testTextInput.receiveAction(TextInputAction.done);
        await t.pumpAndSettle();
        expect(model.query.tagId, longTag.id);
        expect(find.text('没有匹配的资料'), findsOneWidget);
        await t.ensureVisible(find.text('清除筛选'));
        await t.pumpAndSettle();
        expect(
          t.getRect(find.widgetWithText(DesktopButton, '清除筛选')).bottom,
          lessThanOrEqualTo(
            t.getRect(find.byKey(const ValueKey('library-results-footer'))).top,
          ),
        );
        await capture(t, 'stress-long-tag-empty-${width.toInt()}-dark-200');
        await t.tap(find.text('清除筛选'));
        await t.pumpAndSettle();
        expect(model.query.directoryId, 'stress-directory-49');
        expect(model.query.tagId, isNull);
        expect(model.results!.total, greaterThan(0));
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'large edit form retains hundred-tag choices and cross-page relation selections through failed save',
    (t) async {
      final model = await start(t);
      await model.openRelated(azure);
      await t.pumpAndSettle();
      final original = await model.source.readDetail(azure);
      await t.tap(find.text('编辑信息'));
      await t.pumpAndSettle();
      final tag = model.catalog!.tags.singleWhere((t) => t.name == '压力标签 099');
      final tagChip = find.descendant(
        of: find.byType(DesktopDialog),
        matching: find.text(tag.name),
      );
      await t.ensureVisible(tagChip);
      await t.tap(tagChip);
      await t.pumpAndSettle();
      final choose = find.byKey(
        const ValueKey('library-relation-choose-related'),
      );
      await t.ensureVisible(choose);
      await t.tap(choose);
      await t.pumpAndSettle();
      final first = await model.source.queryRelationCandidates(
        const WorkspaceRelationQuery(
          typeId: 'server',
          key: 'related',
          source: azure,
          limit: 15,
        ),
      );
      final early = first.items.firstWhere(
        (r) => !original.relations['related']!.contains(r.ref),
      );
      final earlyOption = find.byKey(
        ValueKey('library-relation-option-related-${early.ref.key}'),
      );
      await t.ensureVisible(earlyOption);
      await t.tap(earlyOption);
      await t.pumpAndSettle();
      for (var page = 0; page < 5; page++) {
        await t.tap(find.widgetWithText(DesktopButton, '下一页'));
        await t.pumpAndSettle();
      }
      final late = await model.source.queryRelationCandidates(
        const WorkspaceRelationQuery(
          typeId: 'server',
          key: 'related',
          source: azure,
          offset: 75,
          limit: 15,
        ),
      );
      final selected = late.items.first;
      final lateOption = find.byKey(
        ValueKey('library-relation-option-related-${selected.ref.key}'),
      );
      await t.ensureVisible(lateOption);
      await t.tap(lateOption);
      await t.pumpAndSettle();
      await capture(t, 'stress-relation-page-six-1280-light');
      await t.tap(find.byKey(const ValueKey('library-relation-done-related')));
      await t.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey('library-relation-remove-related-${early.ref.key}'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          ValueKey('library-relation-remove-related-${selected.ref.key}'),
        ),
        findsOneWidget,
      );
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('unavailable', '压力资料保存失败');
      await t.tap(find.byKey(const ValueKey('library-edit-save')));
      await t.pumpAndSettle();
      expect(find.text('压力资料保存失败'), findsOneWidget);
      expect((await model.source.readDetail(azure)).version, original.version);
      await t.tap(find.byKey(const ValueKey('library-edit-save')));
      await t.pumpAndSettle();
      final saved = await model.source.readDetail(azure);
      expect(saved.record.tags.any((value) => value.id == tag.id), isTrue);
      expect(
        saved.relations['related'],
        containsAll([
          ...original.relations['related']!,
          early.ref,
          selected.ref,
        ]),
      );
      expect(saved.relations['credentials'], original.relations['credentials']);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'switching dataset from recycle clears internal location and return stack and restores baseline count',
    (t) async {
      final model = await start(t);
      await model.openRelated(azure);
      await t.pumpAndSettle();
      expect(model.canGoBack, isTrue);
      await t.tap(find.byKey(const ValueKey('library-open-recycle')));
      await t.pumpAndSettle();
      expect(find.text('旧部署笔记'), findsOneWidget);
      await dataset(t, false);
      expect(
        find.byKey(const ValueKey('library-results-pane')),
        findsOneWidget,
      );
      expect(model.canGoBack, isFalse);
      expect(model.selection, azure);
      expect((await model.source.loadSummary()).records, 31);
      expect(model.query.directoryId, 'selfhost');
      expect(model.scrollOffset, 0);
      expect((await model.source.queryRecycled()).total, 1);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'all tag options are keyboard searchable and clearing keeps other filters',
    (t) async {
      final model = await start(t);
      await model.apply(
        model.query.copyWith(typeId: 'server', keyword: '压力资料'),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('library-tag-filter')));
      await t.pumpAndSettle();
      final tag = model.catalog!.tags.singleWhere((t) => t.name == '压力标签 099');
      await t.enterText(optionsSearch(), tag.name);
      await t.pumpAndSettle();
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(model.query.tagId, tag.id);
      expect(model.query.typeId, 'server');
      expect(model.query.keyword, '压力资料');
      await t.tap(find.byKey(const ValueKey('library-tag-filter')));
      await t.pumpAndSettle();
      await t.enterText(optionsSearch(), '全部标签');
      await t.pumpAndSettle();
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(model.query.tagId, isNull);
      expect(model.query.typeId, 'server');
      expect(model.query.keyword, '压力资料');
      expect(t.takeException(), isNull);
    },
  );
}
