import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

void main() {
  testWidgets(
    'Agent requests in approval inbox; one approval enables automatic classification and read-only result',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      final session = service.agent.openSession('Codex 整理资料');
      final task = await service.agent.requestOrganization(session, '整理服务器分类', [
        'demo-server',
      ], agentName: 'Codex');
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      expect(find.text('允许整理的资料'), findsOneWidget);
      expect(find.textContaining('无需再次确认'), findsOneWidget);
      expect(find.text('fictional.example.invalid'), findsNothing);
      await tester.tap(
        find.byKey(ValueKey('organization-lifetime-${task.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('15 分钟').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('批准整理范围'));
      await tester.pumpAndSettle();
      expect(
        service.agent.organizationStatus(session, task.id)['status'],
        'active',
      );
      expect(
        service.owner.organizationTasks.single.expiresAt.difference(
          service.owner.organizationTasks.single.approvedAt!,
        ),
        const Duration(minutes: 15),
      );
      await service.agent.submitOrganization(session, task.id, [
        OrganizationChange(
          itemId: 'demo-server',
          baseVersion: 1,
          directoryName: '服务器',
        ),
      ]);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('整理完成'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('nav-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('proposal-filter-handled')));
      await tester.pumpAndSettle();
      expect(find.text('确认整批调整'), findsNothing);
      expect(find.text('服务器'), findsOneWidget);
      final unchanged = await service.agent.requestOrganization(
        session,
        '检查现有分类',
        ['demo-server'],
      );
      await service.owner.approveOrganization(unchanged.id, ['demo-server']);
      await service.agent.submitOrganization(session, unchanged.id, []);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('proposal-entry-${unchanged.id}')));
      await tester.pumpAndSettle();
      expect(find.textContaining('没有分类或标签变化'), findsOneWidget);
      expect(service.owner.information.single.version, 2);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
  );
  testWidgets(
    'owner can narrow metadata scope and reject a later Agent request',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      final extra = await service.owner.createInformation('其他资料', '', [
        const FieldInput('值', '', 'private'),
      ]);
      final session = service.agent.openSession('Codex');
      final task = await service.agent.requestOrganization(session, '整理资料', [
        'demo-server',
        extra.id,
      ]);
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('organize-item-${extra.id}')));
      await tester.pumpAndSettle();
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await tester.pumpAndSettle();
      expect(find.text('允许整理的资料'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('organize-item-${extra.id}')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(
                PageStorageKey('organization-document-${task.id}'),
              ),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(
                of: find.byKey(ValueKey('organize-item-${extra.id}')),
                matching: find.byType(Checkbox),
              ),
            )
            .value,
        false,
      );
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.pumpAndSettle();
      await tester.tap(find.text('批准整理范围'));
      await tester.pumpAndSettle();
      expect(service.owner.organizationTasks.single.itemVersions.keys, [
        'demo-server',
      ]);
      await service.agent.requestOrganization(session, '再次申请', [extra.id]);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          ValueKey('request-${service.owner.organizationTasks.last.id}'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('拒绝请求'));
      await tester.pumpAndSettle();
      expect(
        service.owner.organizationTasks.last.state,
        OrganizationTaskState.rejected,
      );
      expect(
        service.agent.organizationStatus(session, task.id)['status'],
        'active',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
  );
  testWidgets(
    'organization shares the inbox with content requests without changing content approval',
    (tester) async {
      final service = InformationService.fictional();
      final session = service.agent.openSession('Codex');
      final content = service.agent.request(session, '检查地址', [
        const FieldRef('demo-server', 'host'),
      ]);
      final task = await service.agent.requestOrganization(session, '分类整理', [
        'demo-server',
      ]);
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('request-${task.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批准整理范围'));
      await tester.pumpAndSettle();
      expect(service.agent.status(session, content.id)['status'], 'pending');
      await tester.tap(find.byKey(ValueKey('request-${content.id}')));
      await tester.pumpAndSettle();
      expect(find.text('批准所选字段'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
  );
}
