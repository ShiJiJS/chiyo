import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/import_proposals.dart';

void main() {
  testWidgets(
    'owner reviews old and new content then confirms without an agent grant',
    (tester) async {
      tester.view.physicalSize = const Size(1500, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final item = await service.owner.createInformation(
        'Old name',
        'Old public description',
        [
          const FieldInput(
            'Host',
            'Public host explanation',
            'OLD-DESKTOP-VALUE',
          ),
        ],
      );
      final session = service.agent.openSession('updater');
      final id = await service.agent.submitUpdate(
        session,
        UpdateInput(
          item.id,
          1,
          [FieldChange.correct(item.fields.single.id, 'NEW-DESKTOP-VALUE')],
          name: 'Reviewed name',
          description: 'Reviewed public description',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ImportProposalsPage(owner: service.owner)),
        ),
      );
      await tester.tap(find.text('查看修改差异'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Old public description'), findsOneWidget);
      expect(
        find.textContaining('Reviewed public description'),
        findsOneWidget,
      );
      expect(find.textContaining('OLD-DESKTOP-VALUE'), findsOneWidget);
      expect(find.textContaining('NEW-DESKTOP-VALUE'), findsOneWidget);
      expect(service.owner.information.single.version, 1);
      await tester.tap(find.text('确认这些修改'));
      await tester.pumpAndSettle();
      expect(service.owner.information.single.name, 'Reviewed name');
      expect(service.owner.information.single.version, 2);
      expect(service.agent.updateStatus(session, id)['status'], 'confirmed');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
