import 'support/workspace_fixtures.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_relation_picker.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/sample_workspace_fixture.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
const aliyun = WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun');
const blinko = WorkspaceRecordRef(WorkspaceRecordKind.information, 'blinko');
const secret = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'aliyunkey');

class CountedRelations extends SampleWorkspaceSource {
  int bodiesRead = 0;
  @override
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) {
    bodiesRead++;
    return super.readDetail(ref);
  }
}

class DeferredRelations extends SampleWorkspaceSource {
  final requests =
      <({WorkspaceRelationQuery query, Completer<WorkspaceResults> result})>[];
  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  ) {
    final result = Completer<WorkspaceResults>();
    requests.add((query: query, result: result));
    return result.future;
  }

  Future<WorkspaceResults> actual(WorkspaceRelationQuery query) =>
      super.queryRelationCandidates(query);
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
  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    final boundary = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('relation-capture')),
    );
    await t.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  test(
    'relation candidates are metadata only, honor type limits and page after filtering',
    () async {
      final source = CountedRelations();
      addTearDown(source.dispose);
      final first = await source.queryRelationCandidates(
        const WorkspaceRelationQuery(
          typeId: 'server',
          key: 'related',
          source: azure,
          limit: 15,
        ),
      );
      final second = await source.queryRelationCandidates(
        const WorkspaceRelationQuery(
          typeId: 'server',
          key: 'related',
          source: azure,
          limit: 15,
          offset: 15,
        ),
      );
      expect(first.total, 30);
      expect(
        {
          ...first.items.map((r) => r.ref),
          ...second.items.map((r) => r.ref),
        }.length,
        30,
      );
      expect(first.items.any((r) => r.ref == azure), isFalse);
      final hosts = await source.queryRelationCandidates(
        const WorkspaceRelationQuery(
          typeId: 'service',
          key: 'hostedOn',
          source: blinko,
        ),
      );
      expect(hosts.items, isNotEmpty);
      expect(hosts.items.every((r) => r.type.id == 'server'), isTrue);
      final bodyQuery = await source.queryRelationCandidates(
        const WorkspaceRelationQuery(
          typeId: 'server',
          key: 'related',
          source: azure,
          keyword: 'tokyo.beichen.example',
        ),
      );
      expect(bodyQuery.total, 0);
      expect(source.bodiesRead, 0);
      expect(
        (await source.readSummaries([secret])).single.type.id,
        'credential',
      );
      expect(source.bodiesRead, 0);
    },
  );

  test(
    'relation edits share record version, reject invalid targets atomically and keep untouched keys',
    () async {
      final source = SampleWorkspaceSource();
      addTearDown(source.dispose);
      final original = await source.readDetail(azure);
      Future<WorkspaceSaveResult> save(
        String id,
        Map<String, List<WorkspaceRecordRef>> changes,
      ) => source.saveRecord(
        WorkspaceEdit(
          operationId: id,
          expectedVersion: original.version,
          record: original.record,
          values: {},
          relations: changes,
        ),
      );
      for (final refs in [
        [azure],
        [aliyun, aliyun],
        [const WorkspaceRecordRef(WorkspaceRecordKind.information, 'gone')],
        [
          const WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            'aliyunkey',
          ),
        ],
      ]) {
        final result =
            await save('invalid-${refs.map((r) => r.key).join(',')}', {
                  'related': refs,
                })
                as WorkspaceRejected;
        expect(result.failure.fieldErrors['relation:related'], isNotNull);
        expect((await source.readDetail(azure)).version, original.version);
      }
      final edit = WorkspaceEdit(
        operationId: 'related-save',
        expectedVersion: original.version,
        record: original.record,
        values: {},
        relations: {
          'related': [blinko],
        },
      );
      final result = await source.saveRecord(edit) as WorkspaceSaved;
      expect(identical(await source.saveRecord(edit), result), isTrue);
      expect(result.detail.relations['related'], [blinko]);
      expect(
        result.detail.relations['credentials'],
        original.relations['credentials'],
      );
      expect(result.detail.relations['docs'], original.relations['docs']);
      expect((await source.readDetail(azure)).version, original.version + 1);
      final stale = await save('stale', {'related': []}) as WorkspaceRejected;
      expect(stale.failure.code, 'conflict');
      expect((await source.readDetail(azure)).relations['related'], [blinko]);
      expect(() => edit.relations['related']!.clear(), throwsUnsupportedError);
      final protected = await source.readDetail(secret);
      final blocked =
          await source.saveRecord(
                WorkspaceEdit(
                  operationId: 'credential-relation',
                  expectedVersion: protected.version,
                  record: protected.record,
                  values: {},
                  relations: {'related': []},
                ),
              )
              as WorkspaceRejected;
      expect(blocked.failure.code, 'unsupported');
      expect((await source.readDetail(secret)).values, isEmpty);
    },
  );

  test(
    'new relations enforce template targets but allow ordinary graph cycles',
    () async {
      final source = SampleWorkspaceSource();
      addTearDown(source.dispose);
      final service = await source.readDetail(blinko);
      final rejected =
          await source.saveRecord(
                WorkspaceEdit(
                  operationId: 'wrong-host',
                  expectedVersion: service.version,
                  record: service.record,
                  values: {},
                  relations: {
                    'hostedOn': [secret],
                  },
                ),
              )
              as WorkspaceRejected;
      expect(rejected.failure.fieldErrors['relation:hostedOn'], isNotNull);
      final a =
          (await source.createRecord(
                WorkspaceCreate(
                  operationId: 'generic-a',
                  typeId: 'generic',
                  name: 'A',
                  values: {'body': 'A正文'},
                ),
              ))
              as WorkspaceSaved;
      final b =
          (await source.createRecord(
                WorkspaceCreate(
                  operationId: 'generic-b',
                  typeId: 'generic',
                  name: 'B',
                  relations: {
                    'related': [a.detail.record.ref],
                  },
                ),
              ))
              as WorkspaceSaved;
      final cycle = await source.saveRecord(
        WorkspaceEdit(
          operationId: 'cycle',
          expectedVersion: a.detail.version,
          record: a.detail.record,
          values: {},
          relations: {
            'related': [b.detail.record.ref],
          },
        ),
      );
      expect(cycle, isA<WorkspaceSaved>());
      final failure =
          await source.createRecord(
                WorkspaceCreate(
                  operationId: 'bad-create',
                  typeId: 'service',
                  name: '坏关联',
                  relations: {
                    'hostedOn': [secret],
                  },
                ),
              )
              as WorkspaceRejected;
      expect(failure.failure.fieldErrors['relation:hostedOn'], isNotNull);
    },
  );

  test(
    'legacy dangling links and unknown values survive unrelated edits; generic fields stay readable',
    () async {
      final fixture = jsonDecode(sampleWorkspaceJson) as Map<String, dynamic>;
      final rows = fixture['records'] as List;
      rows.singleWhere((r) => r['id'] == 'azure')['relations']['related'] = [
        'deleted-target',
      ];
      final legacy = rows.singleWhere((r) => r['id'] == 'ideas');
      legacy['values']['旧字段'] = '仍需保留的正文';
      legacy['values']['旧结构'] = {'原文': '保留原始形状'};
      rows.add({
        ...Map<String, dynamic>.from(legacy),
        'id': 'complex-legacy',
        'name': '复合旧资料',
        'values': {
          'body': {'原文': '复合正文'},
        },
      });
      final source = SampleWorkspaceSource(fixtureJson: jsonEncode(fixture));
      addTearDown(source.dispose);
      var original = await source.readDetail(azure);
      expect(original.relations['related']!.single.id, 'deleted-target');
      final saved =
          await source.saveRecord(
                WorkspaceEdit(
                  operationId: 'unrelated',
                  expectedVersion: original.version,
                  record: original.record.copyWith(description: '新说明'),
                  values: {},
                ),
              )
              as WorkspaceSaved;
      expect(saved.detail.relations['related'], original.relations['related']);
      final cleared =
          await source.saveRecord(
                WorkspaceEdit(
                  operationId: 'clear-deleted',
                  expectedVersion: saved.detail.version,
                  record: saved.detail.record,
                  values: {},
                  relations: {'related': []},
                ),
              )
              as WorkspaceSaved;
      expect(cleared.detail.relations['related'], isEmpty);
      original = await source.readDetail(
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'ideas'),
      );
      expect(original.record.type.id, 'generic');
      expect(
        (original.definition['sections'] as List).any((s) => s['key'] == '旧结构'),
        isTrue,
      );
      final edited =
          await source.saveRecord(
                WorkspaceEdit(
                  operationId: 'legacy-body',
                  expectedVersion: original.version,
                  record: original.record,
                  values: {'body': '修改正文'},
                ),
              )
              as WorkspaceSaved;
      expect(edited.detail.values['旧字段'], '仍需保留的正文');
      expect(edited.detail.values['旧结构'], {'原文': '保留原始形状'});
      expect((await source.loadTemplate('generic'))['fields'], hasLength(1));
      final complex = await source.readDetail(
        const WorkspaceRecordRef(
          WorkspaceRecordKind.information,
          'complex-legacy',
        ),
      );
      expect(
        (complex.definition['fields'] as List).any((f) => f['key'] == 'body'),
        isFalse,
      );
      final retained =
          await source.saveRecord(
                WorkspaceEdit(
                  operationId: 'complex-name',
                  expectedVersion: complex.version,
                  record: complex.record.copyWith(name: '仅改名称'),
                  values: {},
                ),
              )
              as WorkspaceSaved;
      expect(retained.detail.values['body'], {'原文': '复合正文'});
      final invalidBody =
          await source.createRecord(
                WorkspaceCreate(
                  operationId: 'complex-new',
                  typeId: 'generic',
                  name: '新的正文',
                  values: {
                    'body': {'错误形状': '不可覆盖'},
                  },
                ),
              )
              as WorkspaceRejected;
      expect(invalidBody.failure.fieldErrors['body'], isNotNull);
    },
  );

  Future<LibraryController> start(
    WidgetTester t, {
    double scale = 1,
    bool dark = false,
  }) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('relation-capture'),
        child: PreviewWorkspace(inputsBuilder: fixtureInputs),
      ),
    );
    await t.pumpAndSettle();
    if (dark) {
      await fixtureTap(t, find.byKey(const ValueKey('preview-guide')));
      await t.pumpAndSettle();
      await fixtureTap(t, find.byKey(const ValueKey('preview-theme-dark')));
      await t.pumpAndSettle();
    }
    return t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
  }

  Future<void> openEdit(WidgetTester t) async {
    await t.tap(find.text('编辑信息'));
    await t.pumpAndSettle();
  }

  Future<void> choose(WidgetTester t, String key) async {
    final target = find.byKey(ValueKey('library-relation-choose-$key'));
    await t.ensureVisible(target);
    await t.tap(target);
    await t.pumpAndSettle();
  }

  Future<void> search(WidgetTester t, String key, String text) async {
    final target = find.descendant(
      of: find.byKey(ValueKey('library-relation-search-$key')),
      matching: find.byType(TextField),
    );
    await t.ensureVisible(target);
    await t.enterText(target, text);
    await t.pumpAndSettle();
  }

  Future<void> save(WidgetTester t) async {
    final done = find.widgetWithText(DesktopButton, '完成选择');
    if (done.evaluate().isNotEmpty) {
      await t.tap(done);
      await t.pumpAndSettle();
    }
    await t.tap(find.byKey(const ValueKey('library-edit-save')));
    await t.pumpAndSettle();
  }

  testWidgets(
    'multi-selection survives search and failure, then saved detail rereads the actual links',
    (tester) async {
      final model = await start(tester);
      await openEdit(tester);
      await choose(tester, 'related');
      await search(tester, 'related', 'Vikunja');
      await capture(tester, 'relation-chooser-1280-light');
      // Toggle an existing link off; hidden choices remain selected.
      final selected = find.byKey(
        const ValueKey('library-relation-option-related-information:vikunja'),
      );
      await tester.ensureVisible(selected);
      await tester.tap(selected);
      await tester.pumpAndSettle();
      await search(tester, 'related', '家庭');
      expect(
        find.byKey(
          const ValueKey('library-relation-remove-related-information:aliyun'),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-relation-search-related')),
        findsNothing,
      );
      expect(find.text('尚有未保存的修改。可继续编辑，或放弃修改后关闭。'), findsNothing);
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('unavailable', '合成关联保存失败');
      await save(tester);
      expect(find.text('合成关联保存失败'), findsOneWidget);
      await capture(tester, 'relation-failure-1280-light');
      expect(
        (await model.source.readDetail(
          azure,
        )).relations['related']!.any((r) => r.id == 'vikunja'),
        isTrue,
      );
      await save(tester);
      final saved = await model.source.readDetail(azure);
      expect(saved.relations['related'], [aliyun, blinko]);
      expect(model.detail!.relations['related'], saved.relations['related']);
      expect(model.canGoBack, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'generic records offer body editing and creation without adopting an old instance',
    (tester) async {
      final model = await start(tester);
      await model.openRelated(
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'ideas'),
      );
      await tester.pumpAndSettle();
      await openEdit(tester);
      final body = find.descendant(
        of: find.byKey(const ValueKey('library-edit-body')),
        matching: find.byType(TextField),
      );
      await tester.ensureVisible(body);
      await tester.enterText(body, 'Mac 通用资料正文');
      await save(tester);
      expect(model.detail!.values['body'], 'Mac 通用资料正文');
      expect(find.text('Mac 通用资料正文'), findsOneWidget);
      await capture(tester, 'generic-body-1280-light');
      await tester.tap(find.text('添加资料').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-new-type-generic')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(body).controller!.text, '');
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('library-edit-name')),
          matching: find.byType(TextField),
        ),
        '新的通用资料',
      );
      await tester.enterText(body, '新的正文');
      await save(tester);
      expect(model.detail!.record.name, '新的通用资料');
      expect(model.detail!.values['body'], '新的正文');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large text keeps relation choices and fixed submit action reachable',
    (tester) async {
      final model = await start(tester, scale: 2, dark: true);
      await model.openRelated(blinko);
      await tester.pumpAndSettle();
      await openEdit(tester);
      await choose(tester, 'hostedOn');
      await search(tester, 'hostedOn', '日本');
      final option = find.byKey(
        const ValueKey('library-relation-option-hostedOn-information:azure'),
      );
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('library-edit-save'))).bottom,
        lessThan(800),
      );
      await capture(tester, 'relation-chooser-1280-dark-large-text');
      await save(tester);
      expect(model.detail!.relations['hostedOn']!.contains(azure), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'late candidate reads cannot replace the latest query or update a disposed chooser',
    (tester) async {
      final source = DeferredRelations();
      addTearDown(source.dispose);
      var selected = <WorkspaceRecordRef>[aliyun];
      await tester.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => LibraryRelationPicker(
                source: source,
                typeId: 'server',
                relationKey: 'related',
                label: '相关资料',
                record: azure,
                selected: selected,
                onChanged: (value) => update(() => selected = value),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await choose(tester, 'related');
      await search(tester, 'related', '阿里云');
      await search(tester, 'related', 'Vikunja');
      expect(source.requests.length, 3);
      source.requests[2].result.complete(
        await source.actual(source.requests[2].query),
      );
      await tester.pumpAndSettle();
      final latest = find.byKey(
        const ValueKey('library-relation-option-related-information:vikunja'),
      );
      expect(latest, findsOneWidget);
      source.requests[1].result.complete(
        await source.actual(source.requests[1].query),
      );
      source.requests[0].result.complete(
        await source.actual(source.requests[0].query),
      );
      await tester.pumpAndSettle();
      expect(latest, findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('library-relation-option-related-information:aliyun'),
        ),
        findsNothing,
      );
      await search(tester, 'related', '失败');
      expect(tester.widget<DesktopButton>(latest).onPressed, isNull);
      source.requests[3].result.completeError(
        const WorkspaceFailure('unavailable', '候选读取失败'),
      );
      await tester.pumpAndSettle();
      expect(find.text('候选读取失败'), findsOneWidget);
      expect(selected, [aliyun]);
      expect(
        find.byKey(
          const ValueKey('library-relation-remove-related-information:aliyun'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('重试查找'));
      await tester.pumpAndSettle();
      source.requests[4].result.complete(
        await source.actual(source.requests[4].query),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('没有匹配的关联资料'), findsOneWidget);
      await search(tester, 'related', '最后');
      await tester.pumpWidget(const SizedBox());
      source.requests[5].result.complete(
        await source.actual(source.requests[5].query),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'paging candidates never removes chosen objects outside the current page',
    (tester) async {
      final source = SampleWorkspaceSource();
      addTearDown(source.dispose);
      var selected = <WorkspaceRecordRef>[aliyun];
      await tester.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => LibraryRelationPicker(
                source: source,
                typeId: 'server',
                relationKey: 'related',
                label: '相关资料',
                record: azure,
                selected: selected,
                onChanged: (value) => update(() => selected = value),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await choose(tester, 'related');
      final first = await source.queryRelationCandidates(
        const WorkspaceRelationQuery(
          typeId: 'server',
          key: 'related',
          source: azure,
          limit: 15,
        ),
      );
      final candidate = first.items.firstWhere((r) => r.ref != aliyun);
      final option = find.byKey(
        ValueKey('library-relation-option-related-${candidate.ref.key}'),
      );
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('下一页'));
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(selected, [aliyun, candidate.ref]);
      expect(
        find.byKey(
          ValueKey('library-relation-remove-related-${candidate.ref.key}'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          ValueKey('library-relation-option-related-${candidate.ref.key}'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
