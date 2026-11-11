import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/owner_agent_templates.dart';
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
    'submitted import title is searched and shown before and after admission and reopen',
    () async {
      final session = service.agent.openSession('合成标题聊天');
      final id = await service.agent.submitImport(
        session,
        [
          core.ImportItemInput('资料甲', '', [
            const core.FieldInput('正文', '', '合成内容'),
          ]),
        ],
        title: '新增 NAS 应用信息',
        agentName: 'Synthetic Agent',
        purpose: '补齐应用清单',
      );
      var detail = await source.read(id);
      expect(detail.summary.title, '新增 NAS 应用信息');
      expect(detail.summary.agentClaim, 'Synthetic Agent');
      expect(
        (await source.query(
          const WorkspaceProposalQuery(keyword: 'NAS'),
        )).items.single.id,
        id,
      );
      await source.change(decision(detail));
      await close();
      await open();
      detail = await source.read(id);
      expect(detail.summary.title, '新增 NAS 应用信息');
      expect(detail.summary.pending, false);
      expect(detail.summary.agentClaim, 'Synthetic Agent');
    },
  );
  test(
    'proposed directory levels reuse existing parents and save once for the whole proposal',
    () async {
      final parent = await service.owner.createDirectory('账号与服务');
      final session = service.agent.openSession('合成目录提案');
      final id = await service.agent.submitImport(session, [
        for (final name in ['A', 'B'])
          core.ImportItemInput(name, '', [
            const core.FieldInput('用途', '', '合成内容'),
          ], suggestedDirectory: '账号与服务 / 应用 / VPN'),
      ]);
      final detail = await source.read(id), catalog = await source.catalog();
      final proposed = catalog.directories.where((d) => d.proposed).toList();
      expect(proposed.map((d) => d.name), ['应用', 'VPN']);
      expect(proposed.first.parentId, parent.id);
      expect(proposed.last.parentId, proposed.first.id);
      expect(
        detail.items.every(
          (i) => i.proposed.record.directoryId == proposed.last.id,
        ),
        true,
      );
      expect(service.owner.directories.length, 1);
      await source.change(decision(detail));
      expect(service.owner.directories.length, 3);
      expect(
        service.owner.information.map((i) => i.directoryId).toSet().length,
        1,
      );
      expect(
        service.owner.directories.singleWhere((d) => d.name == 'VPN').id,
        service.owner.information.first.directoryId,
      );
    },
  );

  test(
    'edited proposed paths admit information and credentials together and retain actual receipt paths',
    () async {
      service.owner.configureInformationTemplates(
        () => currentAgentTemplates(service.owner),
      );
      final parent = await service.owner.createDirectory('账号与服务');
      final session = service.agent.openSession('合成目录与密码');
      final template = currentAgentTemplates(
        service.owner,
      ).templates.singleWhere((t) => t.id == 'credential.accountPassword');
      final id = await service.agent.submitImport(session, [
        core.ImportItemInput(
          '说明',
          '',
          [const core.FieldInput('正文', '', '合成正文')],
          key: 'note',
          suggestedDirectory: '旧建议',
        ),
        core.ImportItemInput(
          '密码',
          '',
          [],
          key: 'password',
          templateId: template.id,
          templateVersion: template.version,
          templateDigest: template.digest,
          credential: core.CredentialImportInput.owner(),
        ),
      ]);
      final initial = await source.read(id);
      await service.owner.fillImportCredential(
        id,
        initial.summary.version,
        'password',
        'SYNTHETIC-ONLY',
      );
      final detail = await source.read(id);
      final reviews = [
        for (final item in detail.items)
          (() {
            final r = WorkspaceProposalItemReview.fromItem(item);
            return WorkspaceProposalItemReview(
              itemId: r.itemId,
              name: r.name,
              description: r.description,
              values: r.values,
              relations: r.relations,
              tagIds: r.tagIds,
              suggestedDirectory: '账号与服务 / 应用 / VPN',
            );
          })(),
      ];
      expect(service.owner.directories, hasLength(1));
      expect(service.owner.information, isEmpty);
      expect(service.owner.credentials, isEmpty);
      await source.change(decision(detail, reviewed: reviews));
      expect(service.owner.directories, hasLength(3));
      expect(service.owner.directories.any((d) => d.name == '旧建议'), false);
      final vpn = service.owner.directories.singleWhere((d) => d.name == 'VPN');
      expect(service.owner.information.single.directoryId, vpn.id);
      expect(service.owner.credentials.single.directoryId, vpn.id);
      expect(
        service.owner.directories.singleWhere((d) => d.name == '应用').parentId,
        parent.id,
      );
      final status = service.agent.importStatus(session, id);
      final expectedLocation = {
        'directoryId': vpn.id,
        'path': ['账号与服务', '应用', 'VPN'],
      };
      expect(
        (status['items'] as List).map((i) => (i as Map)['savedLocation']),
        everyElement(expectedLocation),
      );
      await service.owner.updateDirectory(
        vpn.id,
        '已改名',
        parentId: vpn.parentId,
      );
      expect(
        (service.agent.importStatus(session, id)['items'] as List)
            .first['savedLocation'],
        expectedLocation,
      );
      await close();
      await open();
      expect(
        service.owner.importProposals.single.admissionDirectories.values.map(
          (r) => r.toJson(),
        ),
        everyElement(expectedLocation),
      );
    },
  );

  test(
    'rejecting a proposal with new directory suggestions creates nothing',
    () async {
      final session = service.agent.openSession('合成取消');
      final id = await service.agent.submitImport(session, [
        core.ImportItemInput('A', '', [
          const core.FieldInput('正文', '', '合成正文'),
        ], suggestedDirectory: '未创建/子目录'),
      ]);
      final detail = await source.read(id);
      expect(
        (await source.catalog()).directories.where((d) => d.proposed),
        hasLength(2),
      );
      await source.change(decision(detail, confirm: false));
      expect(service.owner.directories, isEmpty);
      expect(service.owner.information, isEmpty);
    },
  );

  test('a directory changed after review requires a fresh decision', () async {
    final directory = await service.owner.createDirectory('原目录');
    final session = service.agent.openSession('合成目录变化');
    final id = await service.agent.submitImport(session, [
      core.ImportItemInput('A', '', [
        const core.FieldInput('用途', '', '合成内容'),
      ], directoryId: directory.id),
    ]);
    final detail = await source.read(id);
    await service.owner.updateDirectory(directory.id, '新名称');
    await expectLater(
      source.change(decision(detail)),
      throwsA(isA<WorkspaceFailure>()),
    );
    expect(service.owner.information, isEmpty);
    final current = await source.read(id);
    expect(current.reviewToken, isNot(detail.reviewToken));
    await source.change(decision(current));
    expect(service.owner.information.single.directoryId, directory.id);
  });

  test(
    'an owner-edited relation previews the new target without saving or opening the library',
    () async {
      service.owner.configureInformationTemplates(
        () => currentAgentTemplates(service.owner),
      );
      final session = service.agent.openSession('合成关联预览');
      Map<String, dynamic> example(String template) {
        final value =
            service.agent.readInformationTemplate(template)['template'] as Map;
        return Map<String, dynamic>.from(
          ((value['submissionExample'] as Map)['items'] as List).first as Map,
        );
      }

      final servers = await service.agent.submitImport(session, [
        for (final entry in [
          (key: 'server-a', name: '合成服务器A'),
          (key: 'server-b', name: '合成服务器B'),
        ])
          core.ImportItemInput.fromJson({
            ...example('server'),
            'key': entry.key,
            'name': entry.name,
          }),
      ]);
      await source.change(decision(await source.read(servers)));
      final refs = (await source.read(
        servers,
      )).targets.map((t) => t.record).toList();
      final id = await service.agent.submitImport(session, [
        core.ImportItemInput.fromJson({
          ...example('service'),
          'relations': {
            'hostedOn': [
              {'kind': 'information', 'id': refs.first.id},
            ],
          },
        }),
      ]);
      final proposal = await source.read(id),
          item = (await source.read(id)).items.single;
      await expectLater(
        source.previewRelated(id, proposal.summary.version, refs.last),
        throwsA(isA<WorkspaceFailure>()),
      );
      final original = WorkspaceProposalItemReview.fromItem(item);
      final edited = WorkspaceProposalItemReview(
        itemId: item.id,
        name: original.name,
        description: original.description,
        directoryId: original.directoryId,
        tagIds: original.tagIds,
        values: original.values,
        relations: {
          'hostedOn': [refs.last],
        },
      );
      final preview = await source.previewRelated(
        id,
        proposal.summary.version,
        refs.last,
        review: edited,
      );
      expect(preview.proposed.record.name, '合成服务器B');
      expect(
        (await source.read(id)).items.single.proposed.relations['hostedOn'],
        [refs.first],
      );
      expect(service.owner.information, hasLength(2));
      await expectLater(
        source.previewRelated(
          id,
          proposal.summary.version + 1,
          refs.last,
          review: edited,
        ),
        throwsA(isA<WorkspaceFailure>()),
      );
    },
  );
  test(
    'nested suggestions reuse the existing directory in the real approval adapter',
    () async {
      final parent = await service.owner.createDirectory('Personal');
      final child = await service.owner.createDirectory(
        'Career',
        parentId: parent.id,
      );
      final session = service.agent.openSession('nested intake');
      final id = await service.agent.submitImport(session, [
        core.ImportItemInput('profile', '', [
          const core.FieldInput('body', '', 'value'),
        ], suggestedDirectory: ' personal / Career '),
      ]);
      final detail = await source.read(id);
      expect(detail.items.single.proposed.record.directoryId, child.id);
      await source.change(decision(detail));
      expect(service.owner.directories, hasLength(2));
      expect(service.owner.information.single.directoryId, child.id);
    },
  );
  test(
    'real addition review, whole proposal and suggested classification persist without terminal bodies',
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
      expect(
        catalog.directories.any((d) => d.name == '合成新目录' && d.proposed),
        isTrue,
      );
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
      await expectLater(
        source.change(decision(d, reviewed: [edit])),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'proposal_incomplete',
          ),
        ),
      );
      expect(service.owner.information, isEmpty);
      final command = decision(
        d,
        reviewed: [edit, WorkspaceProposalItemReview.fromItem(d.items.last)],
      );
      final receipt = await source.change(command);
      WorkspaceProposalExpectation(d).check(command, receipt);
      expect(service.owner.information.length, 2);
      expect(service.owner.information.first.name, '主人核对名称');
      expect(service.owner.information.first.fields.single.value, '主人核对正文');
      expect(service.owner.directories.single.name, '合成新目录');
      expect(service.owner.tags.single.name, '合成新标签');
      expect(service.owner.importProposals.single.items, isEmpty);
      expect((await source.read(id)).items, isEmpty);
      expect((await source.read(id)).targets.length, 2);
      final archive = await source.snapshot(id, receipt.records.first.ref);
      expect(archive.detail.record.name, '主人核对名称');
      await close();
      await open();
      expect(
        (await source.receipt(command.operationId))!.records.first.ref,
        receipt.records.first.ref,
      );
      expect((await source.change(command)).commandDigest, command.digest);
      expect(service.owner.information.length, 2);
    },
  );
  test(
    'agent metadata changes remain reviewable and owner edits persist with the field correction',
    () async {
      final destination = await service.owner.createDirectory('新位置');
      final session = service.agent.openSession('合成聊天');
      final item = await service.owner.createInformation('旧名称', '旧用途', [
        const core.FieldInput('步骤', '', '旧步骤'),
      ]);
      final id = await service.agent.submitUpdate(
        session,
        core.UpdateInput(
          item.id,
          item.version,
          [core.FieldChange.correct(item.fields.single.id, '新步骤')],
          name: 'AI 名称',
          description: 'AI 用途',
        ),
      );
      final d = await source.read(id), change = d.items.single;
      expect(change.before!.record.description, '旧用途');
      expect(change.proposed.record.name, 'AI 名称');
      expect(change.proposed.record.description, 'AI 用途');
      final proposed = WorkspaceProposalItemReview.fromItem(change);
      await source.change(
        decision(
          d,
          reviewed: [
            WorkspaceProposalItemReview(
              itemId: proposed.itemId,
              name: '主人核对名称',
              description: '主人核对用途',
              values: proposed.values,
              directoryId: destination.id,
              tagIds: proposed.tagIds,
              relations: proposed.relations,
            ),
          ],
        ),
      );
      final saved = service.owner.information.single;
      expect(saved.name, '主人核对名称');
      expect(saved.description, '主人核对用途');
      expect(saved.directoryId, destination.id);
      expect(saved.fields.single.value, '新步骤');
      expect(saved.fields.single.id, item.fields.single.id);
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
