import 'support/workspace_fixtures.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/classification_page.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_fixture.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

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
  Future<void> ready(WidgetTester t) async {
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> tap(WidgetTester t, Finder f) async {
    if (await prepareFixtureAction(t, f)) return;
    await t.ensureVisible(f);
    await ready(t);
    await t.tap(f);
    await ready(t);
  }

  Future<void> enter(WidgetTester t, String key, String text) async {
    final target = find.byKey(ValueKey(key));
    await t.enterText(
      target.evaluate().single.widget is TextField
          ? target
          : find.descendant(of: target, matching: find.byType(TextField)),
      text,
    );
    await ready(t);
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    await t.runAsync(() async {
      final b = t.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('classification-capture')),
          ),
          image = await b.toImage(pixelRatio: 1),
          bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<SampleWorkspaceSource> start(
    WidgetTester t, {
    bool dark = false,
  }) async {
    t.view.physicalSize = dark ? const Size(1280, 800) : const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = dark ? 2 : 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('classification-capture'),
        child: PreviewWorkspace(inputsBuilder: fixtureInputs),
      ),
    );
    await ready(t);
    final s =
        t.widget<LibraryPage>(find.byType(LibraryPage)).controller.source
            as SampleWorkspaceSource;
    if (dark) {
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-theme-dark')));
    }
    await tap(t, find.byKey(const ValueKey('workspace-nav-settings')));
    if (dark) {
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('settings-section-classifications')),
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('settings-sidebar-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
    }
    await tap(
      t,
      find.byKey(const ValueKey('settings-section-classifications')),
    );
    return s;
  }

  testWidgets(
    'shared settings directory manager creates a hierarchy, preserves failed drafts, and uses the same library tree',
    (t) async {
      final s = await start(t);
      await capture(t, 'classification-1440-light-directories');
      await tap(t, find.byKey(const ValueKey('classification-create')));
      await enter(t, 'library-directory-name', 'Mac 分类目录');
      s.nextSaveFailure = const WorkspaceFailure(
        'disk_full',
        '目录暂时无法保存，修改已保留。',
      );
      await tap(t, find.byKey(const ValueKey('library-directory-save')));
      expect(find.text('目录暂时无法保存，修改已保留。'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('library-directory-save')));
      final parent = (await s.loadCatalog()).directories.singleWhere(
        (d) => d.name == 'Mac 分类目录',
      );
      await enter(t, 'classification-search', 'Mac 分类目录');
      await tap(t, find.byKey(ValueKey('classification-child-${parent.id}')));
      await enter(t, 'library-directory-name', 'Mac 子目录');
      await tap(t, find.byKey(const ValueKey('library-directory-save')));
      final child = (await s.loadCatalog()).directories.singleWhere(
        (d) => d.name == 'Mac 子目录',
      );
      expect(child.parentId, parent.id);
      await tap(t, find.byKey(ValueKey('classification-delete-${parent.id}')));
      await tap(t, find.byKey(const ValueKey('library-directory-save')));
      expect(find.textContaining('目录包含资料'), findsOneWidget);
      await tap(t, find.text('取消'));
      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      final library = t
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller;
      expect(
        library.catalog!.directories.any(
          (d) => d.id == child.id && d.parentId == parent.id,
        ),
        true,
      );
      await tap(t, find.byKey(const ValueKey('workspace-nav-settings')));
      expect(find.byType(ClassificationPage), findsOneWidget);
      expect(
        t
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const ValueKey('classification-search')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        'Mac 分类目录',
      );
    },
  );
  testWidgets(
    'tag rename updates current library metadata; deletion rechecks reviewed membership and preserves the actual content',
    (t) async {
      final s = await start(t);
      final catalog = await s.loadCatalog(),
          tag = catalog.tags.firstWhere(
            (t) => (catalog.tagCounts[t.id] ?? 0) > 0,
          );
      await tap(t, find.byKey(const ValueKey('classification-kind-tag')));
      await enter(t, 'classification-search', tag.name);
      await tap(t, find.byKey(ValueKey('classification-edit-${tag.id}')));
      await enter(t, 'classification-tag-name', 'Mac 分类标记');
      await tap(t, find.byKey(const ValueKey('classification-tag-save')));
      final members = await s.queryRecords(WorkspaceQuery(tagId: tag.id));
      expect(members.total, greaterThan(0));
      await capture(t, 'classification-1440-light-tags');
      await tap(t, find.byKey(ValueKey('classification-delete-${tag.id}')));
      expect(find.text('将影响 ${members.total} 条当前资料或凭据。'), findsOneWidget);
      await capture(t, 'classification-1440-light-tag-removal');
      final target = members.items.first.ref, old = await s.readDetail(target);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'concurrent-owner',
          expectedVersion: old.version,
          record: old.record.copyWith(description: '合成说明更新'),
          values: const {},
        ),
      );
      await ready(t);
      await tap(t, find.byKey(const ValueKey('classification-tag-save')));
      expect(find.textContaining('标签影响范围已变化'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('classification-reload')));
      await tap(t, find.byKey(const ValueKey('classification-tag-save')));
      expect((await s.loadCatalog()).tags.any((t) => t.id == tag.id), false);
      expect((await s.readDetail(target)).values, old.values);
      expect((await s.readDetail(target)).record.description, '合成说明更新');
      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      await enter(t, 'library-search', 'Mac 分类标记');
      final library = t
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller;
      expect(library.results!.total, 0);
      expect(library.detail, isNull);
    },
  );
  testWidgets(
    'dark200 tag edit failure keeps the draft; unknown commit blocks close and resolves only the original operation',
    (t) async {
      final s = await start(t, dark: true);
      await tap(t, find.byKey(const ValueKey('classification-child-selfhost')));
      expect(
        find.byKey(const ValueKey('library-directory-name')),
        findsOneWidget,
      );
      await tap(t, find.text('取消'));
      await capture(t, 'classification-1280-dark200-directories');
      await tap(t, find.byKey(const ValueKey('classification-kind-tag')));
      await tap(t, find.byKey(const ValueKey('classification-create')));
      await enter(t, 'classification-tag-name', 'Mac 深色标签');
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '标签保存失败，输入保留。');
      await tap(t, find.byKey(const ValueKey('classification-tag-save')));
      expect(find.text('标签保存失败，输入保留。'), findsOneWidget);
      await capture(t, 'classification-1280-dark200-tag-failure');
      s.loseNextClassificationReply = true;
      await tap(t, find.byKey(const ValueKey('classification-tag-save')));
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('desktop-dialog-close')),
            )
            .onPressed,
        isNull,
      );
      await tap(t, find.byKey(const ValueKey('desktop-dialog-close')));
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('classification-tag-save')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const ValueKey('classification-reconcile')),
        findsOneWidget,
      );
      await capture(t, 'classification-1280-dark200-tag-unknown');
      await tap(t, find.byKey(const ValueKey('classification-reconcile')));
      expect(
        (await s.loadCatalog()).tags.where((t) => t.name == 'Mac 深色标签'),
        hasLength(1),
      );
      await capture(t, 'classification-1280-dark200-tags');
    },
  );
  testWidgets(
    'classification read failure is distinct from empty and waiting; retry restores the same manager and empty tags can be created',
    (t) async {
      final s = await start(t),
          m = t
              .widget<ClassificationPage>(find.byType(ClassificationPage))
              .controller;
      s.setScenario(SampleWorkspaceScenario.failure);
      await m.load();
      await ready(t);
      expect(
        find.byKey(const ValueKey('classification-read-retry')),
        findsOneWidget,
      );
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('classification-create')),
            )
            .onPressed,
        isNull,
      );
      s.setScenario(SampleWorkspaceScenario.ready);
      await tap(t, find.byKey(const ValueKey('classification-read-retry')));
      expect(m.failure, isNull);
      s.setScenario(SampleWorkspaceScenario.waiting);
      final pending = m.load();
      await t.pump();
      expect(find.byType(LinearProgressIndicator), findsWidgets);
      s.setScenario(SampleWorkspaceScenario.ready);
      await pending;
      await m.load();
      await ready(t);
      final data = jsonDecode(sampleWorkspaceJson) as Map<String, dynamic>;
      data['records'] = [];
      data['trash'] = [];
      data['tags'] = [];
      data['pending'] = 0;
      data['proposals'] = 0;
      await s.replaceFixture(jsonEncode(data));
      await ready(t);
      await tap(t, find.byKey(const ValueKey('classification-kind-tag')));
      expect(find.text('还没有标签，可以从上方新建。'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('classification-create')));
      await enter(t, 'classification-tag-name', '空库第一个标签');
      await tap(t, find.byKey(const ValueKey('classification-tag-save')));
      expect((await s.loadCatalog()).tags.single.name, '空库第一个标签');
    },
  );
}
