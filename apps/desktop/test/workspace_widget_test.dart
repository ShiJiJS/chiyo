import 'package:info_desktop/desktop_controls.dart';
import 'support/approval_interactions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

void main() {
  for (final scenario in [
    (size: const Size(1280, 800), scale: 1.0),
    (size: const Size(800, 650), scale: 1.0),
    (size: const Size(1440, 1000), scale: 2.0),
  ]) {
    testWidgets(
      'decision remains reachable at ${scenario.size} with ${scenario.scale} text',
      (tester) async {
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scenario.scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final service = InformationService(
          repository: MemoryInformationRepository(),
        );
        final item = await service.owner.createInformation(
          'Project environment',
          'Deployment connection',
          [for (var i = 0; i < 30; i++) FieldInput('Field $i', '', 'value-$i')],
        );
        final session = service.agent.openSession('Deployment chat');
        final request = service.agent.request(
          session,
          'Check project deployment configuration',
          [for (final field in item.fields) FieldRef(item.id, field.id)],
        );
        await tester.pumpWidget(InformationApp(service: service, port: 47125));
        await tester.pumpAndSettle();
        final approve = find.byKey(const ValueKey('approve-selection'));
        expect(approve.hitTestable(), findsOneWidget);
        expect(find.text('拒绝请求').hitTestable(), findsOneWidget);
        await selectGrantMinutes(
          tester,
          find.byKey(ValueKey('grant-lifetime-${request.id}')),
          15,
        );
        await tester.pumpAndSettle();
        expect(approve.hitTestable(), findsOneWidget);
        expect(find.byKey(const ValueKey('nav-0')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(approve);
        await tester.pumpAndSettle();
        expect(service.agent.claim(session, request.id).fields, hasLength(30));
        await tester.pumpWidget(const SizedBox());
        await service.close();
      },
    );
  }

  testWidgets(
    'switching requests preserves drafts and approves only the focused request',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      final a = service.agent.openSession('First chat');
      final b = service.agent.openSession('Second chat');
      const host = FieldRef('demo-server', 'host');
      const username = FieldRef('demo-server', 'username');
      final first = service.agent.request(a, 'First purpose', [host]);
      final second = service.agent.request(b, 'Second purpose', [username]);
      await tester.pumpWidget(InformationApp(service: service, port: 47125));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('request-${first.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('field-host')));
      await selectGrantMinutes(
        tester,
        find.byKey(ValueKey('grant-lifetime-${first.id}')),
        15,
      );
      await tester.tap(find.byKey(ValueKey('request-${second.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('approve-selection')));
      await tester.pumpAndSettle();
      expect(service.agent.claim(b, second.id).fields, [username]);
      expect(service.agent.status(a, first.id)['status'], 'pending');
      await tester.tap(find.byKey(ValueKey('request-${first.id}')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DesktopSelect<int>>(
              find.byKey(ValueKey('grant-lifetime-${first.id}')),
            )
            .value,
        15,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('approve-selection')),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );

  testWidgets(
    'returning to history refreshes approvals made after its first visit',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      final session = service.agent.openSession('New approved chat');
      final request = service.agent.request(session, 'Need host', [
        const FieldRef('demo-server', 'host'),
      ]);
      await tester.pumpWidget(InformationApp(service: service, port: 47125));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-3')));
      await tester.pumpAndSettle();
      expect(find.text('暂无授权历史。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('approve-selection')));
      await tester.pumpAndSettle();
      expect(service.agent.status(session, request.id)['status'], 'approved');
      await tester.tap(find.byKey(const ValueKey('nav-3')));
      await tester.pumpAndSettle();
      expect(find.text('New approved chat'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );
}
