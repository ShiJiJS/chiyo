import 'support/approval_interactions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

void main() async {
  testWidgets(
    'owner can remove a requested field that is no longer available',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = MemoryInformationRepository();
      final core = InformationService(repository: repository);
      final item = await core.owner.createInformation('Server', '', [
        const FieldInput('Address', '', 'a.invalid'),
        const FieldInput('Notes', '', 'private text'),
      ]);
      final removed = FieldRef(item.id, item.fields.first.id);
      final remaining = FieldRef(item.id, item.fields.last.id);
      final session = core.agent.openSession('chat');
      final request = core.agent.request(session, 'Need address', [removed]);
      await repository.save(
        InformationItem(item.id, item.name, '', 2, [item.fields.last]),
      );
      await tester.pumpWidget(InformationApp(service: core, port: 47125));
      final unavailable = find.byKey(ValueKey('field-${removed.fieldId}'));
      expect(unavailable, findsOneWidget);
      await tester.ensureVisible(unavailable);
      await tester.pumpAndSettle();
      await tester.tap(unavailable);
      await tester.tap(find.text('调整提供范围 / 补选其他信息'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(ValueKey('scope-field-${remaining.fieldId}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('scope-field-${remaining.fieldId}')),
      );
      await tester.tap(find.byKey(const ValueKey('scope-apply')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('批准所选字段'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批准所选字段'));
      await tester.pump();
      expect(core.agent.claim(session, request.id).fields, [remaining]);
      await tester.pumpWidget(const SizedBox());
      core.close();
    },
  );

  testWidgets('owner replaces a requested field and selects a shorter grant', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = InformationService(
      repository: MemoryInformationRepository(),
      clock: () => DateTime.utc(2026, 10, 16),
    );
    final first = await core.owner.createInformation('Server A', '', [
      const FieldInput('Address A', '', 'a.invalid'),
    ]);
    final second = await core.owner.createInformation('Server B', '', [
      const FieldInput('Private notes B', '', 'Use test network'),
    ]);
    final requested = FieldRef(first.id, first.fields.single.id);
    final replacement = FieldRef(second.id, second.fields.single.id);
    final session = core.agent.openSession('chat');
    final request = core.agent.request(session, 'Connect to the right server', [
      requested,
    ]);
    await tester.pumpWidget(InformationApp(service: core, port: 47125));

    expect(find.text('申请范围'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(ValueKey('field-${requested.fieldId}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('field-${requested.fieldId}')));
    await tester.tap(find.text('调整提供范围 / 补选其他信息'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(ValueKey('scope-field-${replacement.fieldId}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('scope-field-${replacement.fieldId}')),
    );
    await tester.tap(find.byKey(const ValueKey('scope-apply')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(ValueKey('grant-lifetime-${request.id}')),
    );
    await tester.pumpAndSettle();
    await selectGrantMinutes(
      tester,
      find.byKey(ValueKey('grant-lifetime-${request.id}')),
      30,
    );
    await tester.ensureVisible(find.text('批准所选字段'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批准所选字段'));
    await tester.pump();

    final grant = core.agent.claim(session, request.id);
    expect(grant.fields, [replacement]);
    expect(grant.expiresAt, DateTime.utc(2026, 10, 16, 0, 30));
    expect(await core.agent.read(grant.token, replacement), 'Use test network');
    expect(
      () => core.agent.read(grant.token, requested),
      throwsA(isA<AccessFailure>()),
    );
    expect(find.text('Server B'), findsWidgets);
    expect(find.text('Private notes B'), findsWidgets);
    expect(find.text('申请范围'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    core.close();
  });
}
