import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'suggested organization is reused and committed once with the reviewed import',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final existing = await service.owner.createTag('常用');
      final session = service.agent.openSession('Import chat');
      final inputs = [
        for (final n in ['A', 'B'])
          ImportItemInput(
            n,
            '公开说明',
            [const FieldInput('地址', '', 'secret.invalid')],
            suggestedDirectory: '服务入口',
            suggestedTags: ['常用', '服务'],
          ),
      ];
      final id = await service.agent.submitImport(
        session,
        inputs,
        agentName: 'Codex',
        purpose: '整理指定的入口',
      );
      expect(service.owner.directories, isEmpty);
      final receipt = await service.owner.confirmImport(id, 1, inputs);
      expect(service.owner.directories, hasLength(1));
      expect(service.owner.tags, hasLength(2));
      expect(service.owner.information.map((i) => i.directoryId).toSet(), {
        service.owner.directories.single.id,
      });
      expect(
        service.owner.information.every((i) => i.tagIds.contains(existing.id)),
        isTrue,
      );
      await service.owner.confirmImport(id, 1, inputs);
      expect(service.owner.information, hasLength(receipt.length));
      expect(service.owner.directories, hasLength(1));
      final proposal = service.owner.importProposals.single;
      expect(proposal.agentName, 'Codex');
      expect(proposal.purpose, '整理指定的入口');
      expect(proposal.fieldCount, 2);
      expect(proposal.itemNames, ['A', 'B']);
      expect(ImportProposal.fromJson(proposal.toJson()).itemNames, ['A', 'B']);
      expect(jsonEncode(proposal.toJson()), isNot(contains('secret.invalid')));
      final rejectedId = await service.agent.submitImport(session, [
        ImportItemInput('Not imported', '', [
          const FieldInput('Value', '', 'NEVER-RETAIN-REJECTED-VALUE'),
        ]),
      ]);
      await service.owner.rejectImport(rejectedId, 1);
      final rejected = service.owner.importProposals.last;
      expect(rejected.itemNames, ['Not imported']);
      expect(rejected.items, isEmpty);
      expect(
        jsonEncode(rejected.toJson()),
        isNot(contains('NEVER-RETAIN-REJECTED-VALUE')),
      );
    },
  );
  test(
    'only the selected session receives scoped metadata; reviewed organization preserves values and grants',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      await service.owner.createDirectory('仅本人目录名称');
      final item = await service.owner.createInformation('笔记入口', '公开描述', [
        const FieldInput('地址', '', 'PRIVATE-VALUE'),
      ]);
      await service.owner.createInformation('范围外资料', '', [
        const FieldInput('值', '', 'OTHER-VALUE'),
      ]);
      final session = service.agent.openSession('Organizer');
      final other = service.agent.openSession('Other');
      final ref = FieldRef(item.id, item.fields.single.id);
      final request = service.agent.request(session, 'read', [ref]);
      service.owner.approve(request.id, [ref]);
      final token = service.agent.claim(session, request.id).token;
      final selected = service.owner.organizationAgents.firstWhere(
        (a) => a.chatLabel == 'Organizer',
      );
      final task = await service.owner.startOrganizationTask(selected.id, [
        item.id,
      ]);
      expect(service.agent.catalog().toString(), isNot(contains('仅本人目录名称')));
      expect(service.agent.organizationTasks(other), isEmpty);
      await expectLater(
        service.agent.organizationMetadata(other, task.id),
        throwsA(isA<AccessFailure>()),
      );
      final metadata = await service.agent.organizationMetadata(
        session,
        task.id,
      );
      expect((metadata['items'] as List), hasLength(1));
      expect(jsonEncode(metadata), contains('仅本人目录名称'));
      for (final value in [
        'PRIVATE-VALUE',
        'OTHER-VALUE',
        '范围外资料',
        'sessionSecret',
        'token',
      ]) {
        expect(jsonEncode(metadata), isNot(contains(value)));
      }
      await service.agent.submitOrganization(session, task.id, [
        OrganizationChange(
          itemId: item.id,
          baseVersion: 1,
          directoryName: '服务入口',
          tagNames: ['笔记'],
        ),
      ]);
      expect(service.owner.information.first.directoryId, isNull);
      await expectLater(
        service.agent.organizationMetadata(session, task.id),
        throwsA(isA<AccessFailure>()),
      );
      await service.owner.confirmOrganization(task.id);
      expect(service.owner.information.first.directoryId, isNotNull);
      expect(
        service.owner.information.first.fields.single.value,
        'PRIVATE-VALUE',
      );
      expect(await service.agent.read(token, ref), 'PRIVATE-VALUE');
      await service.owner.confirmOrganization(task.id);
      expect(service.owner.information.first.version, 2);
    },
  );
  test(
    'cancellation, session end, restart and observed expiry cannot revive metadata access',
    () async {
      var now = DateTime.utc(2026, 10, 16);
      final repo = MemoryInformationRepository();
      final service = InformationService(repository: repo, clock: () => now);
      final item = await service.owner.createInformation('Item', '', [
        const FieldInput('Value', '', 'private'),
      ]);
      final session = service.agent.openSession('A');
      final binding = service.owner.organizationAgents.single.id;
      final cancelled = await service.owner.startOrganizationTask(binding, [
        item.id,
      ]);
      await service.owner.cancelOrganization(cancelled.id);
      await expectLater(
        service.agent.organizationMetadata(session, cancelled.id),
        throwsA(isA<AccessFailure>()),
      );
      final expired = await service.owner.startOrganizationTask(binding, [
        item.id,
      ]);
      now = now.add(const Duration(minutes: 31));
      expect(
        service.agent.organizationTasks(session).last['status'],
        'expired',
      );
      now = now.subtract(const Duration(hours: 1));
      await expectLater(
        service.agent.organizationMetadata(session, expired.id),
        throwsA(isA<AccessFailure>()),
      );
      final ended = await service.owner.startOrganizationTask(binding, [
        item.id,
      ]);
      service.agent.endSession(session);
      await expectLater(
        service.agent.organizationMetadata(session, ended.id),
        throwsA(isA<AccessFailure>()),
      );
      await service.close();
      final reopened = InformationService(repository: repo);
      addTearDown(reopened.close);
      final fresh = reopened.agent.openSession('A');
      expect(reopened.agent.organizationTasks(fresh), isEmpty);
      await expectLater(
        reopened.agent.organizationMetadata(fresh, ended.id),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
  test(
    'a conflicting batch changes no items and publishes no new labels',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final items = [
        for (final n in ['A', 'B'])
          await service.owner.createInformation(n, '', [
            const FieldInput('Value', '', 'private'),
          ]),
      ];
      final session = service.agent.openSession('A');
      final task = await service.owner.startOrganizationTask(
        service.owner.organizationAgents.single.id,
        items.map((i) => i.id).toList(),
      );
      await service.agent.submitOrganization(session, task.id, [
        for (final i in items)
          OrganizationChange(
            itemId: i.id,
            baseVersion: i.version,
            directoryName: 'New label',
          ),
      ]);
      await service.owner.correctValue(
        FieldRef(items.last.id, items.last.fields.single.id),
        'changed',
      );
      await expectLater(
        service.owner.confirmOrganization(task.id),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.owner.directories, isEmpty);
      expect(
        service.owner.information.every((i) => i.directoryId == null),
        isTrue,
      );
      expect(
        service.owner.organizationTasks.single.state,
        OrganizationTaskState.conflicted,
      );
    },
  );
  test(
    'out-of-scope and duplicate organization changes are rejected before publishing labels',
    () async {
      final service = InformationService.fictional();
      addTearDown(service.close);
      final session = service.agent.openSession('A');
      final task = await service.owner.startOrganizationTask(
        service.owner.organizationAgents.single.id,
        ['demo-server'],
      );
      await expectLater(
        service.agent.submitOrganization(session, task.id, [
          OrganizationChange(
            itemId: 'unselected',
            baseVersion: 1,
            directoryName: 'bad',
          ),
        ]),
        throwsA(isA<AccessFailure>()),
      );
      final c = OrganizationChange(
        itemId: 'demo-server',
        baseVersion: 1,
        directoryName: 'New',
      );
      await expectLater(
        service.agent.submitOrganization(session, task.id, [c, c]),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.owner.directories, isEmpty);
      expect(
        service.owner.organizationTasks.single.state,
        OrganizationTaskState.active,
      );
    },
  );
}
