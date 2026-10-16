import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/library.dart';
import 'package:info_desktop/revisions.dart';

void main() {
  testWidgets(
    'history blocks deleted fields until explicit recycle restore and rejects changed current version',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      addTearDown(() async {
        final closing = service.close();
        await tester.pump();
        await closing;
      });
      final entry = await service.owner.deleteInformation(
        'demo-server',
        1,
        fieldId: 'host',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RevisionHistoryPage(
            owner: service.owner,
            itemId: 'demo-server',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看差异'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请先在回收站明确恢复'), findsOneWidget);
      final blocked = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '确认恢复为新版本'),
      );
      expect(blocked.onPressed, isNull);
      await tester.tap(find.text('打开回收站'));
      await tester.pumpAndSettle();
      expect(find.text('恢复'), findsOneWidget);
      await tester.tap(find.text('恢复'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认恢复'));
      await tester.pumpAndSettle();
      expect(
        service.owner.recycleEntries.where((e) => e.id == entry.id),
        isEmpty,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看差异').last);
      await tester.pumpAndSettle();
      await service.owner.correctValue(
        const FieldRef('demo-server', 'username'),
        'concurrent-correction',
      );
      await tester.tap(find.text('确认恢复为新版本'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前信息已变化'), findsOneWidget);
      expect(
        service.owner.information.single.fields
            .firstWhere((f) => f.id == 'username')
            .value,
        'concurrent-correction',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'history shows old and current differences and restores only after owner confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      addTearDown(() async {
        final closing = service.close();
        await tester.pump();
        await closing;
      });
      await service.owner.correctValue(
        const FieldRef('demo-server', 'host'),
        'changed.invalid',
      );
      await tester.pumpWidget(
        MaterialApp(home: InformationLibrary(owner: service.owner)),
      );
      await tester.tap(find.text('Fictional demo server'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改历史'));
      await tester.pumpAndSettle();
      expect(find.textContaining('30 天'), findsWidgets);
      await tester.tap(find.text('查看差异'));
      await tester.pumpAndSettle();
      expect(find.textContaining('changed.invalid'), findsWidgets);
      expect(find.textContaining('demo.example.invalid'), findsWidgets);
      expect(service.owner.information.single.version, 2);
      await tester.tap(find.text('确认恢复为新版本'));
      await tester.pumpAndSettle();
      expect(service.owner.information.single.version, 3);
      expect(
        service.owner.information.single.fields.first.value,
        'demo.example.invalid',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
