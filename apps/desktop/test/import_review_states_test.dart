import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

class _FailingRepository extends MemoryInformationRepository {
  bool fail = true;
  @override
  Future<void> confirmImportProposal(
    ImportProposal proposal,
    List<InformationItem> items, {
    List<InformationDirectory> newDirectories = const [],
    List<InformationTag> newTags = const [],
  }) async {
    if (fail) {
      fail = false;
      throw StateError('Synthetic save failure');
    }
    return super.confirmImportProposal(
      proposal,
      items,
      newDirectories: newDirectories,
      newTags: newTags,
    );
  }
}

void main() {
  testWidgets(
    'failed import preserves the edited read-only draft and retries the complete batch once',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService(repository: _FailingRepository());
      final session = service.agent.openSession('chat');
      await service.agent.submitImport(
        session,
        [
          ImportItemInput('服务', '', [
            const FieldInput('地址', '', 'original.invalid'),
          ], suggestedDirectory: '服务入口'),
        ],
        agentName: 'Codex',
        purpose: '整理服务',
      );
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.tap(find.byKey(const ValueKey('nav-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看提案'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('edit-import-0')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('proposal-value-0-0')),
        'reviewed.invalid',
      );
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认全部入库'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未能保存，提案和更改已保留'), findsOneWidget);
      expect(find.text('reviewed.invalid'), findsOneWidget);
      expect(service.owner.information, isEmpty);
      expect(service.owner.directories, isEmpty);
      expect(
        service.owner.importProposals.single.state,
        ImportProposalState.pending,
      );
      await tester.tap(find.text('确认全部入库'));
      await tester.pumpAndSettle();
      expect(
        service.owner.information.single.fields.single.value,
        'reviewed.invalid',
      );
      expect(service.owner.directories.single.name, '服务入口');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
  );
  testWidgets(
    'confirmed details follow current information and never resurrect deleted content',
    (tester) async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final session = service.agent.openSession('chat');
      final id = await service.agent.submitImport(session, [
        ImportItemInput('Archived', '', [
          const FieldInput('Value', '', 'old-private-value'),
        ]),
      ]);
      final receipt = (await service.owner.confirmImport(
        id,
        1,
        service.owner.importProposals.single.items,
      )).single;
      final field = service.owner.information.single.fields.single;
      await service.owner.correctValue(
        FieldRef(receipt.id, field.id),
        'current-private-value',
      );
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.tap(find.byKey(const ValueKey('nav-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(find.text('current-private-value'), findsOneWidget);
      expect(find.text('old-private-value'), findsNothing);
      expect(find.text('编辑'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await service.owner.deleteInformation(receipt.id, 2);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Archived'), findsOneWidget);
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(find.text('current-private-value'), findsNothing);
      expect(find.textContaining('部分资料已删除或不可用'), findsOneWidget);
      expect(service.owner.importProposals.single.items, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
  );
  testWidgets(
    'rejected proposals retain public title summaries but no field values',
    (tester) async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final session = service.agent.openSession('Codex');
      final id = await service.agent.submitImport(
        session,
        [
          ImportItemInput('笔记服务入口', '', [
            const FieldInput('地址', '', 'NEVER-RETAIN-REJECTED-VALUE'),
          ]),
        ],
        agentName: 'Codex',
        purpose: '整理指定资料',
      );
      await service.owner.rejectImport(id, 1);
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.tap(find.byKey(const ValueKey('nav-2')));
      await tester.pumpAndSettle();
      expect(find.text('笔记服务入口'), findsOneWidget);
      expect(find.text('NEVER-RETAIN-REJECTED-VALUE'), findsNothing);
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(find.text('编辑'), findsNothing);
      expect(find.text('NEVER-RETAIN-REJECTED-VALUE'), findsNothing);
      expect(find.textContaining('拟录入内容已清理'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
  );
}
