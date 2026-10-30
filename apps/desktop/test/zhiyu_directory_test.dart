import 'support/workspace_fixtures.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

Future<WorkspaceDirectory?> change(
  SampleWorkspaceSource source,
  String operation,
  WorkspaceDirectoryAction action, {
  String? id,
  String name = '',
  String? parent,
  int? version,
}) async => source.changeDirectory(
  WorkspaceDirectoryChange(
    operationId: operation,
    expectedVersion: version ?? (await source.loadCatalog()).version,
    action: action,
    directoryId: id,
    name: name,
    parentId: parent,
  ),
);

Matcher failure(String code) =>
    isA<WorkspaceFailure>().having((e) => e.code, 'code', code);

class RemovedTagSource extends SampleWorkspaceSource {
  String? removedTag;
  @override
  Future<WorkspaceCatalog> loadCatalog() async {
    final catalog = await super.loadCatalog();
    return WorkspaceCatalog(
      version: catalog.version,
      directories: catalog.directories,
      tags: catalog.tags.where((t) => t.id != removedTag),
      types: catalog.types,
      directoryCounts: catalog.directoryCounts,
      tagCounts: catalog.tagCounts,
    );
  }
}

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
  Future<void> capture(WidgetTester tester, String name) async {
    if (evidence.isEmpty) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('directory-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  test(
    'directory writes validate sibling names and paths, are versioned and idempotent',
    () async {
      final source = SampleWorkspaceSource();
      addTearDown(source.dispose);
      final before = await source.loadCatalog();
      final d = (await change(
        source,
        'new',
        WorkspaceDirectoryAction.create,
        name: '  MAC  ',
        version: before.version,
      ))!;
      final after = await source.loadCatalog();
      expect(d.name, 'MAC');
      expect(before.directories.any((x) => x.id == d.id), isFalse);
      expect(after.version, greaterThan(before.version));
      expect(
        identical(
          await change(
            source,
            'new',
            WorkspaceDirectoryAction.create,
            name: '  MAC  ',
            version: before.version,
          ),
          d,
        ),
        isTrue,
      );
      expect(
        (await source.loadCatalog()).directories.length,
        before.directories.length + 1,
      );
      await expectLater(
        change(source, 'new', WorkspaceDirectoryAction.create, name: 'Other'),
        throwsA(failure('operation_conflict')),
      );
      await expectLater(
        change(
          source,
          'duplicate',
          WorkspaceDirectoryAction.create,
          name: 'mac',
        ),
        throwsA(failure('validation')),
      );
      await expectLater(
        change(
          source,
          'slash',
          WorkspaceDirectoryAction.create,
          name: 'Mac/资料',
        ),
        throwsA(failure('validation')),
      );
      await expectLater(
        change(
          source,
          'backslash',
          WorkspaceDirectoryAction.create,
          name: r'Mac\资料',
        ),
        throwsA(failure('validation')),
      );
      await expectLater(
        change(
          source,
          'parent',
          WorkspaceDirectoryAction.create,
          name: 'Good',
          parent: 'missing',
        ),
        throwsA(failure('validation')),
      );
      await expectLater(
        change(
          source,
          'virtual-parent',
          WorkspaceDirectoryAction.create,
          name: 'Good',
          parent: 'all',
        ),
        throwsA(failure('validation')),
      );
      await expectLater(
        change(
          source,
          'stale',
          WorkspaceDirectoryAction.update,
          id: d.id,
          name: 'Other',
          version: before.version,
        ),
        throwsA(failure('conflict')),
      );
      expect((await source.loadCatalog()).version, after.version);
      await change(
        source,
        'same-name-other-parent',
        WorkspaceDirectoryAction.create,
        name: 'MAC',
        parent: d.id,
      );
    },
  );

  test(
    'moves preserve IDs and subtree counts; cycles and nonempty deletion reject atomically',
    () async {
      final source = SampleWorkspaceSource();
      addTearDown(source.dispose);
      final d = (await change(
        source,
        'parent',
        WorkspaceDirectoryAction.create,
        name: 'Mac',
      ))!;
      final child = (await change(
        source,
        'child',
        WorkspaceDirectoryAction.create,
        name: 'Child',
        parent: d.id,
      ))!;
      final before = await source.loadCatalog();
      for (final parent in [d.id, child.id]) {
        await expectLater(
          change(
            source,
            'cycle-$parent',
            WorkspaceDirectoryAction.update,
            id: d.id,
            name: 'Mac',
            parent: parent,
          ),
          throwsA(failure('validation')),
        );
      }
      await expectLater(
        change(source, 'nonempty', WorkspaceDirectoryAction.delete, id: d.id),
        throwsA(failure('directory_not_empty')),
      );
      expect((await source.loadCatalog()).version, before.version);
      await change(
        source,
        'move',
        WorkspaceDirectoryAction.update,
        id: 'selfhost',
        name: '自托管服务',
        parent: child.id,
      );
      final catalog = await source.loadCatalog();
      expect(catalog.directoryCounts[d.id], 15);
      expect(catalog.directoryCounts[child.id], 15);
      expect(
        (await source.queryRecords(WorkspaceQuery(directoryId: d.id))).total,
        15,
      );
      final record = await source.readDetail(
        const WorkspaceRecordRef(WorkspaceRecordKind.credential, 'aliyunkey'),
      );
      expect(record.record.directoryId, 'selfhost');
      expect(record.values, isEmpty);
      await expectLater(
        change(source, 'virtual', WorkspaceDirectoryAction.delete, id: 'all'),
        throwsA(failure('not_found')),
      );
    },
  );

  test(
    'a lone credential prevents empty deletion; failure does not change classification',
    () async {
      final source = SampleWorkspaceSource();
      addTearDown(source.dispose);
      final d = (await change(
        source,
        'credential-folder',
        WorkspaceDirectoryAction.create,
        name: '凭据',
      ))!;
      final original = await source.readDetail(
        const WorkspaceRecordRef(WorkspaceRecordKind.credential, 'aliyunkey'),
      );
      final moved = await source.saveRecord(
        WorkspaceEdit(
          operationId: 'classify',
          expectedVersion: original.version,
          record: original.record.copyWith(directoryId: d.id),
          values: {},
        ),
      );
      expect(moved, isA<WorkspaceSaved>());
      await expectLater(
        change(source, 'remove', WorkspaceDirectoryAction.delete, id: d.id),
        throwsA(failure('directory_not_empty')),
      );
      final before = await source.loadCatalog();
      source.nextSaveFailure = const WorkspaceFailure('unavailable', '合成失败');
      await expectLater(
        change(
          source,
          'fail-rename',
          WorkspaceDirectoryAction.update,
          id: d.id,
          name: '新名称',
        ),
        throwsA(failure('unavailable')),
      );
      final after = await source.loadCatalog();
      expect(after.version, before.version);
      expect(after.directories.singleWhere((x) => x.id == d.id).name, '凭据');
      expect(
        (await source.readDetail(original.record.ref)).record.directoryId,
        d.id,
      );
      source.reset();
      expect(
        (await source.loadCatalog()).directories.any((x) => x.id == d.id),
        isFalse,
      );
      expect(
        (await source.readDetail(original.record.ref)).record.directoryId,
        original.record.directoryId,
      );
    },
  );

  test(
    'deleting an active empty directory repairs only its filter and rereads detail',
    () async {
      final source = SampleWorkspaceSource();
      final model = LibraryController(source);
      addTearDown(model.dispose);
      addTearDown(source.dispose);
      final d = (await change(
        source,
        'empty',
        WorkspaceDirectoryAction.create,
        name: '空目录',
      ))!;
      await model.apply(
        WorkspaceQuery(directoryId: d.id, keyword: '日本', typeId: 'server'),
      );
      expect(model.selection, isNull);
      await change(source, 'delete', WorkspaceDirectoryAction.delete, id: d.id);
      // Observe the source-triggered projection, rather than starting a second load.
      for (var i = 0; i < 20 && model.query.directoryId != null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(model.query.directoryId, isNull);
      expect(model.query.keyword, '日本');
      expect(model.query.typeId, 'server');
      expect(model.query.offset, 0);
      expect(model.scopeNotice, isNotNull);
      expect(model.detail!.record.ref.id, 'azure');
    },
  );

  test(
    'a removed tag clears only that condition, retaining directory and keyword',
    () async {
      final source = RemovedTagSource();
      final model = LibraryController(source);
      addTearDown(model.dispose);
      addTearDown(source.dispose);
      final tag = (await source.loadCatalog()).tags.first;
      await model.apply(
        WorkspaceQuery(directoryId: 'selfhost', keyword: '日本', tagId: tag.id),
      );
      source.removedTag = tag.id;
      await model.load(model.query);
      expect(model.query.tagId, isNull);
      expect(model.query.directoryId, 'selfhost');
      expect(model.query.keyword, '日本');
      expect(model.detail!.record.ref.id, 'azure');
      expect(model.scopeNotice, isNotNull);
    },
  );

  Future<LibraryController> start(
    WidgetTester tester, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('directory-capture'),
        child: PreviewWorkspace(inputsBuilder: fixtureInputs),
      ),
    );
    await tester.pumpAndSettle();
    return tester.widget<LibraryPage>(find.byType(LibraryPage)).controller;
  }

  Future<void> enterName(WidgetTester t, String name) async {
    await t.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('library-directory-name')),
        matching: find.byType(TextField),
      ),
      name,
    );
    await t.pumpAndSettle();
  }

  Future<void> save(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('library-directory-save')));
    await t.pumpAndSettle();
  }

  testWidgets(
    'directory menu creates, preserves failed draft, moves and deletes from the actual library',
    (tester) async {
      final model = await start(tester);
      await tester.tap(find.byKey(const ValueKey('library-directory-create')));
      await tester.pumpAndSettle();
      await enterName(tester, 'Mac 工作');
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('unavailable', '合成目录保存失败');
      await save(tester);
      expect(find.text('合成目录保存失败'), findsOneWidget);
      await capture(tester, 'directory-failure-1280-light');
      expect(find.widgetWithText(TextField, 'Mac 工作'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('尚有未保存的目录修改。'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('尚有未保存的目录修改。'), findsNothing);
      await save(tester);
      final d = model.catalog!.directories.singleWhere(
        (x) => x.name == 'Mac 工作',
      );
      expect(d.parentId, 'selfhost');
      await tester.tap(find.byKey(ValueKey('library-directory-${d.id}')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('library-directory-actions-${d.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名或移动'));
      await tester.pumpAndSettle();
      await enterName(tester, 'Mac 顶层');
      await capture(tester, 'directory-edit-1280-light');
      await tester.tap(find.byKey(const ValueKey('library-directory-parent')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('顶层目录').last);
      await tester.pumpAndSettle();
      await save(tester);
      expect(
        model.catalog!.directories.singleWhere((x) => x.id == d.id).parentId,
        isNull,
      );
      expect(model.query.directoryId, d.id);
      await tester.tap(
        find.byKey(ValueKey('library-directory-actions-${d.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除空目录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Mac 顶层'), findsWidgets);
      await capture(tester, 'directory-delete-1280-light');
      await save(tester);
      expect(model.catalog!.directories.any((x) => x.id == d.id), isFalse);
      expect(model.query.directoryId, isNull);
      expect(find.text('原目录或标签已移除，已清除失效的筛选条件。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'concurrent catalog changes require explicit reload without dropping a large-text draft',
    (tester) async {
      final model = await start(tester, scale: 2);
      final source = model.source as SampleWorkspaceSource;
      await fixtureTap(tester, find.byKey(const ValueKey('preview-guide')));
      await tester.pumpAndSettle();
      await fixtureTap(
        tester,
        find.byKey(const ValueKey('preview-theme-dark')),
      );
      await tester.pumpAndSettle();
      final create = find.byKey(const ValueKey('library-directory-create'));
      await tester.scrollUntilVisible(
        create,
        160,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('library-directory-pane')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(create);
      await tester.pumpAndSettle();
      await enterName(tester, '集中验收目录');
      await change(
        source,
        'concurrent',
        WorkspaceDirectoryAction.create,
        name: '并发目录',
      );
      await tester.pumpAndSettle();
      await save(tester);
      expect(find.text('目录已变化，请重新读取后核对。'), findsOneWidget);
      await capture(tester, 'directory-conflict-1280-dark-large-text');
      final button = tester.widget<DesktopButton>(
        find.byKey(const ValueKey('library-directory-save')),
      );
      expect(button.onPressed, isNull);
      await tester.tap(find.text('重新读取目录'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '集中验收目录'), findsOneWidget);
      await save(tester);
      expect(model.catalog!.directories.any((d) => d.name == '集中验收目录'), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
