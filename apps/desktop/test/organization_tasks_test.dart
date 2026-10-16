import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

void main() {
  testWidgets(
    'owner assigns scoped organization and reviews a read-only batch before applying',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final item = await service.owner.createInformation('笔记服务', '公开说明', [
        const FieldInput('地址', '', 'PRIVATE-CONTENT'),
      ]);
      final session = service.agent.openSession('Codex · 整理资料');
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agent 整理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建整理任务'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不会提供字段值'), findsOneWidget);
      await tester.tap(find.text('创建任务'));
      await tester.pumpAndSettle();
      final task = service.owner.organizationTasks.single;
      expect(task.itemVersions.keys, [item.id]);
      expect(service.owner.information.single.directoryId, isNull);
      await service.agent.submitOrganization(session, task.id, [
        OrganizationChange(
          itemId: item.id,
          baseVersion: 1,
          directoryName: '服务入口',
          tagNames: ['笔记'],
        ),
      ]);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看整理方案'));
      await tester.pumpAndSettle();
      expect(find.text('分类：未分类 → 服务入口'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('PRIVATE-CONTENT'), findsNothing);
      await tester.tap(find.text('确认整批调整'));
      await tester.pumpAndSettle();
      expect(
        service.owner.organizationTasks.single.state,
        OrganizationTaskState.confirmed,
      );
      expect(service.owner.directories.single.name, '服务入口');
      expect(
        service.owner.information.single.fields.single.value,
        'PRIVATE-CONTENT',
      );
      await tester.tap(find.byKey(const ValueKey('subpage-back')));
      await tester.pumpAndSettle();
      expect(find.textContaining('服务入口'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
  );
  testWidgets(
    'organization cannot be started without a receiving agent session',
    (tester) async {
      final service = InformationService.fictional();
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agent 整理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建整理任务'));
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有有效的 Agent 聊天'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '创建任务'))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
  );
}
