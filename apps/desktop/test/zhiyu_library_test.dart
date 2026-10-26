import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
const aliyun = WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun');

class CountingSample extends SampleWorkspaceSource {
  final detailsRead = <WorkspaceRecordRef>[];
  @override
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) {
    detailsRead.add(ref);
    return super.readDetail(ref);
  }
}

void main() {
  test(
    'related navigation removes only blocking filters and restores exact origin',
    () async {
      final source = CountingSample();
      final model = LibraryController(source);
      addTearDown(model.dispose);
      addTearDown(source.dispose);
      final catalog = await source.loadCatalog();
      final tag = catalog.tags.singleWhere((t) => t.name == '生产环境');
      await model.apply(
        WorkspaceQuery(
          directoryId: 'selfhost',
          keyword: '日本',
          typeId: 'server',
          tagId: tag.id,
        ),
      );
      expect(model.selection, azure);
      model.scrollOffset = 125;
      source.detailsRead.clear();
      await model.openRelated(aliyun);
      expect(model.selection, aliyun);
      expect(model.query.keyword, '');
      expect(model.query.directoryId, 'selfhost');
      expect(model.query.typeId, 'server');
      expect(model.query.tagId, tag.id);
      expect(source.detailsRead, [aliyun]);
      await model.goBack();
      expect(model.query.keyword, '日本');
      expect(model.selection, azure);
      expect(model.scrollOffset, 125);
      await model.clearFilters();
      expect(model.query.directoryId, 'selfhost');
      await model.showAll();
      expect(model.query.directoryId, isNull);
      expect(model.query.typeId, isNull);
      expect(model.query.tagId, isNull);
    },
  );

  test(
    'catalog counts include descendants and credentials; create is validated and idempotent',
    () async {
      final source = SampleWorkspaceSource();
      addTearDown(source.dispose);
      final catalog = await source.loadCatalog();
      expect(catalog.directoryCounts['all'], 31);
      expect(catalog.directoryCounts['selfhost'], 15);
      expect(catalog.directoryCounts['personal'], 6);
      expect(catalog.directoryCounts['career'], 5);
      final invalid =
          await source.createRecord(
                WorkspaceCreate(
                  operationId: 'invalid-create',
                  typeId: 'server',
                  name: '新服务器',
                  values: {'host': 'mac.example', 'port': 'NaN'},
                ),
              )
              as WorkspaceRejected;
      expect(invalid.failure.fieldErrors['port'], isNotNull);
      expect((await source.loadSummary()).records, 31);
      final draft = WorkspaceCreate(
        operationId: 'create-mac',
        typeId: 'server',
        name: '新服务器',
        directoryId: 'selfhost',
        values: {'host': 'mac.example', 'port': '22'},
      );
      final created = await source.createRecord(draft) as WorkspaceSaved;
      expect(identical(await source.createRecord(draft), created), isTrue);
      expect((await source.loadSummary()).records, 32);
      expect((await source.loadCatalog()).directoryCounts['selfhost'], 16);
      final metadata = await source.readSummaries([created.detail.record.ref]);
      expect(metadata.single.name, '新服务器');
    },
  );

  Future<void> start(
    WidgetTester tester, {
    double width = 1440,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(const PreviewWorkspace());
    await tester.pumpAndSettle();
  }

  Finder field(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(TextField),
  );
  Future<void> enter(WidgetTester tester, String key, String text) async {
    final target = field(key);
    await tester.ensureVisible(target);
    await tester.enterText(target, text);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    final target = find.byKey(const ValueKey('library-edit-save'));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'real preview has responsive three panes and metadata filtering',
    (tester) async {
      await start(tester);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('library-directory-pane')))
            .width,
        214,
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('library-results-pane')))
            .width,
        300,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('library-detail-title')))
            .data,
        'Azure 日本服务器',
      );
      await tester.tap(find.byKey(const ValueKey('library-directory-all')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        '日本',
      );
      await tester.pumpAndSettle();
      final model = tester
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller;
      expect(
        model.results!.items.every(
          (r) => '${r.name} ${r.description} ${r.tags.map((t) => t.name)}'
              .contains('日本'),
        ),
        isTrue,
      );
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        '不存在的关键词',
      );
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的资料'), findsOneWidget);
      await tester.tap(find.text('清除筛选'));
      await tester.pumpAndSettle();
      expect(model.results!.total, 31);
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(find.byKey(const ValueKey('library-directory-pane')))
            .width,
        194,
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('library-results-pane')))
            .width,
        275,
      );
      await tester.tap(find.byTooltip('展开阅读'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-directory-pane')),
        findsNothing,
      );
      expect(find.text('退出展开'), findsOneWidget);
      await tester.tap(find.text('退出展开'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-directory-pane')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'edit failure retains draft and explicit retry rereads the saved record',
    (tester) async {
      await start(tester);
      final model = tester
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller;
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('offline', '保存失败，请重试。');
      await tester.tap(find.text('编辑信息'));
      await tester.pumpAndSettle();
      await enter(tester, 'library-edit-description', '新的服务器用途');
      await save(tester);
      expect(find.text('保存失败，请重试。'), findsOneWidget);
      final status = tester.getRect(
        find.byKey(const ValueKey('library-edit-status')),
      );
      expect(status.top, greaterThan(0));
      expect(status.bottom, lessThan(tester.view.physicalSize.height));
      expect(
        tester
            .widget<TextField>(field('library-edit-description'))
            .controller!
            .text,
        '新的服务器用途',
      );
      await save(tester);
      expect(find.byType(DesktopDialog), findsNothing);
      expect(
        (await model.source.readDetail(azure)).record.description,
        '新的服务器用途',
      );
      expect(find.text('已保存资料'), findsOneWidget);
    },
  );

  testWidgets(
    'an outstanding refresh cannot open a saving form that cannot finish',
    (tester) async {
      await start(tester);
      final model = tester
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller;
      final source = model.source as SampleWorkspaceSource;
      source.setScenario(SampleWorkspaceScenario.waiting);
      final pending = model.load(model.query);
      await tester.pump();
      expect(
        tester
            .widget<DesktopButton>(find.byKey(const ValueKey('library-create')))
            .onPressed,
        isNull,
      );
      final edit = find.widgetWithText(DesktopButton, '编辑信息');
      expect(tester.widget<DesktopButton>(edit).onPressed, isNull);
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pump();
      expect(find.byType(DesktopDialog), findsNothing);
      source.setScenario(SampleWorkspaceScenario.ready);
      await pending;
      await model.load(model.query);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DesktopButton>(find.byKey(const ValueKey('library-create')))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'opening a related record resets its detail scroll to the identity header',
    (tester) async {
      await start(tester);
      final link = find.byKey(
        const ValueKey('library-relation-information:aliyun'),
      );
      await tester.ensureVisible(link);
      expect(
        tester.getRect(find.byKey(const ValueKey('library-detail-title'))).top,
        lessThan(0),
      );
      await tester.tap(link);
      await tester.pumpAndSettle();
      final title = find.byKey(const ValueKey('library-detail-title'));
      expect(tester.widget<Text>(title).data, '阿里云杭州服务器');
      expect(
        tester.getRect(title).top,
        greaterThan(
          tester
              .getRect(find.byKey(const ValueKey('library-detail-scroll')))
              .top,
        ),
      );
    },
  );

  testWidgets(
    'create validates required fields before adding and selecting a record',
    (tester) async {
      await start(tester);
      await tester.tap(find.byKey(const ValueKey('library-create')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(DesktopDialog),
          matching: find.text('服务器信息'),
        ),
      );
      await tester.pumpAndSettle();
      await save(tester);
      expect(find.text('请输入1–160字的名称。'), findsOneWidget);
      expect(find.text('请填写主机地址。'), findsOneWidget);
      await enter(tester, 'library-edit-name', 'Mac 测试服务器');
      await enter(tester, 'library-edit-host', 'mac.example');
      await save(tester);
      expect(find.byType(DesktopDialog), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('library-detail-title')))
            .data,
        'Mac 测试服务器',
      );
      final model = tester
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller;
      expect((await model.source.loadSummary()).records, 32);
    },
  );

  testWidgets('large text keeps library and edit actions reachable', (
    tester,
  ) async {
    await start(tester, width: 1280, scale: 2);
    expect(tester.takeException(), isNull);
    final edit = find.text('编辑信息');
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await enter(tester, 'library-edit-name', '放大文字下的编辑');
    await save(tester);
    expect(find.byType(DesktopDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
