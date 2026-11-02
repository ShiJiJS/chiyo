import 'package:info_desktop/organization_selectors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/import_proposals.dart';
import 'package:info_desktop/ui.dart';

class FailingImportRepository extends MemoryInformationRepository {
  bool fail = false;
  @override
  Future<void> commitImportAdmission(
    List<ImportProposal> proposals,
    List<InformationItem> items, {
    required String decisionProposalId,
    required bool confirm,
    List<ImportReceipt> decisionRecords = const [],
    List<String> awaitingKeys = const [],
    List<InformationDirectory> newDirectories = const [],
    List<InformationTag> newTags = const [],
  }) async {
    if (fail) throw StateError('synthetic storage failure');
    await super.commitImportAdmission(
      proposals,
      items,
      decisionProposalId: decisionProposalId,
      confirm: confirm,
      decisionRecords: decisionRecords,
      awaitingKeys: awaitingKeys,
      newDirectories: newDirectories,
      newTags: newTags,
    );
  }
}

void main() {
  testWidgets(
    'a stopped query reports failure without claiming an empty successful result',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      await service.agent.submitImport(
        service.agent.openSession('Stopped query'),
        [
          ImportItemInput('Pending item', '', [
            const FieldInput('Value', '', 'pending value'),
          ]),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(body: ImportProposalsPage(owner: service.owner)),
        ),
      );
      expect(find.text('pending value'), findsOneWidget);
      await service.close();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('提案查询失败，请调整条件或检查服务状态。'), findsOneWidget);
      expect(find.text('没有找到提案'), findsNothing);
      expect(find.text('调整关键词或查看全部提案。'), findsNothing);
      expect(find.text('调整左侧搜索或筛选后，继续查看详情。'), findsNothing);
      expect(find.text('pending value'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'queue paging and search retain a reviewed item when new proposals arrive',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 10, 17);
      final service = InformationService(
        repository: MemoryInformationRepository(),
        clock: () => now,
      );
      addTearDown(() async {
        final closing = service.close();
        await tester.pump();
        await closing;
      });
      final ids = <String>[];
      for (var n = 0; n < 10; n++) {
        now = now.add(const Duration(seconds: 1));
        ids.add(
          await service.agent.submitImport(
            service.agent.openSession(n == 1 ? 'Queue middle' : 'Queue $n'),
            [
              ImportItemInput('Item $n', '', [
                FieldInput('Value', '', 'value-$n'),
              ]),
            ],
          ),
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(body: ImportProposalsPage(owner: service.owner)),
        ),
      );
      await tester.tap(find.byTooltip('下一页提案'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('proposal-entry-${ids[1]}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('edit-import-0')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('field-value-0')),
        'reviewed-middle',
      );
      await tester.tap(find.byKey(const ValueKey('save-information')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('proposal-search')),
        'Queue middle',
      );
      await tester.pumpAndSettle();
      now = now.add(const Duration(seconds: 1));
      await service.agent.submitImport(service.agent.openSession('Incoming'), [
        ImportItemInput('Incoming', '', [
          const FieldInput('Value', '', 'incoming value'),
        ]),
      ]);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('proposal-search')))
            .controller!
            .text,
        'Queue middle',
      );
      expect(find.text('reviewed-middle'), findsOneWidget);
      expect(find.text('incoming value'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('proposal-search')),
        'no such proposal',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('proposal-document')), findsNothing);
      expect(find.text('reviewed-middle'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('proposal-search')), '');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一页提案'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('proposal-entry-${ids[1]}')));
      await tester.pumpAndSettle();
      expect(find.text('reviewed-middle'), findsOneWidget);
      expect(service.owner.information, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'external proposal identity selects its terminal receipt or an explicit missing state',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
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
      final session = service.agent.openSession('External identity');
      final terminal = await service.agent.submitImport(session, [
        ImportItemInput('Handled', '', [
          const FieldInput('Value', '', 'handled value'),
        ]),
      ]);
      await service.owner.rejectImport(terminal, 1);
      await service.agent.submitImport(session, [
        ImportItemInput('Pending', '', [
          const FieldInput('Value', '', 'pending value'),
        ]),
      ]);
      Widget page(String id) => MaterialApp(
        theme: informationTheme(),
        home: Scaffold(
          body: ImportProposalsPage(
            owner: service.owner,
            initialProposalId: id,
          ),
        ),
      );
      await tester.pumpWidget(page(terminal));
      await tester.pumpAndSettle();
      expect(find.text('处理回执'), findsOneWidget);
      expect(find.text('pending value'), findsNothing);
      await tester.pumpWidget(page('missing-proposal'));
      await tester.pumpAndSettle();
      expect(find.text('该提案已不存在。请从左侧选择其他提案。'), findsOneWidget);
      expect(find.byKey(const ValueKey('proposal-document')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('review can discard suggested labels without creating them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
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
    final folder = await service.owner.createDirectory('Existing folder');
    await service.agent.submitImport(
      service.agent.openSession('Suggested labels'),
      [
        ImportItemInput(
          'Suggested item',
          '',
          [const FieldInput('URL', '', 'suggested.example')],
          suggestedDirectory: 'Suggested folder',
          suggestedTags: ['Suggested tag'],
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: informationTheme(),
        home: Scaffold(body: ImportProposalsPage(owner: service.owner)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('edit-import-0')));
    await tester.pumpAndSettle();
    expect(find.text('Agent 建议创建目录：Suggested folder'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('item-directory')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Existing folder').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('item-tags')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agent 建议：Suggested tag'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用所选标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-information')));
    await tester.pumpAndSettle();
    expect(service.owner.information, isEmpty);
    await tester.tap(find.byKey(const ValueKey('proposal-action-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-proposal-decision')));
    await tester.pumpAndSettle();
    expect(service.owner.information.single.directoryId, folder.id);
    expect(service.owner.directories, hasLength(1));
    expect(service.owner.tags, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'invalid classification can be explicitly repaired without a partial batch',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
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
      final directory = await service.owner.createDirectory('Valid folder');
      await service.agent.submitImport(
        service.agent.openSession('Repair invalid classification'),
        [
          ImportItemInput('Valid first', '', [
            const FieldInput('URL', '', 'first.example'),
          ]),
          ImportItemInput(
            'Invalid second',
            '',
            [const FieldInput('URL', '', 'second.example')],
            directoryId: 'missing-directory',
            tagIds: ['missing-tag'],
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(body: ImportProposalsPage(owner: service.owner)),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('proposal-action-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-proposal-decision')));
      await tester.pumpAndSettle();
      expect(service.owner.information, isEmpty);
      expect(find.textContaining('草稿已保留'), findsOneWidget);
      await tester.tap(find.text('返回核对'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('edit-import-1')));
      await tester.tap(find.byKey(const ValueKey('edit-import-1')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('item-directory')),
          matching: find.text('原目录不可用，请重新选择'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('item-directory')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valid folder').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('item-tags')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除不可用标签（missing-tag）').last);
      await tester.tap(find.text('使用所选标签'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-information')));
      await tester.pumpAndSettle();
      expect(service.owner.information, isEmpty);
      await tester.tap(find.byKey(const ValueKey('proposal-action-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-proposal-decision')));
      await tester.pumpAndSettle();
      expect(service.owner.information, hasLength(2));
      expect(service.owner.information.last.directoryId, directory.id);
      expect(service.owner.information.last.tagIds, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Escape returns confirmation focus to its originating action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = InformationService(
      repository: MemoryInformationRepository(),
    );
    await service.agent.submitImport(
      service.agent.openSession('Keyboard import'),
      [
        ImportItemInput('Keyboard item', '', [
          const FieldInput('URL', '', 'keyboard.example'),
        ]),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: informationTheme(),
        home: Scaffold(body: ImportProposalsPage(owner: service.owner)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('proposal-action-confirm')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('confirm-proposal-decision')),
      findsNothing,
    );
    expect(service.owner.information, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('confirm-proposal-decision')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await service.close();
  });
  testWidgets('current result closes its values when the service stops', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = InformationService(
      repository: MemoryInformationRepository(),
    );
    final id = await service.agent.submitImport(
      service.agent.openSession('Completed import'),
      [
        ImportItemInput('Current service', '', [
          const FieldInput('URL', '', 'current-only.example'),
        ]),
      ],
    );
    await service.owner.confirmImport(
      id,
      1,
      service.owner.importProposals.single.items,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: informationTheme(),
        home: Scaffold(body: ImportProposalsPage(owner: service.owner)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('proposal-filter-handled')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按信息身份查看当前内容 →'));
    await tester.pumpAndSettle();
    expect(find.text('current-only.example'), findsOneWidget);
    await service.close();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('current-only.example'), findsNothing);
    expect(find.text('信息库暂不可用，请恢复服务后重试。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'batch storage failure keeps the reviewed item and retries atomically',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = FailingImportRepository();
      final service = InformationService(repository: repository);
      addTearDown(() async {
        final closing = service.close();
        await tester.pump();
        await closing;
      });
      final id = await service.agent.submitImport(
        service.agent.openSession('Batch import'),
        [
          ImportItemInput('First', '', [
            const FieldInput('URL', '', 'first.example'),
          ]),
          ImportItemInput('Second', '', [
            const FieldInput('URL', '', 'second.example'),
          ]),
        ],
      );
      String? openedItem;
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(
            body: ImportProposalsPage(
              owner: service.owner,
              onOpenInformation: (id) => openedItem = id,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('edit-import-0')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('field-value-0')),
        'reviewed.example',
      );
      await tester.tap(find.byKey(const ValueKey('save-information')));
      await tester.pumpAndSettle();
      repository.fail = true;
      await tester.tap(find.byKey(const ValueKey('proposal-action-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-proposal-decision')));
      await tester.pumpAndSettle();
      expect(find.textContaining('提案和调整内容已保留'), findsOneWidget);
      expect(find.text('未应用这批变更'), findsOneWidget);
      await tester.tap(find.text('返回核对'));
      await tester.pumpAndSettle();
      expect(service.owner.information, isEmpty);
      expect(find.text('reviewed.example'), findsOneWidget);
      repository.fail = false;
      await tester.tap(find.byKey(const ValueKey('proposal-action-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-proposal-decision')));
      await tester.pumpAndSettle();
      expect(
        service.owner.information.map((item) => item.fields.single.value),
        ['reviewed.example', 'second.example'],
      );
      final receipts = await service.owner.confirmImport(id, 1, const []);
      expect(receipts, hasLength(2));
      expect(service.owner.information, hasLength(2));
      final current = service.owner.information.first;
      await service.owner.correctValue(
        FieldRef(current.id, current.fields.single.id),
        'current.example',
      );
      await tester.tap(find.text('按信息身份查看当前内容 →'));
      await tester.pumpAndSettle();
      expect(find.text('current.example'), findsOneWidget);
      expect(find.text('reviewed.example'), findsNothing);
      await tester.tap(find.text('在信息库打开 →').first);
      await tester.pumpAndSettle();
      expect(openedItem, current.id);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'a version race during confirmation keeps the conflict receipt visible',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
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
      final item = await service.owner.createInformation('Docs', '', [
        const FieldInput('URL', '', 'old.example'),
      ]);
      await service.agent.submitUpdate(
        service.agent.openSession('Update docs'),
        UpdateInput(item.id, 1, [
          FieldChange.correct(item.fields.single.id, 'submitted.example'),
        ]),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(body: ImportProposalsPage(owner: service.owner)),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('proposal-action-confirm')));
      await tester.pumpAndSettle();
      await service.owner.correctValue(
        FieldRef(item.id, item.fields.single.id),
        'manual.example',
      );
      await tester.tap(find.byKey(const ValueKey('confirm-proposal-decision')));
      await tester.pumpAndSettle();
      expect(
        service.owner.information.single.fields.single.value,
        'manual.example',
      );
      expect(find.textContaining('未覆盖当前内容'), findsOneWidget);
      expect(find.text('处理回执'), findsOneWidget);
      expect(find.text('submitted.example'), findsNothing);
      await tester.tap(find.text('按信息身份查看当前内容 →'));
      await tester.pumpAndSettle();
      expect(find.text('manual.example'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'a completed organization with no changes is a read-only result',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
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
      final item = await service.owner.createInformation('Docs', '', [
        const FieldInput('URL', '', 'never-show-value'),
      ]);
      final session = service.agent.openSession('Organize docs');
      final task = await service.agent.requestOrganization(
        session,
        'Check categories',
        [item.id],
        agentName: 'Codex',
      );
      await service.owner.approveOrganization(task.id, [item.id]);
      await service.agent.submitOrganization(session, task.id, []);
      expect(
        service.owner
            .queryProposals(filter: ProposalFilter.handled)
            .entries
            .single
            .stateLabel,
        '无改动完成',
      );
      String? openedGrant;
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(
            body: ImportProposalsPage(
              owner: service.owner,
              onOpenOrganizationGrant: (id) => openedGrant = id,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('proposal-filter-handled')));
      await tester.pumpAndSettle();
      expect(find.text('没有分类或标签变化。已完成本次整理，整理能力已经结束。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('proposal-action-confirm')),
        findsNothing,
      );
      expect(find.text('never-show-value'), findsNothing);
      await tester.tap(find.text('查看本次整理授权 →'));
      expect(openedGrant, task.id);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('deletion review shows the live target then only a receipt', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
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
    final item = await service.owner.createInformation('Archived docs', '', [
      const FieldInput('URL', '', 'archive.example'),
    ]);
    await service.agent.submitDelete(
      service.agent.openSession('Remove archive'),
      item.id,
      1,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: informationTheme(),
        home: Scaffold(body: ImportProposalsPage(owner: service.owner)),
      ),
    );
    expect(find.text('archive.example'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('proposal-action-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-proposal-decision')));
    await tester.pumpAndSettle();
    expect(service.owner.information, isEmpty);
    expect(find.text('archive.example'), findsNothing);
    await tester.tap(find.text('按信息身份查看当前内容 →'));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前信息已不存在'), findsOneWidget);
    expect(find.text('archive.example'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'reviewing a modification preserves explicit replacement identity',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
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
      final originalDirectory = await service.owner.createDirectory(
        'Original folder',
      );
      final item = await service.owner.createInformation('Docs', '', [
        const FieldInput('URL', '', 'old.example'),
        const FieldInput('Note', '', 'old note'),
      ], directoryId: originalDirectory.id);
      await service.agent.submitUpdate(
        service.agent.openSession('Update docs'),
        UpdateInput(item.id, 1, [
          FieldChange.correct(item.fields.first.id, 'submitted.example'),
          FieldChange.replace(
            item.fields.last.id,
            const FieldInput('Note', '', 'new meaning'),
          ),
        ]),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(body: ImportProposalsPage(owner: service.owner)),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('edit-update')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('field-value-0')),
        'reviewed.example',
      );
      await tester.tap(find.byKey(const ValueKey('item-directory')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('未分类').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-information')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('edit-update')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DirectoryField>(
              find.byKey(const ValueKey('item-directory')),
            )
            .value,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        service.owner.information.single.fields.first.value,
        'old.example',
      );
      await tester.tap(find.byKey(const ValueKey('proposal-action-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-proposal-decision')));
      await tester.pumpAndSettle();
      final current = service.owner.information.single;
      expect(current.directoryId, isNull);
      expect(current.fields.first.id, item.fields.first.id);
      expect(current.fields.first.value, 'reviewed.example');
      expect(current.fields.last.id, isNot(item.fields.last.id));
      expect(current.fields.last.name, 'Note');
      expect(current.fields.last.value, 'new meaning');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'one item review stays a draft until the whole batch is confirmed',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
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
      final session = service.agent.openSession('Review batch');
      final id = await service.agent.submitImport(session, [
        ImportItemInput('First', 'public', [
          const FieldInput('URL', '', 'first.example'),
        ]),
        ImportItemInput('Second', '', [
          const FieldInput(
            'Note',
            '',
            'second value',
            kind: FieldKind.textNote,
          ),
        ]),
      ], agentName: 'Codex');
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(body: ImportProposalsPage(owner: service.owner)),
        ),
      );
      expect(find.byKey(const ValueKey('proposal-document')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('edit-import-0')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('item-name')),
        'Reviewed first',
      );
      await tester.enterText(
        find.byKey(const ValueKey('field-value-0')),
        'reviewed.example',
      );
      await tester.tap(find.byKey(const ValueKey('save-information')));
      await tester.pumpAndSettle();
      expect(service.owner.information, isEmpty);
      expect(find.text('reviewed.example'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('proposal-action-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-proposal-decision')));
      await tester.pumpAndSettle();
      expect(service.agent.importStatus(session, id)['status'], 'confirmed');
      expect(service.owner.information.map((item) => item.name), [
        'Reviewed first',
        'Second',
      ]);
      expect(
        service.owner.information.last.fields.single.value,
        'second value',
      );
      expect(find.text('reviewed.example'), findsNothing);
      expect(find.text('处理回执'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
