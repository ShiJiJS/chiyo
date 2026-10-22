import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/information_editor.dart';
import 'package:info_desktop/ui.dart';

void main() {
  const platforms = TargetPlatformVariant({
    TargetPlatform.macOS,
    TargetPlatform.windows,
  });

  Future<InformationEditorDraft> open(
    WidgetTester tester, {
    Future<void> Function(InformationEditorDraft)? save,
  }) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final draft = InformationEditorDraft(
      name: 'Synthetic item',
      description: 'Synthetic description',
      fields: [
        EditableInformationField(
          name: 'Synthetic field',
          description: 'Synthetic field description',
          value: 'Synthetic value',
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: informationTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => InformationEditor(
                  draft: draft,
                  onSave: save ?? (_) async {},
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return draft;
  }

  Finder field(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(EditableText),
  );

  testWidgets(
    'accessible fields retain purpose, value and editing actions with save guards',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final pending = Completer<void>();
      try {
        final draft = await open(tester, save: (_) => pending.future);
        for (final entry in {
          'item-name': ('信息名称', 'Synthetic item'),
          'item-description': ('公开说明', 'Synthetic description'),
          'field-name-0': ('字段名称', 'Synthetic field'),
          'field-value-0': ('字段内容', 'Synthetic value'),
          'field-description-0': ('字段公开说明', 'Synthetic field description'),
        }.entries) {
          await tester.ensureVisible(field(entry.key));
          await tester.pumpAndSettle();
          final data = tester.getSemantics(field(entry.key)).getSemanticsData();
          expect(data.label, entry.value.$1);
          expect(data.value, entry.value.$2);
          expect(data.flagsCollection.isTextField, isTrue);
          await tester.tap(field(entry.key));
          await tester.pumpAndSettle();
          expect(
            tester
                .getSemantics(field(entry.key))
                .getSemanticsData()
                .hasAction(SemanticsAction.setText),
            isTrue,
          );
        }
        await tester.ensureVisible(field('item-name'));
        await tester.tap(field('item-name'));
        await tester.pumpAndSettle();
        final nameId = tester.getSemantics(field('item-name')).id;
        tester.semantics.performAction(
          find.semantics.byPredicate((node) => node.id == nameId),
          SemanticsAction.setText,
          args: 'Updated synthetic name',
        );
        await tester.pumpAndSettle();
        expect(draft.name, 'Updated synthetic name');
        expect(
          tester.getSemantics(field('item-name')).getSemanticsData().label,
          '信息名称',
        );
        await tester.tap(find.byKey(const ValueKey('save-information')));
        await tester.pump();
        final disabled = tester
            .getSemantics(field('item-name'))
            .getSemanticsData();
        expect(disabled.label, '信息名称');
        expect(disabled.value, 'Updated synthetic name');
        expect(disabled.flagsCollection.isEnabled.toBoolOrNull(), isFalse);
        expect(disabled.hasAction(SemanticsAction.setText), isFalse);
        expect(draft.fields.single.value, 'Synthetic value');
        pending.complete();
        await tester.pumpAndSettle();
        expect(find.byType(InformationEditor), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete();
        await tester.pumpWidget(const SizedBox());
        semantics.dispose();
      }
    },
    variant: platforms,
  );

  testWidgets(
    'empty tags and directory selectors announce purpose and remain operable',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final draft = await open(tester);
        final directory = tester
            .getSemantics(find.byKey(const ValueKey('item-directory')))
            .getSemanticsData();
        expect(directory.label, contains('所在目录'));
        expect(directory.label, contains('未分类'));
        expect(directory.flagsCollection.isButton, isTrue);
        expect(directory.hasAction(SemanticsAction.tap), isTrue);
        await tester.ensureVisible(find.byKey(const ValueKey('field-kind-0')));
        await tester.pumpAndSettle();
        final kind = tester
            .getSemantics(find.byKey(const ValueKey('field-kind-0')))
            .getSemanticsData();
        expect(kind.label, contains('字段类型'));
        expect(kind.label, contains('结构化字段'));
        expect(kind.flagsCollection.isButton, isTrue);
        await tester.ensureVisible(find.byKey(const ValueKey('item-tags')));
        await tester.pumpAndSettle();
        final tags = tester.getSemantics(
          find.byKey(const ValueKey('item-tags')),
        );
        expect(tags.getSemanticsData().label, '标签');
        expect(tags.getSemanticsData().flagsCollection.isButton, isTrue);
        tester.semantics.performAction(
          find.semantics.byPredicate((node) => node.id == tags.id),
          SemanticsAction.tap,
        );
        await tester.pumpAndSettle();
        expect(find.text('选择标签'), findsOneWidget);
        await tester.tap(find.text('×').hitTestable().last);
        await tester.pumpAndSettle();
        expect(find.text('选择标签'), findsNothing);
        expect(draft.tagIds, isEmpty);
        expect(draft.name, 'Synthetic item');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        semantics.dispose();
      }
    },
    variant: platforms,
  );
}
