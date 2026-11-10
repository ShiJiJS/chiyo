import 'dart:async';
import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class _DelayedOrganizationRepository extends MemoryInformationRepository {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> confirmOrganizationTask(
    OrganizationTask task,
    List<InformationItem> items,
    List<InformationRevision> previous, {
    List<InformationDirectory> newDirectories = const [],
    List<InformationTag> newTags = const [],
    void Function()? validate,
  }) async {
    entered.complete();
    await release.future;
    await super.confirmOrganizationTask(
      task,
      items,
      previous,
      newDirectories: newDirectories,
      newTags: newTags,
      validate: validate,
    );
  }
}

void main() {
  test(
    'organization lifetime follows the chosen deadline and rejects invalid decisions atomically',
    () async {
      var now = DateTime.utc(2026, 10, 17);
      final service = InformationService.fictional(clock: () => now);
      addTearDown(service.close);
      final session = service.agent.openSession('Organizer');
      final task = await service.agent.requestOrganization(session, '分类整理', [
        'demo-server',
      ]);
      for (final invalid in [
        Duration.zero,
        const Duration(seconds: -1),
        const Duration(minutes: 31),
      ]) {
        await expectLater(
          service.owner.approveOrganization(task.id, [
            'demo-server',
          ], lifetime: invalid),
          throwsA(
            isA<AccessFailure>().having(
              (e) => e.status,
              'status',
              'invalid_duration',
            ),
          ),
        );
        expect(
          service.agent.organizationStatus(session, task.id)['status'],
          'pending',
        );
      }
      await service.owner.approveOrganization(task.id, [
        'demo-server',
      ], lifetime: const Duration(minutes: 15));
      expect(
        service.owner.organizationTasks.single.expiresAt,
        now.add(const Duration(minutes: 15)),
      );
      expect(
        (await service.agent.organizationMetadata(session, task.id))['items'],
        hasLength(1),
      );
      final other = await service.agent.requestOrganization(session, '默认期限', [
        'demo-server',
      ]);
      await service.owner.approveOrganization(other.id, ['demo-server']);
      expect(
        service.owner.organizationTasks.last.expiresAt,
        now.add(const Duration(hours: 2)),
      );
      now = now.add(const Duration(minutes: 15));
      expect(
        service.agent.organizationStatus(session, task.id)['status'],
        'expired',
      );
      await expectLater(
        service.agent.organizationMetadata(session, task.id),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        service.agent.organizationStatus(session, other.id)['status'],
        'active',
      );
    },
  );
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
      final task = await service.agent.requestOrganization(session, '整理分类', [
        item.id,
      ], agentName: 'Codex');
      await expectLater(
        service.agent.organizationMetadata(session, task.id),
        throwsA(isA<AccessFailure>()),
      );
      await service.owner.approveOrganization(task.id, [item.id]);
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
      expect(service.owner.information.first.directoryId, isNotNull);
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
      final cancelled = await service.agent.requestOrganization(
        session,
        '整理分类',
        [item.id],
      );
      await service.owner.approveOrganization(cancelled.id, [item.id]);
      await service.owner.cancelOrganization(cancelled.id);
      await expectLater(
        service.agent.organizationMetadata(session, cancelled.id),
        throwsA(isA<AccessFailure>()),
      );
      final expired = await service.agent.requestOrganization(session, '整理分类', [
        item.id,
      ]);
      now = now.add(const Duration(minutes: 121));
      expect(
        service.agent.organizationTasks(session).last['status'],
        'expired',
      );
      now = now.subtract(const Duration(hours: 1));
      await expectLater(
        service.agent.organizationMetadata(session, expired.id),
        throwsA(isA<AccessFailure>()),
      );
      final ended = await service.agent.requestOrganization(session, '整理分类', [
        item.id,
      ]);
      await service.owner.approveOrganization(ended.id, [item.id]);
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
      final task = await service.agent.requestOrganization(
        session,
        '整理分类',
        items.map((i) => i.id).toList(),
      );
      await service.owner.approveOrganization(
        task.id,
        items.map((i) => i.id).toList(),
      );
      await service.owner.correctValue(
        FieldRef(items.last.id, items.last.fields.single.id),
        'changed',
      );
      await expectLater(
        service.agent.submitOrganization(session, task.id, [
          for (final i in items.take(1))
            OrganizationChange(
              itemId: i.id,
              baseVersion: i.version,
              directoryName: 'New label',
            ),
        ]),
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
      final task = await service.agent.requestOrganization(session, '整理分类', [
        'demo-server',
      ]);
      await service.owner.approveOrganization(task.id, ['demo-server']);
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
  test(
    'request waits for owner, partial approval limits reads and automatic writes, then cannot renew',
    () async {
      final service = InformationService.fictional();
      addTearDown(service.close);
      final other = await service.owner.createInformation('Outside', '', [
        const FieldInput('V', '', 'PRIVATE'),
      ]);
      final session = service.agent.openSession('Codex');
      final request = await service.agent.requestOrganization(session, '整理资料', [
        'demo-server',
        other.id,
      ]);
      expect(
        service.agent.organizationStatus(session, request.id)['status'],
        'pending',
      );
      await expectLater(
        service.agent.submitOrganization(session, request.id, [
          OrganizationChange(
            itemId: 'demo-server',
            baseVersion: 1,
            directoryName: 'Before approval',
          ),
        ]),
        throwsA(isA<AccessFailure>()),
      );
      await service.owner.approveOrganization(request.id, ['demo-server']);
      final deadline = service.owner.organizationTasks.single.expiresAt;
      final metadata = await service.agent.organizationMetadata(
        session,
        request.id,
      );
      expect((metadata['items'] as List).length, 1);
      await expectLater(
        service.agent.submitOrganization(session, request.id, [
          OrganizationChange(
            itemId: other.id,
            baseVersion: 1,
            directoryName: 'Forbidden',
          ),
        ]),
        throwsA(isA<AccessFailure>()),
      );
      await service.agent.submitOrganization(session, request.id, [
        OrganizationChange(
          itemId: 'demo-server',
          baseVersion: 1,
          directoryName: 'Servers',
        ),
      ]);
      expect(
        service.agent.organizationStatus(session, request.id)['status'],
        'confirmed',
      );
      expect(service.owner.information.first.version, 2);
      expect(service.owner.information.last.directoryId, isNull);
      expect(service.owner.organizationTasks.single.expiresAt, deadline);
      await expectLater(
        service.owner.approveOrganization(request.id, ['demo-server']),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        service.agent.submitOrganization(session, request.id, [
          OrganizationChange(
            itemId: 'demo-server',
            baseVersion: 1,
            directoryName: 'Again',
          ),
        ]),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.owner.information.first.version, 2);
    },
  );
  test(
    'denied and expired pending organization requests never authorize metadata or writes',
    () async {
      var now = DateTime.utc(2026, 10, 16);
      final service = InformationService(
        repository: MemoryInformationRepository(),
        clock: () => now,
      );
      addTearDown(service.close);
      final item = await service.owner.createInformation('Info', '', [
        const FieldInput('V', '', 'private'),
      ]);
      final session = service.agent.openSession('Codex');
      final denied = await service.agent.requestOrganization(session, '整理分类', [
        item.id,
      ]);
      await service.owner.denyOrganization(denied.id);
      await expectLater(
        service.owner.approveOrganization(denied.id, [item.id]),
        throwsA(isA<AccessFailure>()),
      );
      final expired = await service.agent.requestOrganization(session, '整理分类', [
        item.id,
      ]);
      now = now.add(const Duration(minutes: 121));
      expect(
        service.agent.organizationStatus(session, expired.id)['status'],
        'expired',
      );
      now = now.subtract(const Duration(hours: 1));
      await expectLater(
        service.owner.approveOrganization(expired.id, [item.id]),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        service.agent.organizationMetadata(session, denied.id),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.owner.directories, isEmpty);
    },
  );
  test(
    'session end or expiry while automatic write waits prevents committing labels or information',
    () async {
      for (final expire in [false, true]) {
        var now = DateTime.utc(2026, 10, 16);
        final repo = _DelayedOrganizationRepository();
        final service = InformationService(repository: repo, clock: () => now);
        final item = await service.owner.createInformation('Info', '', [
          const FieldInput('V', '', 'private'),
        ]);
        final session = service.agent.openSession('Codex');
        final request = await service.agent.requestOrganization(
          session,
          '整理分类',
          [item.id],
        );
        await service.owner.approveOrganization(request.id, [item.id]);
        final saving = service.agent.submitOrganization(session, request.id, [
          OrganizationChange(
            itemId: item.id,
            baseVersion: 1,
            directoryName: 'Must not appear',
          ),
        ]);
        final denied = expectLater(saving, throwsA(isA<AccessFailure>()));
        await repo.entered.future;
        if (expire) {
          now = now.add(const Duration(minutes: 121));
        } else {
          service.agent.endSession(session);
        }
        repo.release.complete();
        await denied;
        expect(service.owner.directories, isEmpty);
        expect(service.owner.information.single.version, 1);
        expect(service.owner.informationRevisions, isEmpty);
        await service.close();
      }
    },
  );
  test(
    'an approved organization with no changes completes without rewriting information or history',
    () async {
      final service = InformationService.fictional();
      addTearDown(service.close);
      final session = service.agent.openSession('Codex');
      final request = await service.agent.requestOrganization(session, '检查分类', [
        'demo-server',
      ]);
      await service.owner.approveOrganization(request.id, ['demo-server']);
      await service.agent.submitOrganization(session, request.id, []);
      expect(
        service.agent.organizationStatus(session, request.id)['status'],
        'confirmed',
      );
      expect(service.owner.information.single.version, 1);
      expect(service.owner.informationRevisions, isEmpty);
      await expectLater(
        service.agent.organizationMetadata(session, request.id),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
}
