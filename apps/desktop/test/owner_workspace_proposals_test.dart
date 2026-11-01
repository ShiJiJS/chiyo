import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/owner_workspace_proposals.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async {
    value = List.of(key);
  }
}

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceSource library;
  late OwnerWorkspaceProposals source;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(repository: repo);
    source = OwnerWorkspaceProposals(
      owner: service.owner,
      library: () => library,
      changed: () => library.notifyExternalChange(),
    );
    library = OwnerWorkspaceSource(
      owner: service.owner,
      proposals: source,
      refreshInterval: Duration.zero,
    );
  }

  Future<void> close() async {
    await library.dispose();
    await service.close();
    await repo.close();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-proposals-');
    keys = _Keys();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  WorkspaceProposalChange decision(
    WorkspaceProposalDetail d, {
    bool confirm = true,
    List<WorkspaceProposalItemReview>? reviewed,
  }) => WorkspaceProposalChange(
    operationId: workspaceOperationId(),
    proposalId: d.summary.id,
    version: d.summary.version,
    reviewToken: d.reviewToken,
    action: confirm
        ? WorkspaceProposalAction.confirm
        : WorkspaceProposalAction.reject,
    reviewed: confirm
        ? reviewed ?? d.items.map(WorkspaceProposalItemReview.fromItem).toList()
        : [],
  );
  test(
    'real addition review, partial selection and suggested classification persist without terminal bodies',
    () async {
      final session = service.agent.openSession('合成聊天');
      final id = await service.agent.submitImport(session, [
        core.ImportItemInput(
          '保留项',
          '',
          [const core.FieldInput('字段', '', '合成原文')],
          suggestedDirectory: '合成新目录',
          suggestedTags: ['合成新标签'],
        ),
        core.ImportItemInput('未选项', '', [
          const core.FieldInput('字段', '', '不应保存'),
        ]),
      ]);
      final d = await source.read(id);
      expect(d.canConfirm, isTrue);
      final catalog = await source.catalog();
      expect(catalog.directories.any((d) => d.name == '建议新建：合成新目录'), isTrue);
      final original = d.items.first,
          review = WorkspaceProposalItemReview.fromItem(original);
      final edit = WorkspaceProposalItemReview(
        itemId: review.itemId,
        name: '主人核对名称',
        description: review.description,
        directoryId: review.directoryId,
        tagIds: review.tagIds,
        values: {for (final k in review.values.keys) k: '主人核对正文'},
      );
      final command = decision(d, reviewed: [edit]);
      final receipt = await source.change(command);
      WorkspaceProposalExpectation(d).check(command, receipt);
      expect(service.owner.information.length, 1);
      expect(service.owner.information.single.name, '主人核对名称');
      expect(service.owner.information.single.fields.single.value, '主人核对正文');
      expect(service.owner.directories.single.name, '合成新目录');
      expect(service.owner.tags.single.name, '合成新标签');
      expect(service.owner.importProposals.single.items, isEmpty);
      expect((await source.read(id)).items, isEmpty);
      final archive = await source.snapshot(id, receipt.records.single.ref);
      expect(archive.detail.record.name, '主人核对名称');
      await close();
      await open();
      expect(
        (await source.receipt(command.operationId))!.records.single.ref,
        receipt.records.single.ref,
      );
      expect((await source.change(command)).commandDigest, command.digest);
      expect(service.owner.information.length, 1);
    },
  );
  test(
    'mixed add/replace changes keep correct reviewed values and stable preview identities',
    () async {
      final session = service.agent.openSession('合成聊天');
      final item = await service.owner.createInformation('合成资料', '', [
        const core.FieldInput('替换目标', '', '旧值'),
        const core.FieldInput('保持字段', '', '保持值'),
      ]);
      final id = await service.agent.submitUpdate(
        session,
        core.UpdateInput(item.id, item.version, [
          const core.FieldChange.add(core.FieldInput('新增字段', '', '新增值')),
          core.FieldChange.replace(
            item.fields.first.id,
            const core.FieldInput('新含义', '', '替换值'),
          ),
        ]),
      );
      final d = await source.read(id), again = await source.read(id);
      expect(d.reviewToken, again.reviewToken);
      expect(d.snapshotDigest, again.snapshotDigest);
      expect(d.items.single.changes.map((c) => c.label), ['新增字段', '新含义']);
      final original = d.items.single,
          values = Map<String, Object?>.of(original.proposed.values);
      for (final c in original.changes) {
        values[c.key] = '核对${c.label}';
      }
      final preservedKey = original.proposed.fieldIds.entries
          .singleWhere((e) => e.value == item.fields.last.id)
          .key;
      values[preservedKey] = '主人同时核对保持字段';
      final review = WorkspaceProposalItemReview(
        itemId: original.id,
        name: original.proposed.record.name,
        description: original.proposed.record.description,
        values: values,
      );
      final command = decision(d, reviewed: [review]);
      final receipt = await source.change(command);
      WorkspaceProposalExpectation(d).check(command, receipt);
      final saved = service.owner.information.single;
      expect(saved.fields.map((f) => '${f.name}:${f.value}').toSet(), {
        '新含义:核对新含义',
        '新增字段:核对新增字段',
        '保持字段:主人同时核对保持字段',
      });
      expect(saved.fields.any((f) => f.id == item.fields.first.id), isFalse);
      expect(saved.fields.any((f) => f.id == item.fields.last.id), isTrue);
    },
  );
  test(
    'stale modification can be compared and rejected, never overwrites owner edits',
    () async {
      final session = service.agent.openSession('合成聊天');
      final item = await service.owner.createInformation('合成资料', '', [
        const core.FieldInput('字段', '', '原值'),
      ]);
      final id = await service.agent.submitUpdate(
        session,
        core.UpdateInput(item.id, 1, [
          core.FieldChange.correct(item.fields.single.id, 'AI值'),
        ]),
      );
      final d = await source.read(id), command = decision(d);
      await service.owner.correctValue(
        core.FieldRef(item.id, item.fields.single.id),
        '主人新值',
      );
      await expectLater(
        source.change(command),
        throwsA(
          isA<WorkspaceFailure>().having((e) => e.code, 'code', 'conflict'),
        ),
      );
      final conflict = await source.read(id);
      expect(conflict.summary.status, WorkspaceProposalStatus.conflicted);
      expect(conflict.canConfirm, isFalse);
      expect((await source.currentTarget(id)).values.values, contains('主人新值'));
      await source.change(decision(conflict, confirm: false));
      expect(service.owner.information.single.fields.single.value, '主人新值');
    },
  );
  test(
    'delete decision uses actual recycle and exact pre-delete snapshot',
    () async {
      final session = service.agent.openSession('合成聊天');
      final item = await service.owner.createInformation('合成资料', '', [
        const core.FieldInput('字段', '', '原值'),
      ]);
      final id = await service.agent.submitDelete(session, item.id, 1);
      final d = await source.read(id), command = decision(d);
      final receipt = await source.change(command);
      WorkspaceProposalExpectation(d).check(command, receipt);
      expect(service.owner.information, isEmpty);
      expect(receipt.records.single.entryId, isNotEmpty);
      final done = await source.read(id);
      expect(done.targets.single.version, 1);
      final archive = await source.snapshot(id, done.targets.single.record);
      expect(archive.detail.values.values, contains('原值'));
    },
  );
  test(
    'legacy organization review and current agent-applied result use actual classifications only',
    () async {
      final session = service.agent.openSession('合成整理聊天');
      final item = await service.owner.createInformation('合成整理资料', '', [
        const core.FieldInput('字段', '', '不属于整理范围的正文'),
      ]);
      final task = await service.agent.requestOrganization(session, '整理合成分类', [
        item.id,
      ]);
      // Retained legacy task: newer requests are approved with autoApply=true.
      await repo.saveOrganizationTask(
        task.withState(
          core.OrganizationTaskState.active,
          autoApply: false,
          approvedAt: DateTime.now().toUtc(),
          itemNames: {item.id: item.name},
        ),
      );
      await service.agent.submitOrganization(session, task.id, [
        core.OrganizationChange(
          itemId: item.id,
          baseVersion: 1,
          directoryName: '合成整理目录',
          tagNames: ['合成整理标签'],
        ),
      ]);
      final d = await source.read(task.id);
      expect(d.canConfirm, isTrue);
      expect(d.organization!.legacyReview, isTrue);
      expect(d.items.single.proposed.values, isEmpty);
      final command = decision(d);
      final receipt = await source.change(command);
      expect(receipt.records.single.version, 2);
      expect(
        service.owner.information.single.fields.single.value,
        '不属于整理范围的正文',
      );
      expect(
        (await source.read(task.id)).organization!.outcome,
        WorkspaceOrganizationOutcome.applied,
      );
      final next = await service.agent.requestOrganization(session, '整理合成标签', [
        item.id,
      ]);
      await service.owner.approveOrganization(next.id, [item.id]);
      await service.agent.submitOrganization(session, next.id, [
        core.OrganizationChange(
          itemId: item.id,
          baseVersion: 2,
          directoryId: service.owner.directories.single.id,
          tagNames: ['第二合成标签'],
        ),
      ]);
      final applied = await source.read(next.id);
      expect(applied.items, isEmpty);
      expect(
        applied.organization!.outcome,
        WorkspaceOrganizationOutcome.applied,
      );
      expect(applied.organization!.members.single.resultVersion, 3);
      await close();
      await open();
      expect(
        (await source.read(task.id)).organization!.outcome,
        WorkspaceOrganizationOutcome.applied,
      );
      expect(command.proposalId, task.id);
    },
  );
}
