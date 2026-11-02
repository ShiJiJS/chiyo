import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/library_history_dialog.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/settings_controller.dart';
import 'package:info_desktop/workspace/settings_page.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'support/workspace_fixtures.dart';

Finder key(String id) => find.byKey(ValueKey(id));

Future<void> tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pumpAndSettle();
  await t.tap(f);
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
}

void main() {
  test(
    'readable history preserves duplicate relation labels and inspectable target identities',
    () {
      const a = WorkspaceRecordRef(WorkspaceRecordKind.information, 'first');
      const b = WorkspaceRecordRef(WorkspaceRecordKind.information, 'second');
      WorkspaceRecordSummary summary(WorkspaceRecordRef ref) =>
          WorkspaceRecordSummary(
            ref: ref,
            name: '同名资料',
            description: '',
            type: const WorkspaceType('generic', '通用', 'file'),
            updatedAt: DateTime(2026),
          );
      final archive = WorkspaceArchive(
        archivedAt: DateTime(2026),
        targets: {a: summary(a), b: summary(b)},
        detail: WorkspaceDetail(
          record: summary(a),
          version: 1,
          definition: {
            'fields': [],
            'relations': [
              {'key': 'left', 'label': '相关资料'},
              {'key': 'right', 'label': '相关资料'},
            ],
          },
          values: {},
          relations: {
            'left': [a],
            'right': [b],
          },
        ),
      );
      final readable = librarySnapshot(archive),
          ids = librarySnapshot(archive, includeTargetIds: true);
      expect(readable['关联：相关资料（left）'], '同名资料');
      expect(readable['关联：相关资料（right）'], '同名资料');
      expect(ids['关联：相关资料（left）'], contains(a.key));
      expect(ids['关联：相关资料（right）'], contains(b.key));
    },
  );
  Future<void> start(WidgetTester t) async {
    t.view.physicalSize = const Size(1440, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(const PreviewWorkspace(inputsBuilder: fixtureInputs));
    await t.pumpAndSettle();
  }

  testWidgets('library tag management opens settings at tags directly', (
    t,
  ) async {
    await start(t);
    await tap(t, key('library-tags-manage'));
    final page = t.widget<WorkspaceSettingsPage>(
      find.byType(WorkspaceSettingsPage),
    );
    expect(page.controller.section, WorkspaceSettingsSection.classifications);
    expect(page.classifications.kind, WorkspaceClassificationKind.tag);
    expect(find.text('新建标签'), findsOneWidget);
  });

  for (final save in [false, true]) {
    testWidgets(
      'Cmd K works after creation closes (save=$save) and in reading view',
      (t) async {
        await start(t);
        final model = t
            .widget<LibraryPage>(find.byType(LibraryPage))
            .controller;
        await tap(t, key('library-create'));
        if (save) {
          await tap(t, key('library-new-type-generic'));
          await t.enterText(key('library-edit-name'), '合成快捷键资料');
          await t.enterText(key('library-edit-body'), '合成正文');
          await tap(t, key('library-edit-save'));
          expect(model.detail!.record.name, '合成快捷键资料');
        } else {
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
        }
        await t.pumpAndSettle();
        await t.tap(key('library-detail-title'));
        await t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.keyK);
        await t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await t.pumpAndSettle();
        final search = t.widget<EditableText>(
          find.descendant(
            of: key('library-search-frame'),
            matching: find.byType(EditableText),
          ),
        );
        expect(search.focusNode.hasFocus, isTrue);
        t.testTextInput.enterText('备份');
        await t.pumpAndSettle();
        expect(model.query.keyword, '备份');
        await model.clearFilters();
        await t.pumpAndSettle();
        await tap(t, key('library-detail-expand'));
        await t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.keyK);
        await t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await t.pumpAndSettle();
        expect(key('library-search-frame'), findsOneWidget);
        expect(
          t
              .widget<EditableText>(
                find.descendant(
                  of: key('library-search-frame'),
                  matching: find.byType(EditableText),
                ),
              )
              .focusNode
              .hasFocus,
          isTrue,
        );
      },
    );
  }

  testWidgets(
    'history shows relation names and collapses identical structure',
    (t) async {
      await start(t);
      final model = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
      final before = model.detail!;
      await model.source.saveRecord(
        WorkspaceEdit(
          operationId: workspaceOperationId(),
          expectedVersion: before.version,
          record: before.record.copyWith(description: '合成版本说明'),
          values: before.values,
          relations: before.relations,
        ),
      );
      await t.pumpAndSettle();
      final context = t.element(find.byType(LibraryPage));
      final closed = showLibraryHistory(
        context,
        model.source,
        before.record.ref,
      );
      await t.pumpAndSettle();
      await tap(t, key('library-version-${before.version}'));
      final raw = const JsonEncoder.withIndent('  ').convert(before.definition);
      expect(find.text(raw), findsNothing);
      await tap(t, key('history-structure-details'));
      expect(find.text(raw), findsOneWidget);
      await tap(t, find.text('关闭').last);
      await closed;

      final targets = await model.source.readSummaries(
        before.relations.values.expand((v) => v),
      );
      final snapshot = librarySnapshot(
        WorkspaceArchive(
          detail: before,
          archivedAt: DateTime(2026),
          targets: {for (final r in targets) r.ref: r},
        ),
      );
      for (final target in targets) {
        expect(
          snapshot.values.any(
            (v) => v.contains('${target.name}（${target.ref.key}）'),
          ),
          isFalse,
        );
      }
      expect(t.takeException(), isNull);
    },
  );
}
