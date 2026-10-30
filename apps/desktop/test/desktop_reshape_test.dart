import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/library.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/ui.dart';

class _FailingWrites extends MemoryInformationRepository {
  bool fail = false;
  int draftCommits = 0;
  @override
  Future<InformationDraftReceipt> commitInformationDraft(
    InformationDraftChange change,
  ) async {
    draftCommits++;
    if (fail) throw StateError('synthetic draft transaction failure');
    return super.commitInformationDraft(change);
  }

  @override
  Future<void> commitRecycleChange({
    required String itemId,
    InformationItem? item,
    InformationRevision? previous,
    required List<RecycleEntry> entries,
    required List<RecycleFact> facts,
    DeleteProposal? proposal,
    InformationLifecycleReceipt? lifecycleReceipt,
    void Function()? validate,
  }) async {
    if (fail) throw StateError('synthetic write failure');
    await super.commitRecycleChange(
      itemId: itemId,
      item: item,
      previous: previous,
      entries: entries,
      facts: facts,
      proposal: proposal,
      lifecycleReceipt: lifecycleReceipt,
      validate: validate,
    );
  }

  @override
  Future<void> save(InformationItem item) async {
    if (fail) throw StateError('synthetic write failure');
    await super.save(item);
  }

  @override
  Future<void> saveInformationRevision(
    InformationItem item,
    InformationRevision previous,
  ) async {
    if (fail) throw StateError('synthetic write failure');
    await super.saveInformationRevision(item, previous);
  }
}

void main() {
  testWidgets(
    'failed value correction preserves the draft and retries without changing identity',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _FailingWrites();
      final service = InformationService(repository: repository);
      final item = await service.owner.createInformation(
        'Server',
        'Deployment',
        [const FieldInput('Host', '', 'old.invalid')],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: InformationLibrary(owner: service.owner),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('edit-information-description')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('field-value-0')),
        'reviewed.invalid',
      );
      repository.fail = true;
      await tester.tap(find.byKey(const ValueKey('save-information')));
      await tester.pumpAndSettle();
      expect(find.textContaining('输入已保留'), findsOneWidget);
      expect(repository.draftCommits, 1);
      expect(find.text('reviewed.invalid'), findsOneWidget);
      expect(
        service.owner.information.single.fields.single.value,
        'old.invalid',
      );
      repository.fail = false;
      await tester.tap(find.byKey(const ValueKey('save-information')));
      await tester.pumpAndSettle();
      final saved = service.owner.information.single;
      expect(saved.fields.single.value, 'reviewed.invalid');
      expect(saved.fields.single.id, item.fields.single.id);
      expect(saved.version, 2);
      expect(repository.draftCommits, 2);
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: InformationLibrary(
            key: const ValueKey('reopened'),
            owner: service.owner,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('reviewed.invalid'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );
  testWidgets(
    'valid new information keeps its input on storage failure and saves once on retry',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = _FailingWrites();
      final service = InformationService(repository: repo);
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: InformationLibrary(owner: service.owner),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('new-information')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('item-name')),
        'New server',
      );
      await tester.enterText(
        find.byKey(const ValueKey('field-name-0')),
        'Host',
      );
      await tester.enterText(
        find.byKey(const ValueKey('field-value-0')),
        'new.invalid',
      );
      repo.fail = true;
      await tester.tap(find.byKey(const ValueKey('save-information')));
      await tester.pumpAndSettle();
      expect(service.owner.information, isEmpty);
      expect(repo.draftCommits, 1);
      expect(find.textContaining('输入已保留'), findsOneWidget);
      expect(find.textContaining('请填写'), findsNothing);
      expect(find.text('new.invalid'), findsOneWidget);
      repo.fail = false;
      await tester.tap(find.byKey(const ValueKey('save-information')));
      await tester.pumpAndSettle();
      expect(
        service.owner.information.single.fields.single.value,
        'new.invalid',
      );
      expect(service.owner.information.single.name, 'New server');
      expect(repo.draftCommits, 2);
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );

  testWidgets(
    'large-type request picker and scope review approve only the selected chat fields',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final service = InformationService.fictional();
      final a = service.agent.openSession('First');
      final b = service.agent.openSession('Second');
      const host = FieldRef('demo-server', 'host');
      const username = FieldRef('demo-server', 'username');
      final ar = service.agent.request(a, 'First purpose', [host]);
      final br = service.agent.request(b, 'Second purpose', [username]);
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('request-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second · 待处理').last);
      await tester.pumpAndSettle();
      expect(find.text('Second purpose'), findsOneWidget);
      await tester.tap(find.text('最终选择 1 个字段'));
      await tester.pumpAndSettle();
      expect(find.text('本次授权范围 · 1 个字段'), findsOneWidget);
      expect(find.text('· Username'), findsOneWidget);
      expect(find.text('· Address'), findsNothing);
      expect(service.agent.status(b, br.id)['status'], 'pending');
      await tester.tap(find.text('返回审批'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('approve-selection')));
      await tester.pumpAndSettle();
      expect(service.agent.claim(b, br.id).fields, [username]);
      expect(service.agent.status(a, ar.id)['status'], 'pending');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );
}
