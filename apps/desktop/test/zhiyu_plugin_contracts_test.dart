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
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_edit_conflict.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_fixture.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'workspace_adoption_test.dart' show installDomain;

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
  Future<void> tap(WidgetTester t, Finder f) async {
    if (await prepareFixtureAction(t, f)) return;
    await t.ensureVisible(f);
    await t.pumpAndSettle();
    await t.tap(f);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> enter(WidgetTester t, String key, String text) async {
    final f = find.byKey(ValueKey(key));
    await t.ensureVisible(f);
    await t.enterText(f, text);
    await t.pumpAndSettle();
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    final b = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('contract-capture')),
    );
    await t.runAsync(() async {
      final im = await b.toImage(pixelRatio: 1),
          bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      im.dispose();
    });
  }

  Future<({LibraryController library, SampleWorkspaceSource source})> start(
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
        key: ValueKey('contract-capture'),
        child: PreviewWorkspace(inputsBuilder: fixtureInputs),
      ),
    );
    await t.pumpAndSettle();
    if (dark) {
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-theme-dark')));
    }
    final library = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
    return (library: library, source: library.source as SampleWorkspaceSource);
  }

  Future<void> installUpdate(SampleWorkspaceSource s) async {
    final choices = await s.pluginChoices(),
        c = choices.singleWhere((c) => c.filename == '域名管理-1.1.0.json'),
        p = await s.plugins.previewInstall(c.selectionId);
    await s.plugins.change(
      WorkspacePluginChange(
        operationId: workspaceOperationId(),
        action: WorkspacePluginAction.install,
        packageId: p.package.id,
        expectedVersion: p.catalogVersion,
        selectionId: c.selectionId,
        expectedDigest: p.package.digest,
      ),
    );
    for (final c in choices) {
      await s.plugins.releaseCandidate(c.selectionId);
    }
  }

  void saveDisabled(WidgetTester t) => expect(
    t
        .widget<DesktopButton>(find.byKey(const ValueKey('library-edit-save')))
        .onPressed,
    isNull,
  );

  test(
    'conflict comparison distinguishes two different related records with the same display name',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final original = await s.readDetail(azure),
          catalog = await s.loadCatalog();
      const other = WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        'aliyun',
      );
      final second = await s.readDetail(other),
          targets = {
            azure: original.record.copyWith(name: '同名资料'),
            other: second.record.copyWith(name: '同名资料'),
          };
      String preview(WorkspaceRecordRef ref) => libraryEditorReviewValues(
        record: original.record,
        definition: original.definition,
        values: original.values,
        relations: {
          'related': [ref],
        },
        catalog: catalog,
        targets: targets,
      ).singleWhere((e) => e.id == 'relation:related').value;
      expect(preview(azure), isNot(preview(other)));
      expect(preview(azure), contains(azure.key));
      expect(preview(other), contains(other.key));
    },
  );

  testWidgets(
    'ordinary conflict review preserves the exact draft, tolerates failed reads, and rechecks a newer version before writing',
    (t) async {
      final m = await start(t), original = await m.source.readDetail(azure);
      await tap(t, find.text('编辑信息'));
      await enter(t, 'library-edit-name', '尚未提交的草稿名称');
      await m.source.saveRecord(
        WorkspaceEdit(
          operationId: 'other-edit',
          expectedVersion: original.version,
          record: original.record.copyWith(name: '另一窗口的当前名称'),
          values: {'host': 'changed.example'},
        ),
      );
      await t.pumpAndSettle();
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      saveDisabled(t);
      m.source.setScenario(SampleWorkspaceScenario.failure);
      await tap(t, find.byKey(const ValueKey('library-edit-review-current')));
      expect(
        t
            .widget<DesktopTextField>(
              find.byKey(const ValueKey('library-edit-name')),
            )
            .controller!
            .text,
        '尚未提交的草稿名称',
      );
      saveDisabled(t);
      m.source.setScenario(SampleWorkspaceScenario.ready);
      await tap(t, find.byKey(const ValueKey('library-edit-review-current')));
      expect(find.text('另一窗口的当前名称'), findsWidgets);
      expect(find.text('尚未提交的草稿名称'), findsWidgets);
      await capture(t, 'contracts-1440-light-edit-review');
      await tap(t, find.byKey(const ValueKey('library-edit-review-back')));
      saveDisabled(t);
      expect((await m.source.readDetail(azure)).version, 2);
      await tap(t, find.byKey(const ValueKey('library-edit-review-current')));
      final v2 = await m.source.readDetail(azure);
      await m.source.saveRecord(
        WorkspaceEdit(
          operationId: 'edit-during-review',
          expectedVersion: v2.version,
          record: v2.record.copyWith(description: '核对期间又发生的修改'),
          values: const {},
        ),
      );
      await tap(t, find.byKey(const ValueKey('library-edit-review-keep')));
      expect((await m.source.readDetail(azure)).version, 3);
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      saveDisabled(t);
      await tap(t, find.byKey(const ValueKey('library-edit-review-current')));
      await tap(t, find.byKey(const ValueKey('library-edit-review-keep')));
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(find.byType(DesktopDialog), findsNothing);
      expect(m.library.detail!.version, 4);
      expect(m.library.detail!.record.name, '尚未提交的草稿名称');
      expect(m.library.detail!.values['host'], original.values['host']);
      expect(m.library.detail!.fieldIds, original.fieldIds);
    },
  );

  testWidgets(
    'dark200 updated creation schema requires an explicit draft reset and then uses the reviewed current template',
    (t) async {
      final m = await start(t, dark: true);
      await installDomain(m.source);
      await t.pumpAndSettle();
      await tap(t, find.byTooltip('添加资料'));
      await tap(
        t,
        find.byKey(const ValueKey('library-new-type-local.domain/domain')),
      );
      await enter(t, 'library-edit-name', '旧定义草稿');
      await enter(t, 'library-edit-domain', 'draft.example');
      await installUpdate(m.source);
      await t.pumpAndSettle();
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      saveDisabled(t);
      await tap(t, find.byKey(const ValueKey('library-edit-review-current')));
      expect(
        find.byKey(const ValueKey('library-edit-review-keep')),
        findsNothing,
      );
      expect(find.textContaining('这会清空本次草稿'), findsOneWidget);
      await capture(t, 'contracts-1280-dark-200-schema-review');
      await tap(t, find.byKey(const ValueKey('library-edit-review-back')));
      expect(
        t
            .widget<DesktopTextField>(
              find.byKey(const ValueKey('library-edit-name')),
            )
            .controller!
            .text,
        '旧定义草稿',
      );
      await tap(t, find.byKey(const ValueKey('library-edit-review-current')));
      await tap(t, find.byKey(const ValueKey('library-edit-review-reload')));
      expect(
        t
            .widget<DesktopTextField>(
              find.byKey(const ValueKey('library-edit-name')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(
        find.byKey(const ValueKey('library-edit-maintainer')),
        findsOneWidget,
      );
      await enter(t, 'library-edit-name', '新版定义录入');
      await enter(t, 'library-edit-domain', 'current.example');
      await enter(t, 'library-edit-maintainer', '合成维护人');
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(m.library.detail!.definition['templateVersion'], '1.1.0');
      expect(m.library.detail!.values['domain'], 'current.example');
      expect((await m.source.loadSummary()).records, 32);
    },
  );

  testWidgets(
    'legacy definition identity changes do not carry old text into a new meaning, and reloading never creates records',
    (t) async {
      final m = await start(t);
      await tap(t, find.byKey(const ValueKey('workspace-nav-settings')));
      await tap(t, find.byKey(const ValueKey('legacy-menu')));
      await tap(t, find.byKey(const ValueKey('legacy-create')));
      await enter(t, 'library-edit-name', '保留的旧版草稿');
      m.source.reviseLegacyTemplate('legacy-resource');
      await t.pumpAndSettle();
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      await tap(t, find.byKey(const ValueKey('library-edit-review-current')));
      expect(
        find.byKey(const ValueKey('library-edit-review-keep')),
        findsNothing,
      );
      await tap(t, find.byKey(const ValueKey('library-edit-review-reload')));
      expect((await m.source.loadSummary()).records, 31);
      await enter(t, 'library-edit-name', '重新核对的旧版录入');
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(m.library.detail!.definition['legacyTemplateVersion'], 2);
      expect(m.library.detail!.values.values, everyElement(''));
      expect((await m.source.loadSummary()).records, 32);
    },
  );

  testWidgets(
    'removed profile entry identities cannot be revived by retaining an old editor draft',
    (t) async {
      final m = await start(t);
      const profile = WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        'profile',
      );
      await m.library.openRelated(profile);
      await t.pumpAndSettle();
      final original = await m.source.readDetail(profile);
      expect(original.values['education'] as List, isNotEmpty);
      await tap(t, find.text('编辑信息'));
      await enter(t, 'library-edit-name', '旧经历草稿');
      await m.source.saveRecord(
        WorkspaceEdit(
          operationId: 'remove-entry-elsewhere',
          expectedVersion: original.version,
          record: original.record,
          values: const {'education': <Object?>[]},
        ),
      );
      await t.pumpAndSettle();
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      await tap(t, find.byKey(const ValueKey('library-edit-review-current')));
      expect(
        find.byKey(const ValueKey('library-edit-review-keep')),
        findsNothing,
      );
      await capture(t, 'contracts-1440-light-entry-identity-review');
      await tap(t, find.byKey(const ValueKey('library-edit-review-reload')));
      expect((await m.source.readDetail(profile)).version, 2);
      expect((await m.source.readDetail(profile)).values['education'], isEmpty);
      expect(find.text('旧经历草稿'), findsNothing);
      expect(find.byType(DesktopDialog), findsOneWidget);
    },
  );

  testWidgets(
    'adopted overview keeps original relation meaning for a colliding key and shows retained links outside the target layout',
    (t) async {
      final m = await start(t),
          data = jsonDecode(sampleWorkspaceJson) as Map<String, dynamic>,
          row =
              (data['records'] as List).singleWhere((r) => r['id'] == 'azure')
                  as Map<String, dynamic>;
      (row['definition']['relations'] as List).add({
        'key': 'pointsTo',
        'label': '原维护文档',
        'targetTemplates': ['document'],
      });
      row['relations']['pointsTo'] = ['sshguide'];
      (row['definition']['relations'] as List).add({
        'key': 'extraDocs',
        'label': '原补充文档',
        'targetTemplates': ['document'],
      });
      row['relations']['extraDocs'] = ['https'];
      await m.source.replaceFixture(jsonEncode(data));
      await m.library.load(const WorkspaceQuery(), keepSelection: azure);
      await installDomain(m.source);
      final p = await m.source.previewAdoption(
        WorkspaceAdoptionDraft(
          ref: azure,
          typeId: 'local.domain/domain',
          fields: const {
            'domain': WorkspaceFieldMapping(value: 'retained.example'),
          },
        ),
      );
      expect(p.canApply, true, reason: p.errors.toString());
      await m.source.applyAdoption('adopt-retained-links', p.planId);
      await t.pumpAndSettle();
      await m.library.openRelated(azure);
      await t.pumpAndSettle();
      expect(find.text('指向的服务器'), findsNothing);
      expect(find.text('原维护文档'), findsOneWidget);
      expect(find.text('原补充文档'), findsOneWidget);
      await t.ensureVisible(find.text('原补充文档'));
      await t.pumpAndSettle();
      await capture(t, 'contracts-1440-light-retained-relations');
      await tap(t, find.text('编辑信息'));
      expect(
        find.byKey(const ValueKey('library-relation-picker-pointsTo')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('library-relation-picker-extraDocs')),
        findsOneWidget,
      );
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(m.library.detail!.relations['pointsTo'], [
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'sshguide'),
      ]);
      expect(m.library.detail!.relations['extraDocs'], [
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'https'),
      ]);
    },
  );
}
