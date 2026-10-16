import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

void main() {
  testWidgets(
    'owner edits a batch and sees confirmed information on the library tab',
    (tester) async {
      tester.view.physicalSize = const Size(1500, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(() async {
        final closing = service.close();
        await tester.pump();
        await closing;
      });
      final directory = await service.owner.createDirectory('Reviewed folder');
      final tag = await service.owner.createTag('Reviewed tag');
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      // Mount the library first, so switching back proves it refreshes existing UI.
      await tester.tap(find.text('我的信息'));
      await tester.pumpAndSettle();
      final session = service.agent.openSession('importing chat');
      final id = await service.agent.submitImport(session, [
        ImportItemInput('Suggested', 'Public suggestion', [
          const FieldInput('Host', 'Address', 'private.invalid'),
        ], suggestedDirectory: 'Servers'),
        ImportItemInput('Second suggestion', '', [
          const FieldInput(
            'Notes',
            '',
            'private note',
            kind: FieldKind.textNote,
          ),
        ]),
      ]);
      await tester.tap(find.text('录入提案'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('预览并调整'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('proposal-name-0')),
        'Reviewed item',
      );
      await tester.enterText(
        find.byKey(const ValueKey('proposal-value-0-0')),
        'reviewed.invalid',
      );
      await tester.tap(find.byKey(const ValueKey('proposal-directory-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reviewed folder').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('proposal-tag-0-0')));
      await tester.pumpAndSettle();
      expect(service.owner.information, isEmpty);
      await tester.tap(find.text('确认全部入库'));
      await tester.pumpAndSettle();
      expect(service.agent.importStatus(session, id)['status'], 'confirmed');
      expect(service.owner.information.first.directoryId, directory.id);
      expect(service.owner.information.first.tagIds, [tag.id]);
      expect(
        service.owner.information.first.fields.single.value,
        'reviewed.invalid',
      );
      await tester.tap(find.text('我的信息'));
      await tester.pumpAndSettle();
      expect(find.text('Reviewed item'), findsOneWidget);
      expect(find.text('Second suggestion'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
