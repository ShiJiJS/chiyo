import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/library_history_dialog.dart';
import 'package:info_desktop/workspace/proposals_controller.dart';
import 'package:info_desktop/workspace/proposals_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
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
  ProposalsController model(WidgetTester t) =>
      t.widget<ProposalsPage>(find.byType(ProposalsPage)).controller;
  Future<void> ready(WidgetTester t) async {
    for (var i = 0; i < 200; i++) {
      await t.pump();
      if (find.byType(ProposalsPage).evaluate().isEmpty) {
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        return;
      }
      final m = model(t);
      if (!m.loading && !m.reading && !m.busy) {
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        return;
      }
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    fail('Proposal UI did not finish reading');
  }

  Future<void> tap(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.pumpAndSettle();
    await t.tap(f);
    await ready(t);
  }

  Future<void> closed(WidgetTester t) async {
    final guide = find.byKey(const ValueKey('preview-guide'));
    for (
      var i = 0;
      i < 100 && t.widget<DesktopButton>(guide).onPressed == null;
      i++
    ) {
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(t.widget<DesktopButton>(guide).onPressed, isNotNull);
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
        key: ValueKey('proposals-capture'),
        child: PreviewWorkspace(),
      ),
    );
    await t.pumpAndSettle();
    final s =
        t.widget<LibraryPage>(find.byType(LibraryPage)).controller.source
            as SampleWorkspaceSource;
    if (dark) {
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-theme-dark')));
      await closed(t);
    }
    await tap(t, find.byKey(const ValueKey('workspace-nav-proposals')));
    return s;
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    await t.runAsync(() async {
      final b = t.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('proposals-capture')),
          ),
          im = await b.toImage(pixelRatio: 1),
          bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      im.dispose();
    });
  }

  testWidgets(
    'actual import editing, item reduction and confirmation update shared library and return to the exact processed proposal',
    (t) async {
      final s = await start(t), m = model(t);
      expect(m.selection, 'import');
      await tap(t, find.byKey(const ValueKey('proposal-filter-pending')));
      await capture(t, 'proposals-1440-light-import');
      await tap(t, find.byKey(const ValueKey('proposal-item-status')));
      expect(m.draft!.selected, {'portal'});
      await tap(t, find.byKey(const ValueKey('proposal-edit-portal')));
      await t.enterText(
        find.byKey(const ValueKey('proposal-edit-name')),
        'Owner核对后的入口',
      );
      await t.enterText(
        find.byKey(const ValueKey('proposal-edit-url')),
        'https://reviewed.beichen.example',
      );
      await tap(t, find.byKey(const ValueKey('proposal-edit-keep')));
      await closed(t);
      expect(m.draft!.items['portal']!.name, 'Owner核对后的入口');
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      expect(m.selection, 'import');
      expect(m.filter, WorkspaceProposalFilter.all);
      expect(m.detail!.summary.status, WorkspaceProposalStatus.completed);
      expect(m.detail!.items, isEmpty);
      expect(m.detail!.targets, hasLength(1));
      final ref = m.detail!.targets.single.record;
      expect(
        (await s.readDetail(ref)).values['url'],
        'https://reviewed.beichen.example',
      );
      expect((await s.loadSummary()).proposals, 1);
      expect((await s.loadSummary()).records, 32);
      await capture(t, 'proposals-1440-light-imported');
      await tap(t, find.byKey(ValueKey('proposal-current-${ref.key}')));
      expect(
        t
            .widget<LibraryPage>(find.byType(LibraryPage))
            .controller
            .detail!
            .record
            .ref,
        ref,
      );
      final position = m.detailScroll;
      await tap(t, find.byKey(const ValueKey('workspace-back')));
      expect(model(t), same(m));
      expect(m.selection, 'import');
      expect(m.detailScroll, position);
    },
  );
  testWidgets(
    'actual modification editor previews its correction and preserves unrelated field identities and relations',
    (t) async {
      final s = await start(t), m = model(t);
      await tap(t, find.byKey(const ValueKey('proposal-row-update')));
      final before = await s.proposals.currentTarget('update');
      await tap(t, find.byKey(const ValueKey('proposal-edit-server-port')));
      await t.enterText(
        find.byKey(const ValueKey('proposal-edit-port')),
        '2233',
      );
      await tap(t, find.byKey(const ValueKey('proposal-edit-keep')));
      await closed(t);
      expect(m.draft!.items.values.single.values['port'], '2233');
      expect(find.text('2233'), findsOneWidget);
      await capture(t, 'proposals-1440-light-modification');
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      final current = await s.readDetail(before.record.ref);
      expect(current.values['port'], '2233');
      expect(current.fieldIds, before.fieldIds);
      expect(current.relations, before.relations);
      expect(current.values['host'], before.values['host']);
      expect(m.detail!.summary.status, WorkspaceProposalStatus.completed);
      expect(m.detail!.items, isEmpty);
    },
  );
  testWidgets(
    'guide-injected lost reply freezes navigation until matching original receipt; terminal view retains no submitted bodies',
    (t) async {
      final s = await start(t), m = model(t);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-proposal-unknown')));
      await closed(t);
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      expect(m.uncertain, true);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('workspace-nav-library')),
            )
            .onPressed,
        isNull,
      );
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('preview-guide')))
            .onPressed,
        isNull,
      );
      await capture(t, 'proposals-1440-light-unknown');
      await tap(t, find.byKey(const ValueKey('proposal-reconcile')));
      expect(m.frozen, false);
      expect(m.detail!.summary.status, WorkspaceProposalStatus.completed);
      expect(m.draft, isNull);
      expect(m.detail!.items, isEmpty);
      expect((await s.loadSummary()).records, 33);
    },
  );
  testWidgets(
    'conflict is reproduced from the actual guide, current comparison never writes, edited review is preserved and rejection leaves current values',
    (t) async {
      final s = await start(t), m = model(t);
      await tap(t, find.byKey(const ValueKey('proposal-row-update')));
      await tap(t, find.byKey(const ValueKey('proposal-edit-server-port')));
      await t.enterText(
        find.byKey(const ValueKey('proposal-edit-port')),
        '2233',
      );
      await tap(t, find.byKey(const ValueKey('proposal-edit-keep')));
      await closed(t);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-proposal-conflict')));
      await closed(t);
      await ready(t);
      expect(m.canConfirm, false);
      expect(m.draft!.items.values.single.values['port'], '2233');
      await tap(t, find.byKey(const ValueKey('proposal-compare-server-port')));
      expect(find.text('2200'), findsOneWidget);
      expect(find.text('2233'), findsWidgets);
      await capture(t, 'proposals-1440-light-conflict-comparison');
      await tap(t, find.byKey(const ValueKey('proposal-read-close')));
      await closed(t);
      await tap(t, find.byKey(const ValueKey('proposal-reject')));
      expect(
        (await s.readDetail(
          const WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun'),
        )).values['port'],
        '2200',
      );
      expect(m.detail!.summary.status, WorkspaceProposalStatus.rejected);
    },
  );
  testWidgets(
    'explicit saved-version snapshot invalidates its mounted body after purge and never substitutes current content',
    (t) async {
      final s = await start(t), m = model(t);
      await tap(t, find.byKey(const ValueKey('proposal-item-status')));
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      final ref = m.detail!.targets.single.record,
          original = await s.readDetail(m.detail!.targets.single.record);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'later',
          expectedVersion: original.version,
          record: original.record,
          values: {'url': 'https://later.example'},
        ),
      );
      await ready(t);
      await tap(t, find.byKey(ValueKey('proposal-snapshot-${ref.key}')));
      expect(
        t
            .widget<LibrarySnapshotView>(find.byType(LibrarySnapshotView))
            .archive
            .detail
            .values,
        original.values,
      );
      final current = await s.readDetail(ref),
          deleted = await s.changeRecord(
            WorkspaceRecordChange(
              operationId: 'recycle',
              ref: ref,
              expectedVersion: current.version,
              action: WorkspaceRecordAction.recycle,
            ),
          );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'purge',
          ref: ref,
          expectedVersion: deleted.version,
          entryId: deleted.entryId,
          action: WorkspaceRecordAction.purge,
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(LibrarySnapshotView), findsNothing);
      expect(find.textContaining('不会替换成当前或同名内容'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('proposal-read-close')));
      await closed(t);
      await ready(t);
      expect(m.detail!.targets.single.snapshotAvailable, false);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(ValueKey('proposal-current-${ref.key}')),
            )
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets(
    'dark200 uses real filtering, editing failure and retry without clipping or losing review',
    (t) async {
      final s = await start(t, dark: true), m = model(t);
      await tap(t, find.byKey(const ValueKey('proposal-kind')));
      await tap(t, find.text('修改信息').last);
      expect(m.selection, 'update');
      await capture(t, 'proposals-1280-dark200-modification');
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '存储空间不足，审阅仍保留');
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      expect(m.writeFailure!.code, 'disk_full');
      expect(m.draft, isNotNull);
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      expect(m.detail!.summary.status, WorkspaceProposalStatus.completed);
      await t.enterText(
        find.byKey(const ValueKey('proposal-search')),
        '没有匹配的合成提案',
      );
      await ready(t);
      expect(m.results!.total, 0);
      expect(find.text('没有匹配的提案。'), findsOneWidget);
      t.view.physicalSize = const Size(900, 800);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'field validation points to the exact proposal input and editing it clears the error without discarding review',
    (t) async {
      final s = await start(t), m = model(t);
      await tap(t, find.byKey(const ValueKey('proposal-row-update')));
      await tap(t, find.byKey(const ValueKey('proposal-edit-server-port')));
      await t.enterText(
        find.byKey(const ValueKey('proposal-edit-port')),
        '不是数字',
      );
      await tap(t, find.byKey(const ValueKey('proposal-edit-keep')));
      await closed(t);
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      expect(m.writeFailure!.code, 'validation');
      expect(
        m.writeFailure!.fieldErrors.keys,
        contains('item:server-port:port'),
      );
      await tap(t, find.byKey(const ValueKey('proposal-edit-server-port')));
      final error = t
          .widget<DesktopTextField>(
            find.byKey(const ValueKey('proposal-edit-port')),
          )
          .decoration
          .errorText;
      expect(error, isNotNull);
      await t.enterText(
        find.byKey(const ValueKey('proposal-edit-port')),
        '2233',
      );
      await t.pumpAndSettle();
      expect(
        t
            .widget<DesktopTextField>(
              find.byKey(const ValueKey('proposal-edit-port')),
            )
            .decoration
            .errorText,
        isNull,
      );
      await tap(t, find.byKey(const ValueKey('proposal-edit-keep')));
      await closed(t);
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      expect(
        (await s.readDetail(
          const WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun'),
        )).values['port'],
        '2233',
      );
    },
  );
  testWidgets(
    'actual proposal guide reaches empty, failure, waiting and recovery states',
    (t) async {
      await start(t);
      final m = model(t);
      Future<void> scenario(String name, {bool waiting = false}) async {
        await tap(t, find.byKey(const ValueKey('preview-guide')));
        await t.ensureVisible(find.text(name));
        await t.tap(find.text(name));
        if (waiting) {
          await t.pump(const Duration(milliseconds: 500));
        } else {
          await ready(t);
        }
        await closed(t);
      }

      await scenario('空资料');
      expect(m.results!.total, 0);
      await scenario('读取失败');
      expect(m.readFailure, isNotNull);
      await tap(t, find.byKey(const ValueKey('proposal-retry')));
      expect(m.readFailure, isNull);
      expect(m.results!.total, 2);
      await scenario('持续等待', waiting: true);
      expect(m.loading, true);
      await t.tap(find.byKey(const ValueKey('preview-guide')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      await t.ensureVisible(find.text('正常资料'));
      await t.tap(find.text('正常资料'));
      await ready(t);
      await closed(t);
      expect(m.loading, false);
      expect(m.results!.pending, 2);
    },
  );
  testWidgets(
    'relation picker edits a disabled-template proposal using its submitted rules and confirms after explicit reread',
    (t) async {
      final s = await start(t), m = model(t);
      final catalog = await s.plugins.load();
      await s.plugins.change(
        WorkspacePluginChange(
          operationId: 'disable-for-editor',
          action: WorkspacePluginAction.disable,
          packageId: 'builtin.service',
          expectedVersion: catalog.version,
          expectedDigest: catalog.packages
              .singleWhere((p) => p.id == 'builtin.service')
              .digest,
        ),
      );
      await ready(t);
      expect(m.needsReview, true);
      await tap(t, find.byKey(const ValueKey('proposal-item-status')));
      await tap(t, find.byKey(const ValueKey('proposal-edit-portal')));
      await tap(
        t,
        find.byKey(const ValueKey('library-relation-choose-hostedOn')),
      );
      await tap(
        t,
        find.byKey(
          const ValueKey('library-relation-option-hostedOn-information:azure'),
        ),
      );
      await tap(
        t,
        find.byKey(
          const ValueKey('library-relation-option-hostedOn-information:aliyun'),
        ),
      );
      await tap(
        t,
        find.byKey(const ValueKey('library-relation-done-hostedOn')),
      );
      await tap(t, find.byKey(const ValueKey('proposal-edit-keep')));
      await closed(t);
      expect(m.draft!.items['portal']!.relations['hostedOn'], [
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun'),
      ]);
      await tap(t, find.byKey(const ValueKey('proposal-review-current')));
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      final saved = await s.readDetail(m.detail!.targets.single.record);
      expect(saved.relations['hostedOn'], [
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun'),
      ]);
      expect(saved.templateState, WorkspaceTemplateState.disabled);
    },
  );
  testWidgets(
    'purging a pending target clears both the visible old diff and an already open current comparison',
    (t) async {
      final s = await start(t), m = model(t);
      await tap(t, find.byKey(const ValueKey('proposal-row-update')));
      final old = await s.proposals.currentTarget('update');
      await tap(t, find.byKey(const ValueKey('proposal-compare-server-port')));
      expect(find.text(old.values['port'] as String), findsWidgets);
      final deleted = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'pending-ui-recycle',
          ref: old.record.ref,
          expectedVersion: old.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'pending-ui-purge',
          ref: old.record.ref,
          expectedVersion: deleted.version,
          entryId: deleted.entryId,
          action: WorkspaceRecordAction.purge,
        ),
      );
      await t.pumpAndSettle();
      expect(find.text(old.values['port'] as String), findsNothing);
      expect(find.text('当前普通资料已不可用。'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('proposal-read-close')));
      await closed(t);
      await ready(t);
      expect(m.detail!.items.single.before!.values, isEmpty);
      expect(m.draft!.originals.values.single.before!.values, isEmpty);
      expect(m.draft!.items.values.single.values.keys, ['port']);
      expect(find.text('原版本内容已不可用。'), findsOneWidget);
      expect(m.canConfirm, false);
    },
  );
}
