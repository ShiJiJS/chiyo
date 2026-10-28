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
import 'package:info_desktop/workspace/workspace_entries.dart';
import 'package:info_desktop/workspace/library_entries.dart';
import 'package:info_desktop/workspace/proposal_batch.dart';
import 'package:info_desktop/workspace/grant_history_page.dart';

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
      if (!m.loading && !m.reading && !m.busy && !m.batch.busy) {
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

  Future<void> pickProposal(WidgetTester t, String id) async {
    final list = find
        .descendant(
          of: find.byKey(const ValueKey('proposal-list')),
          matching: find.byType(Scrollable),
        )
        .first;
    await t.drag(list, const Offset(0, 1600));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.byKey(ValueKey('proposal-row-$id')),
      250,
      scrollable: list,
      maxScrolls: 25,
    );
    await tap(t, find.byKey(ValueKey('proposal-row-$id')));
    expect(model(t).selection, id);
  }

  Future<void> openBatch(WidgetTester t) async {
    final target = find.byKey(const ValueKey('proposal-batch-open'));
    if (target.evaluate().isEmpty) {
      await t.scrollUntilVisible(
        target,
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('proposal-list')),
              matching: find.byType(Scrollable),
            )
            .first,
        maxScrolls: 25,
      );
    }
    await tap(t, target);
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
  testWidgets(
    'actual deletion guide reviews the full retained scope, moves the same object to recycle and opens only its exact pre-delete snapshot',
    (t) async {
      final s = await start(t);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-proposal-deletion')));
      await closed(t);
      await tap(t, find.byKey(const ValueKey('proposal-row-delete-service')));
      final m = model(t), ref = m.detail!.items.single.before!.record.ref;
      expect(find.text('删除整条资料'), findsOneWidget);
      expect(find.byKey(const ValueKey('proposal-edit-service')), findsNothing);
      expect(m.canConfirm, true);
      await capture(t, 'proposals-1440-light-deletion');
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      expect(m.detail!.summary.status, WorkspaceProposalStatus.completed);
      expect(m.detail!.items, isEmpty);
      expect(find.text('已移入回收站'), findsWidgets);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(ValueKey('proposal-current-${ref.key}')),
            )
            .onPressed,
        isNull,
      );
      await tap(t, find.byKey(ValueKey('proposal-snapshot-${ref.key}')));
      expect(find.byType(LibrarySnapshotView), findsOneWidget);
      expect(
        t
            .widget<LibrarySnapshotView>(find.byType(LibrarySnapshotView))
            .archive
            .detail
            .version,
        1,
      );
      await capture(t, 'proposals-1440-light-deleted-snapshot');
      await tap(t, find.byKey(const ValueKey('proposal-read-close')));
      await closed(t);
      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      await tap(t, find.byKey(const ValueKey('library-open-recycle')));
      expect(find.text('Blinko 笔记'), findsWidgets);
      final terminal = await s.proposals.read('delete-service');
      expect(terminal.targets.single.record, ref);
      expect(terminal.targets.single.snapshotAvailable, true);
    },
  );
  testWidgets(
    'whole deletion conflict compares the new version without changing the requested target or deleting it',
    (t) async {
      final s = await start(t);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-proposal-deletion')));
      await closed(t);
      await tap(t, find.byKey(const ValueKey('proposal-row-delete-service')));
      final m = model(t), d = m.detail!.items.single.before!;
      await t.runAsync(
        () => s.saveRecord(
          WorkspaceEdit(
            operationId: 'delete-concurrent-ui',
            expectedVersion: d.version,
            record: d.record,
            values: {'purpose': '删除前需要保留的新说明'},
          ),
        ),
      );
      await ready(t);
      expect(m.canConfirm, false);
      await tap(t, find.byKey(const ValueKey('proposal-compare-service')));
      expect(find.text('删除前需要保留的新说明'), findsWidgets);
      expect(find.textContaining('当前资料v2'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('proposal-read-close')));
      await closed(t);
      await tap(t, find.byKey(const ValueKey('proposal-reject')));
      expect(m.detail!.summary.status, WorkspaceProposalStatus.rejected);
      expect(
        (await s.readDetail(d.record.ref)).values['purpose'],
        '删除前需要保留的新说明',
      );
    },
  );
  testWidgets(
    'field intent guide reviews explicit new meaning and edits only listed values, then reads replacement and added fields in the shared library',
    (t) async {
      final s = await start(t);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-proposal-fields')));
      await closed(t);
      await tap(t, find.byKey(const ValueKey('proposal-row-fields-server')));
      final m = model(t),
          before = await s.proposals.currentTarget('fields-server');
      expect(find.textContaining('新字段定义：运维联系标识'), findsOneWidget);
      expect(find.textContaining('旧授权不包含新字段'), findsOneWidget);
      await t.ensureVisible(find.textContaining('新字段定义：恢复联系人'));
      await capture(t, 'proposals-1440-light-field-intents');
      await tap(t, find.byKey(const ValueKey('proposal-edit-fields-server')));
      await t.enterText(
        find.byKey(const ValueKey('proposal-edit-port')),
        '2233',
      );
      await t.enterText(
        find.byKey(const ValueKey('proposal-edit-recoveryContact')),
        'owner@beichen.example',
      );
      expect(find.byKey(const ValueKey('proposal-edit-purpose')), findsNothing);
      await tap(t, find.byKey(const ValueKey('proposal-edit-keep')));
      await closed(t);
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      final ref = m.detail!.targets.single.record;
      await tap(t, find.byKey(ValueKey('proposal-current-${ref.key}')));
      expect(find.text('运维联系标识'), findsOneWidget);
      expect(find.text('恢复联系人'), findsOneWidget);
      expect(find.text('owner@beichen.example'), findsOneWidget);
      final current = await s.readDetail(ref);
      expect(current.fieldIds['port'], before.fieldIds['port']);
      expect(current.fieldIds['user'], isNot(before.fieldIds['user']));
      expect(current.values['port'], '2233');
      expect(current.values.containsKey('purpose'), false);
    },
  );
  testWidgets(
    'entry review edits a single leaf and renders independent new and retained identities in the same profile timeline',
    (t) async {
      final s = await start(t, dark: true);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-proposal-fields')));
      await closed(t);
      final list = find
          .descendant(
            of: find.byKey(const ValueKey('proposal-list')),
            matching: find.byType(Scrollable),
          )
          .first;
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('proposal-row-fields-profile')),
        260,
        scrollable: list,
        maxScrolls: 20,
      );
      await tap(t, find.byKey(const ValueKey('proposal-row-fields-profile')));
      expect(find.text('教育经历'), findsOneWidget);
      final m = model(t),
          before = await s.proposals.currentTarget('fields-profile'),
          change = m.detail!.items.single.changes.first;
      await tap(t, find.byKey(const ValueKey('proposal-edit-fields-profile')));
      await t.enterText(
        find.byKey(ValueKey('proposal-edit-${change.reviewKey}')),
        'Owner核对后的教育名称',
      );
      await tap(t, find.byKey(const ValueKey('proposal-edit-keep')));
      await closed(t);
      await t.ensureVisible(find.textContaining('第一段教育 · 名称修正'));
      await t.pumpAndSettle();
      await capture(t, 'proposals-1280-dark200-entry-leaves');
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      final ref = m.detail!.targets.single.record;
      await tap(t, find.byKey(ValueKey('proposal-current-${ref.key}')));
      expect(find.byType(LibraryEntryTimeline), findsWidgets);
      expect(find.text('Owner核对后的教育名称'), findsOneWidget);
      expect(find.text('研究成果'), findsOneWidget);
      expect(find.text('北辰学院 · 继续教育'), findsOneWidget);
      final old = WorkspaceRepeatedEntry.read(before.values['education']).first,
          current = WorkspaceRepeatedEntry.read(
            (await s.readDetail(ref)).values['education'],
          ).first;
      expect(current.fieldIds['title'], old.fieldIds['title']);
      expect(current.fieldIds.containsKey('period'), false);
      expect(current.fieldIds['detail'], isNot(old.fieldIds['detail']));
    },
  );
  testWidgets(
    'a field-only delete is distinct from whole deletion and restores through the existing recycle UI without restoring the former identity',
    (t) async {
      final s = await start(t);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-proposal-fields')));
      await closed(t);
      await tap(t, find.byKey(const ValueKey('proposal-row-delete-field')));
      final m = model(t),
          before = await s.proposals.currentTarget('delete-field');
      expect(find.text('删除整条资料'), findsNothing);
      expect(find.text('移除该字段；旧内容进入回收站。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('proposal-edit-delete-field')),
        findsNothing,
      );
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      expect(find.text('字段已回收'), findsWidgets);
      expect(m.detail!.targets.single.exists, true);
      final entries = await s.queryRecycled(),
          entry = entries.items.singleWhere(
            (e) => e.record.ref == before.record.ref,
          );
      expect(entry.wholeItem, false);
      await tap(t, find.byKey(const ValueKey('workspace-nav-library')));
      await tap(t, find.byKey(const ValueKey('library-open-recycle')));
      await tap(t, find.byKey(ValueKey('library-recycle-view-${entry.id}')));
      expect(find.textContaining('这里只恢复回收字段'), findsOneWidget);
      expect(find.text('恢复字段'), findsOneWidget);
      expect(find.text('资料结构'), findsNothing);
      await capture(t, 'proposals-1440-light-partial-restore');
      await tap(t, find.byKey(const ValueKey('library-recycle-submit')));
      expect(find.text('恢复字段'), findsNothing);
      final restored = await s.readDetail(before.record.ref);
      expect(restored.values['auth'], before.values['auth']);
      expect(restored.fieldIds['auth'], isNot(before.fieldIds['auth']));
      expect(restored.values['url'], before.values['url']);
    },
  );
  testWidgets(
    'actual mixed batch confirms addition, modification and whole deletion independently',
    (t) async {
      final s = await start(t),
          m = model(t),
          before = (await s.loadSummary()).records;
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-proposal-deletion')));
      await closed(t);
      for (final id in ['import', 'update', 'delete-service']) {
        await pickProposal(t, id);
        if (m.needsReview) {
          await tap(t, find.byKey(const ValueKey('proposal-review-current')));
        }
        expect(
          m.canConfirm,
          true,
          reason:
              '$id / ${m.needsReview} / ${m.detail?.summary.status} / ${m.readFailure?.message}',
        );
        await tap(t, find.byKey(const ValueKey('proposal-batch-add-confirm')));
        expect(m.batch.entry(id), isNotNull, reason: id);
      }
      expect(m.batch.entries, hasLength(3));
      await openBatch(t);
      await tap(t, find.byKey(const ValueKey('proposal-batch-run')));
      expect(
        m.batch.entries.every((e) => e.status == ProposalBatchStatus.completed),
        true,
      );
      expect(m.batch.entries.every((e) => e.command == null), true);
      expect((await s.loadSummary()).records, before + 1);
      await capture(t, 'proposals-1440-light-mixed-results');
      await tap(t, find.byKey(const ValueKey('proposal-batch-close')));
      await closed(t);
    },
  );
  testWidgets(
    'actual middle-unknown batch stops the tail, blocks Escape and close, then explicitly continues and returns from results to its query',
    (t) async {
      final s = await start(t), m = model(t);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(
        t,
        find.byKey(const ValueKey('preview-proposal-batch-unknown')),
      );
      await closed(t);
      for (final id in ['import', 'fields-server', 'delete-field']) {
        await pickProposal(t, id);
        if (m.needsReview) {
          await tap(t, find.byKey(const ValueKey('proposal-review-current')));
        }
        expect(
          m.canConfirm,
          true,
          reason:
              '$id / ${m.needsReview} / ${m.detail?.summary.status} / ${m.readFailure?.message}',
        );
        await tap(t, find.byKey(const ValueKey('proposal-batch-add-confirm')));
        expect(m.batch.entry(id), isNotNull, reason: id);
      }
      await t.enterText(
        find.byKey(const ValueKey('proposal-search')),
        'Blinko',
      );
      await ready(t);
      await openBatch(t);
      await tap(t, find.byKey(const ValueKey('proposal-batch-run')));
      expect(m.batch.entries.map((e) => e.status).toList(), [
        ProposalBatchStatus.completed,
        ProposalBatchStatus.unknown,
        ProposalBatchStatus.notStarted,
      ]);
      expect(m.frozen, true);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('proposal-batch-close')),
            )
            .onPressed,
        isNull,
      );
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('desktop-dialog-close')),
            )
            .onPressed,
        isNull,
      );
      await tap(t, find.byKey(const ValueKey('desktop-dialog-close')));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('proposal-batch-dialog')),
        findsOneWidget,
      );
      await t.ensureVisible(
        find.byKey(const ValueKey('proposal-batch-state-fields-server')),
      );
      await capture(t, 'proposals-1440-light-mixed-unknown');
      await tap(t, find.byKey(const ValueKey('proposal-batch-reconcile')));
      expect(m.batch.pendingCount, 1);
      expect((await s.proposals.read('delete-field')).summary.pending, true);
      await tap(t, find.byKey(const ValueKey('proposal-batch-run')));
      expect(
        m.batch.entries.every((e) => e.status == ProposalBatchStatus.completed),
        true,
      );
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('proposal-batch-open-import')),
        -200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('proposal-batch-list')),
              matching: find.byType(Scrollable),
            )
            .first,
        maxScrolls: 20,
      );
      await tap(t, find.byKey(const ValueKey('proposal-batch-open-import')));
      await closed(t);
      await ready(t);
      expect(m.selection, 'import');
      expect(m.keyword, '');
      expect(m.detail!.items, isEmpty);
      await openBatch(t);
      expect(m.keyword, 'Blinko');
      expect(m.selection, 'delete-field');
      await tap(t, find.byKey(const ValueKey('proposal-batch-close')));
      await closed(t);
    },
  );
  testWidgets(
    'dark200 batch keeps definite failure and rejection separate and explicitly retries only the failed proposal',
    (t) async {
      final s = await start(t, dark: true), m = model(t);
      if (m.needsReview) {
        await tap(t, find.byKey(const ValueKey('proposal-review-current')));
      }
      await tap(t, find.byKey(const ValueKey('proposal-batch-add-confirm')));
      await t.enterText(find.byKey(const ValueKey('proposal-search')), '服务器');
      await ready(t);
      await pickProposal(t, 'update');
      expect(m.canReject, true);
      await tap(t, find.byKey(const ValueKey('proposal-batch-add-reject')));
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.text('下次保存失败'));
      await tap(t, find.text('完成'));
      await closed(t);
      await openBatch(t);
      await tap(t, find.byKey(const ValueKey('proposal-batch-run')));
      expect(m.batch.entry('import')!.status, ProposalBatchStatus.failed);
      expect(m.batch.entry('update')!.status, ProposalBatchStatus.rejected);
      expect(m.batch.entry('import')!.command!.reviewed, hasLength(2));
      await t.ensureVisible(
        find.byKey(const ValueKey('proposal-batch-retry-import')),
      );
      await t.pumpAndSettle();
      await capture(t, 'proposals-1280-dark200-mixed-failure');
      await tap(t, find.byKey(const ValueKey('proposal-batch-retry-import')));
      expect(m.batch.entry('import')!.status, ProposalBatchStatus.completed);
      expect(m.batch.entry('update')!.status, ProposalBatchStatus.rejected);
      expect((await s.loadSummary()).records, 33);
      await tap(t, find.byKey(const ValueKey('proposal-batch-close')));
      await closed(t);
    },
  );
  testWidgets(
    'automatic organization result is read only and links the same original grant and operation, returning to its query',
    (t) async {
      await start(t);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-organization-applied')));
      await closed(t);
      await ready(t);
      await t.enterText(find.byKey(const ValueKey('proposal-search')), '整理');
      await ready(t);
      await pickProposal(t, 'organized');
      final m = model(t);
      expect(
        m.detail!.organization!.outcome,
        WorkspaceOrganizationOutcome.applied,
      );
      expect(find.byKey(const ValueKey('proposal-confirm')), findsNothing);
      expect(find.byKey(const ValueKey('proposal-reject')), findsNothing);
      expect(
        find.byKey(const ValueKey('proposal-batch-add-confirm')),
        findsNothing,
      );
      expect(find.textContaining('无需再次确认'), findsOneWidget);
      await capture(t, 'proposals-1440-light-organization-result');
      await t.ensureVisible(
        find.byKey(const ValueKey('organization-current-information:blinko')),
      );
      await t.pumpAndSettle();
      final oldScroll = m.detailScroll;
      await tap(
        t,
        find.byKey(const ValueKey('organization-current-information:blinko')),
      );
      expect(find.byType(LibraryPage), findsOneWidget);
      expect(
        t
            .widget<LibraryPage>(find.byType(LibraryPage))
            .controller
            .detail!
            .record
            .ref,
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'blinko'),
      );
      await tap(t, find.byKey(const ValueKey('workspace-back')));
      expect(model(t).keyword, '整理');
      expect(model(t).selection, 'organized');
      expect(model(t).detailScroll, oldScroll);
      await tap(t, find.byKey(const ValueKey('organization-history')));
      final history = t
          .widget<GrantHistoryPage>(find.byType(GrantHistoryPage))
          .controller;
      for (var i = 0; i < 100 && (history.loading || history.reading); i++) {
        await t.pump();
      }
      await t.pumpAndSettle();
      expect(history.selection, 'request:organize');
      expect(history.detail!.events.single.proposalId, 'organized');
      expect(history.detail!.summary.state, WorkspaceGrantState.completed);
      await tap(t, find.byKey(const ValueKey('workspace-back')));
      expect(model(t).keyword, '整理');
      expect(model(t).selection, 'organized');
      await tap(t, find.byKey(const ValueKey('organization-history')));
      await t.pumpAndSettle();
      final link = find.byKey(const ValueKey('grant-organization-organized'));
      await tap(t, link);
      expect(model(t).selection, 'organized');
    },
  );

  testWidgets(
    'legacy organization stays pending until explicit confirmation and recovers its original unknown receipt in dark200',
    (t) async {
      final s = await start(t, dark: true);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-organization-legacy')));
      await closed(t);
      await ready(t);
      await pickProposal(t, 'legacy-organize');
      expect(model(t).canConfirm, true);
      expect(model(t).canEdit, false);
      expect(find.textContaining('旧版方案保留主人确认'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('proposal-edit-information:blinko')),
        findsNothing,
      );
      await capture(t, 'proposals-1280-dark200-legacy-organization');
      s.loseNextProposalReply = true;
      await tap(t, find.byKey(const ValueKey('proposal-confirm')));
      expect(model(t).uncertain, true);
      await tap(t, find.byKey(const ValueKey('proposal-reconcile')));
      expect(model(t).uncertain, false);
      expect(model(t).draft, isNull);
      expect(
        model(t).detail!.organization!.outcome,
        WorkspaceOrganizationOutcome.applied,
      );
      expect(find.byKey(const ValueKey('proposal-confirm')), findsNothing);
      final target = model(t).detail!.targets.first;
      await tap(
        t,
        find.byKey(ValueKey('proposal-snapshot-${target.record.key}')),
      );
      expect(
        t
            .widget<LibrarySnapshotView>(find.byType(LibrarySnapshotView))
            .archive
            .detail
            .version,
        target.version,
      );
      await tap(t, find.byKey(const ValueKey('proposal-read-close')));
      await closed(t);
    },
  );

  testWidgets(
    'automatic organization unknown reload is read only and a later original observation enables no second approval',
    (t) async {
      final s = await start(t);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-organization-unknown')));
      await closed(t);
      await ready(t);
      await pickProposal(t, 'organized');
      final d = await s.readDetail(
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'blinko'),
      );
      expect(
        model(t).detail!.organization!.outcome,
        WorkspaceOrganizationOutcome.unknown,
      );
      await tap(t, find.byKey(const ValueKey('organization-refresh')));
      expect(
        model(t).detail!.organization!.outcome,
        WorkspaceOrganizationOutcome.unknown,
      );
      expect(find.byKey(const ValueKey('proposal-confirm')), findsNothing);
      await capture(t, 'proposals-1440-light-organization-unknown');
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-organization-observe')));
      await closed(t);
      await ready(t);
      expect(
        model(t).detail!.organization!.outcome,
        WorkspaceOrganizationOutcome.applied,
      );
      expect((await s.readDetail(d.record.ref)).version, d.version);
      expect(find.byKey(const ValueKey('proposal-confirm')), findsNothing);
    },
  );

  testWidgets(
    'organization conflict result preserves metadata, has no second approval and handles a deleted target',
    (t) async {
      final s = await start(t);
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(
        t,
        find.byKey(const ValueKey('preview-organization-conflicted')),
      );
      await closed(t);
      await ready(t);
      await pickProposal(t, 'organized');
      expect(
        model(t).detail!.organization!.outcome,
        WorkspaceOrganizationOutcome.conflicted,
      );
      expect(find.byKey(const ValueKey('proposal-confirm')), findsNothing);
      final ref = const WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            'blinko',
          ),
          d = await s.readDetail(ref);
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'org-widget-recycle',
          ref: ref,
          expectedVersion: d.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      await ready(t);
      expect(model(t).detail!.organization!.members.first.exists, false);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(ValueKey('organization-current-${ref.key}')),
            )
            .onPressed,
        isNull,
      );
      expect(find.textContaining('保留原身份与分类记录'), findsOneWidget);
      await capture(t, 'proposals-1440-light-organization-conflict');
    },
  );
}
