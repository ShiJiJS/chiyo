import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/library.dart';
import 'package:info_desktop/import_proposals.dart';

void main() {
  testWidgets(
    'owner must explicitly confirm field deletion and can restore from recycle',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      addTearDown(() async {
        final closing = service.close();
        await tester.pump();
        await closing;
      });
      await tester.pumpWidget(
        MaterialApp(home: InformationLibrary(owner: service.owner)),
      );
      await tester.tap(find.text('Fictional demo server'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除字段').first);
      await tester.pumpAndSettle();
      expect(service.owner.information.single.fields, hasLength(2));
      expect(find.textContaining('30 天'), findsWidgets);
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(service.owner.information.single.fields, hasLength(1));
      await tester.tap(find.text('回收站'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复'));
      await tester.pumpAndSettle();
      expect(find.textContaining('重新批准'), findsWidgets);
      await tester.tap(find.text('确认恢复'));
      await tester.pumpAndSettle();
      expect(service.owner.information.single.fields, hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'agent field deletion preview names only selected target before explicit confirmation',
    (tester) async {
      final service = InformationService.fictional();
      addTearDown(() async {
        final closing = service.close();
        await tester.pump();
        await closing;
      });
      final session = service.agent.openSession('proposer');
      final id = await service.agent.submitDelete(
        session,
        'demo-server',
        1,
        fieldId: 'host',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ImportProposalsPage(owner: service.owner)),
        ),
      );
      await tester.tap(find.text('查看删除范围'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Address'), findsOneWidget);
      expect(find.textContaining('Username'), findsNothing);
      expect(service.owner.information.single.fields, hasLength(2));
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(service.agent.deleteStatus(session, id)['status'], 'confirmed');
      expect(service.owner.information.single.fields.single.id, 'username');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
