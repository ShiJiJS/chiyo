import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_agent_templates.dart';
import 'package:info_desktop/workspace/owner_workspace_proposals.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_information_codec.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late AgentServer server;
  late AgentClient cli;
  late OwnerWorkspaceSource library;
  late OwnerWorkspaceProposals proposals;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(repository: repo);
    service.owner.configureInformationTemplates(
      () => currentAgentTemplates(service.owner),
    );
    server = await AgentServer.start(service.agent, port: 0);
    cli = AgentClient(server.port);
    proposals = OwnerWorkspaceProposals(
      owner: service.owner,
      library: () => library,
      changed: () => library.notifyExternalChange(),
    );
    library = OwnerWorkspaceSource(
      owner: service.owner,
      proposals: proposals,
      refreshInterval: Duration.zero,
    );
    expect(
      (await cli.execute({
        'command': 'session',
        'chatLabel': '模板录入测试',
      }))['status'],
      'ok',
    );
  }

  Future<void> close() async {
    cli.close();
    await server.close();
    await library.dispose();
    await service.close();
    await repo.close();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('template-import-');
    keys = _Keys();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  Future<Map<String, dynamic>> example(String templateId) async {
    final response = await cli.execute({
      'command': 'template-read',
      'templateId': templateId,
    });
    return Map<String, dynamic>.from(
      (response['template'] as Map)['submissionExample'] as Map,
    );
  }

  Future<WorkspaceProposalReceipt> approve(
    WorkspaceProposalDetail detail, {
    List<WorkspaceProposalItemReview>? reviewed,
  }) => proposals.change(
    WorkspaceProposalChange(
      operationId: workspaceOperationId(),
      proposalId: detail.summary.id,
      version: detail.summary.version,
      reviewToken: detail.reviewToken,
      action: WorkspaceProposalAction.confirm,
      reviewed:
          reviewed ??
          detail.items.map(WorkspaceProposalItemReview.fromItem).toList(),
    ),
  );
  test(
    'queried examples survive encrypted pending storage, actual review, admission and reopen as typed records',
    () async {
      final templates =
          (await cli.execute({'command': 'template-list'}))['templates']
              as List;
      final ids = <String>[];
      for (final template in templates.where(
        (t) => t['id'] != 'file' && t['recordKind'] == 'information',
      )) {
        final response = await cli.execute(
          await example(template['id'] as String),
        );
        expect(response['status'], 'pending', reason: template['id'] as String);
        ids.add(response['proposalId'] as String);
      }
      final snapshots = {
        for (final id in ids) id: (await proposals.read(id)).reviewToken,
      };
      expect(service.owner.information, isEmpty);
      await close();
      await open();
      for (final id in ids) {
        final detail = await proposals.read(id);
        expect(detail.reviewToken, snapshots[id]);
        final proposed = detail.items.single.proposed;
        expect(proposed.record.type.id, isNot('unknown'));
        final receipt = await approve(detail);
        final saved = service.owner.information.singleWhere(
          (i) => i.id == receipt.records.single.ref.id,
        );
        expect(saved.layout!.typeId, proposed.record.type.id);
        expect(
          saved.fields.map((f) => f.value),
          containsAll(proposed.values.values.whereType<String>()),
        );
        final decoded = WorkspaceInformationCodec().decode(
          saved,
          tagNames: const {},
        );
        expect(
          (
            decoded.record.type.id,
            decoded.record.type.name,
            decoded.record.type.icon,
          ),
          (
            proposed.record.type.id,
            proposed.record.type.name,
            proposed.record.type.icon,
          ),
        );
        expect(decoded.definition, proposed.definition);
        if (saved.layout!.typeId == 'document') {
          expect(decoded.values['bodyFormat'], 'markdown');
          expect(decoded.values['body'], contains('## 维护说明'));
        }
        if (saved.layout!.typeId.contains('profile')) {
          final education = decoded.values['education'] as List;
          expect(education.single['title'], '示例大学 · 计算机专业');
          expect((education.single['fieldIds'] as Map).length, 3);
          expect(
            saved.fields.where((f) => f.name == '经历名称').single.value,
            '示例大学 · 计算机专业',
          );
        }
        expect((await proposals.read(id)).items, isEmpty);
      }
      await close();
      await open();
      expect(service.owner.information.length, ids.length);
      expect(service.owner.information.every((i) => i.layout != null), true);
      expect(service.owner.importProposals.every((p) => p.items.isEmpty), true);
    },
  );
  test(
    'owner edits remain in the typed fields and structured entry leaves',
    () async {
      final profile =
          ((await cli.execute({'command': 'template-list'}))['templates']
                      as List)
                  .singleWhere(
                    (t) => (t['id'] as String).contains('profile'),
                  )['id']
              as String;
      final submitted = await cli.execute(await example(profile));
      final detail = await proposals.read(submitted['proposalId'] as String);
      final original = WorkspaceProposalItemReview.fromItem(
        detail.items.single,
      );
      final values =
          jsonDecode(jsonEncode(original.values)) as Map<String, dynamic>;
      values['name'] = '主人核对姓名';
      (values['education'] as List).single['detail'] = '主人核对教育说明';
      await approve(
        detail,
        reviewed: [
          WorkspaceProposalItemReview(
            itemId: original.itemId,
            name: original.name,
            description: original.description,
            values: values,
            relations: original.relations,
          ),
        ],
      );
      final decoded = WorkspaceInformationCodec().decode(
        service.owner.information.single,
        tagNames: const {},
      );
      expect(decoded.values['name'], '主人核对姓名');
      expect(
        (decoded.values['education'] as List).single['detail'],
        '主人核对教育说明',
      );
      expect(service.owner.information.single.layout!.typeId, profile);
    },
  );
  test(
    'typed modification uses the existing before/after approval and persists owner-reviewed values',
    () async {
      final originalPayload = await example('document');
      final submitted = await cli.execute(originalPayload);
      await approve(await proposals.read(submitted['proposalId'] as String));
      final item = service.owner.information.single;
      final template = Map<String, dynamic>.from(
        (originalPayload['items'] as List).single as Map,
      );
      final changedValues = Map<String, Object?>.from(
        template['values'] as Map,
      );
      changedValues['body'] = '## 第二版\n\n更新维护步骤。';
      final update = <String, dynamic>{
        'command': 'update-submit',
        'update': {
          'itemId': item.id,
          'baseVersion': item.version,
          'templateId': template['templateId'],
          'templateVersion': template['templateVersion'],
          'templateDigest': template['templateDigest'],
          'values': changedValues,
        },
      };
      final response = await cli.execute(update);
      expect(response['status'], 'pending');
      final id = response['proposalId'] as String;
      expect(service.owner.information.single.version, 1);
      final beforeRestart = await proposals.read(id);
      expect(
        beforeRestart.items.single.before!.values['body'],
        contains('## 维护说明'),
      );
      expect(
        beforeRestart.items.single.proposed.values['body'],
        contains('## 第二版'),
      );
      expect(
        beforeRestart.items.single.changes.single.intent,
        WorkspaceProposalFieldIntent.correct,
      );
      await close();
      await open();
      final detail = await proposals.read(id);
      expect(detail.reviewToken, beforeRestart.reviewToken);
      final review = WorkspaceProposalItemReview.fromItem(detail.items.single);
      final receipt = await approve(
        detail,
        reviewed: [
          WorkspaceProposalItemReview(
            itemId: review.itemId,
            name: review.name,
            description: review.description,
            values: {...review.values, 'body': '## 主人修改\n\n最终步骤。'},
            relations: review.relations,
          ),
        ],
      );
      expect(receipt.records.single.version, 2);
      final saved = service.owner.information.single;
      expect(saved.fields.map((f) => f.id), item.fields.map((f) => f.id));
      expect(
        saved.fields.singleWhere((f) => f.name == '正文').value,
        '## 主人修改\n\n最终步骤。',
      );
      expect(saved.layout!.typeId, 'document');
      expect(
        service.owner.informationRevisions.single.item.fields
            .singleWhere((f) => f.name == '正文')
            .value,
        contains('## 维护说明'),
      );
      expect(service.owner.updateProposals.single.input.values, isEmpty);
      final bad = jsonDecode(jsonEncode(update)) as Map<String, dynamic>;
      (bad['update'] as Map)['templateDigest'] = '0' * 64;
      expect((await cli.execute(bad))['status'], 'template_changed');
      (bad['update'] as Map)['compiledTemplate'] = {};
      expect((await cli.execute(bad))['status'], 'invalid_request');
    },
  );
  test(
    'typed relations persist, stay owner-reviewed and validate target types without granting reads',
    () async {
      Future<core.InformationItem> add(String templateId) async {
        final submitted = await cli.execute(await example(templateId));
        final receipt = await approve(
          await proposals.read(submitted['proposalId'] as String),
        );
        return service.owner.information.singleWhere(
          (i) => i.id == receipt.records.single.ref.id,
        );
      }

      final server1 = await add('server'),
          server2 = await add('server'),
          document = await add('document');
      final payload = await example('service');
      final input = (payload['items'] as List).single as Map;
      input['relations'] = {
        'hostedOn': [
          {'kind': 'information', 'id': server1.id},
        ],
        'docs': [
          {'kind': 'information', 'id': document.id},
        ],
      };
      final submitted = await cli.execute(payload);
      expect(submitted['status'], 'pending');
      final detail = await proposals.read(submitted['proposalId'] as String);
      expect(
        detail.items.single.proposed.relations['hostedOn']!.single.id,
        server1.id,
      );
      final related = await proposals
          .relations(
            detail.summary.id,
            detail.items.single.id,
            detail.summary.version,
          )
          .readSummaries([
            WorkspaceRecordRef(WorkspaceRecordKind.information, server1.id),
          ]);
      expect(related.single.name, server1.name);
      final receipt = await approve(detail);
      final serviceItem = service.owner.information.singleWhere(
        (i) => i.id == receipt.records.single.ref.id,
      );
      expect(serviceItem.layout!.relations['hostedOn']!.single.id, server1.id);
      final update = <String, dynamic>{
        'command': 'update-submit',
        'update': {
          'itemId': serviceItem.id,
          'baseVersion': serviceItem.version,
          'templateId': input['templateId'],
          'templateVersion': input['templateVersion'],
          'templateDigest': input['templateDigest'],
          'values': input['values'],
          'relations': {
            'hostedOn': [
              {'kind': 'information', 'id': server2.id},
            ],
          },
        },
      };
      final changed = await cli.execute(update);
      expect(changed['status'], 'pending');
      final preview = await proposals.read(changed['proposalId'] as String);
      expect(
        preview.items.single.before!.relations['hostedOn']!.single.id,
        server1.id,
      );
      expect(
        preview.items.single.proposed.relations['hostedOn']!.single.id,
        server2.id,
      );
      expect(
        service.owner.information
            .singleWhere((i) => i.id == serviceItem.id)
            .layout!
            .relations['hostedOn']!
            .single
            .id,
        server1.id,
      );
      await approve(preview);
      await close();
      await open();
      final saved = service.owner.information.singleWhere(
        (i) => i.id == serviceItem.id,
      );
      expect(saved.layout!.relations['hostedOn']!.single.id, server2.id);
      expect(saved.layout!.relations.containsKey('docs'), false);
      expect(
        service
            .owner
            .informationRevisions
            .single
            .item
            .layout!
            .relations['hostedOn']!
            .single
            .id,
        server1.id,
      );
      expect(
        (await cli.execute({'command': 'read', 'itemId': saved.id}))['status'],
        'unauthorized',
      );
      final invalid = await example('service');
      ((invalid['items'] as List).single as Map)['relations'] = {
        'hostedOn': [
          {'kind': 'information', 'id': document.id},
        ],
      };
      final pending = await cli.execute(invalid);
      expect(pending['status'], 'needs_attention');
      await expectLater(
        approve(await proposals.read(pending['proposalId'] as String)),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'proposal_reference_unavailable',
          ),
        ),
      );
      expect(service.owner.information.length, 4);
      ((invalid['items'] as List).single as Map)['relations'] = {
        'PRIVATE-RELATION': [],
      };
      final error = await cli.execute(invalid);
      expect(error['status'], 'validation_failed');
      expect(jsonEncode(error), isNot(contains('PRIVATE')));
    },
  );
  test(
    'CLI pending references survive review, partial admission and encrypted reopen without a false saved receipt',
    () async {
      final payload = await example('document');
      final base = Map<String, dynamic>.from(
        (payload['items'] as List).single as Map,
      );
      payload['items'] = [
        {
          ...base,
          'key': 'a',
          'name': '说明甲',
          'relations': {
            'related': [
              {'kind': 'information', 'itemKey': 'b'},
            ],
          },
        },
        {
          ...base,
          'key': 'b',
          'name': '说明乙',
          'relations': {
            'related': [
              {'kind': 'information', 'itemKey': 'a'},
            ],
          },
        },
        {...base, 'key': 'independent', 'name': '独立说明'},
      ];
      final submitted = await cli.execute(payload);
      expect(submitted['status'], 'pending');
      final id = submitted['proposalId'] as String;
      final initial = await proposals.read(id);
      final first = await approve(
        initial,
        reviewed: [
          for (final i in initial.items.where(
            (i) => i.proposed.record.name != '说明乙',
          ))
            WorkspaceProposalItemReview.fromItem(i),
        ],
      );
      expect(first.records.length, 1);
      expect(first.awaitingItemIds, ['proposal:$id:a']);
      expect(service.owner.information.single.name, '独立说明');
      final remaining = await proposals.read(id);
      expect(remaining.items.map((i) => i.proposed.record.name), [
        '说明甲',
        '说明乙',
      ]);
      expect(remaining.items.first.admissionNote, contains('已批准'));
      final linked = await proposals
          .relations(id, remaining.items.first.id, remaining.summary.version)
          .readSummaries(
            remaining.items.first.proposed.relations.values.expand((r) => r),
          );
      expect(linked.single.name, '说明乙（待入库）');
      final state = await cli.execute({
        'command': 'import-status',
        'proposalId': id,
      });
      expect(
        (state['items'] as List).singleWhere((i) => i['key'] == 'a')['state'],
        'approved',
      );
      expect(jsonEncode(state), isNot(contains('维护说明')));
      await close();
      await open();
      final reopened = await proposals.read(id);
      expect(reopened.items.first.admissionNote, contains('已批准'));
      expect(
        (await proposals.receipt(first.operationId))!.awaitingItemIds,
        first.awaitingItemIds,
      );
      final finalReceipt = await approve(
        reopened,
        reviewed: [WorkspaceProposalItemReview.fromItem(reopened.items.last)],
      );
      expect(finalReceipt.awaitingItemIds, isEmpty);
      expect(finalReceipt.records.length, 1);
      expect(service.owner.information.length, 3);
      final a = service.owner.information.singleWhere((i) => i.name == '说明甲'),
          b = service.owner.information.singleWhere((i) => i.name == '说明乙');
      expect(a.layout!.relations['related']!.single.id, b.id);
      expect(b.layout!.relations['related']!.single.id, a.id);
      final finalDetail = await proposals.read(id);
      expect(finalDetail.summary.status, WorkspaceProposalStatus.completed);
      expect(finalDetail.items, isEmpty);
      expect(finalDetail.targets.map((t) => t.name).toSet(), {
        '说明甲',
        '说明乙',
        '独立说明',
      });
    },
  );
  test(
    'CLI revision after a rejected dependency resets approval and the owner can admit the repaired proposal',
    () async {
      final targetPayload = await example('document');
      ((targetPayload['items'] as List).single as Map)['key'] = 'target';
      final target = await cli.execute(targetPayload);
      final payload = await example('document');
      final row = (payload['items'] as List).single as Map;
      row['key'] = 'dependent';
      row['relations'] = {
        'related': [
          {
            'kind': 'information',
            'itemKey': 'target',
            'proposalId': target['proposalId'],
          },
        ],
      };
      final response = await cli.execute(payload);
      final id = response['proposalId'] as String;
      final waiting = await approve(await proposals.read(id));
      expect(waiting.records, isEmpty);
      expect(waiting.awaitingItemIds.length, 1);
      expect(
        (await proposals.read(id)).summary.status,
        WorkspaceProposalStatus.awaiting,
      );
      final targetDetail = await proposals.read(target['proposalId'] as String);
      await proposals.change(
        WorkspaceProposalChange(
          operationId: workspaceOperationId(),
          proposalId: targetDetail.summary.id,
          version: targetDetail.summary.version,
          reviewToken: targetDetail.reviewToken,
          action: WorkspaceProposalAction.reject,
          reviewed: const [],
        ),
      );
      final blocked = await proposals.read(id);
      expect(blocked.summary.status, WorkspaceProposalStatus.needsAttention);
      expect(blocked.notice, contains('已被拒绝'));
      row['relations'] = <String, Object?>{};
      final amended = await cli.execute({
        'command': 'import-revise',
        'proposalId': id,
        'version': blocked.summary.version,
        'items': [row],
      });
      expect(amended['status'], 'pending');
      expect(
        service.owner.importProposals
            .singleWhere((p) => p.id == id)
            .approvedKeys,
        isEmpty,
      );
      expect(service.owner.information, isEmpty);
      await approve(await proposals.read(id));
      expect(service.owner.information.length, 1);
    },
  );
  test(
    'reviewed template modification waits for its reference, survives reopen and saves the owner values with it',
    () async {
      final base = await example('document');
      final seed = await cli.execute(base);
      await approve(await proposals.read(seed['proposalId'] as String));
      final original = service.owner.information.single;
      final targetPayload = await example('document');
      ((targetPayload['items'] as List).single as Map).addAll(<String, dynamic>{
        'key': 'target',
        'name': '新维护说明',
      });
      final target = await cli.execute(targetPayload);
      final input = (base['items'] as List).single as Map;
      final result = await cli.execute({
        'command': 'update-submit',
        'update': {
          'itemId': original.id,
          'baseVersion': original.version,
          'templateId': input['templateId'],
          'templateVersion': input['templateVersion'],
          'templateDigest': input['templateDigest'],
          'values': {'bodyFormat': 'markdown', 'body': '## AI 提议修改'},
          'relations': {
            'related': [
              {
                'kind': 'information',
                'itemKey': 'target',
                'proposalId': target['proposalId'],
              },
            ],
          },
        },
      });
      expect(result['status'], 'pending');
      final id = result['proposalId'] as String;
      final detail = await proposals.read(id);
      expect(detail.items.single.before!.values['body'], contains('## 维护说明'));
      final proposed = WorkspaceProposalItemReview.fromItem(
        detail.items.single,
      );
      final linked = await proposals
          .relations(id, proposed.itemId, detail.summary.version)
          .readSummaries(proposed.relations.values.expand((r) => r));
      expect(linked.single.name, '新维护说明（待入库）');
      final waiting = await approve(
        detail,
        reviewed: [
          WorkspaceProposalItemReview(
            itemId: proposed.itemId,
            name: proposed.name,
            description: proposed.description,
            values: {
              ...proposed.values,
              'body': '## OWNER-REVIEWED-MODIFICATION',
            },
            relations: proposed.relations,
          ),
        ],
      );
      expect(waiting.records, isEmpty);
      expect(waiting.awaitingItemIds, [original.id]);
      expect(service.owner.information.single.version, 1);
      expect(service.owner.informationRevisions, isEmpty);
      final status = await cli.execute({
        'command': 'update-status',
        'proposalId': id,
      });
      expect(status['status'], 'approved_awaiting_admission');
      expect(jsonEncode(status), isNot(contains('OWNER-REVIEWED')));
      expect(
        (await proposals.read(id)).summary.status,
        WorkspaceProposalStatus.awaiting,
      );
      await close();
      await open();
      expect(
        (await proposals.read(id)).items.single.proposed.values['body'],
        '## OWNER-REVIEWED-MODIFICATION',
      );
      expect((await proposals.receipt(waiting.operationId))!.awaitingItemIds, [
        original.id,
      ]);
      await approve(await proposals.read(target['proposalId'] as String));
      final current = service.owner.information.singleWhere(
            (i) => i.id == original.id,
          ),
          referenced = service.owner.information.singleWhere(
            (i) => i.name == '新维护说明',
          );
      expect(
        current.fields.singleWhere((f) => f.name == '正文').value,
        '## OWNER-REVIEWED-MODIFICATION',
      );
      expect(current.layout!.relations['related']!.single.id, referenced.id);
      expect(current.version, 2);
      expect(service.owner.informationRevisions.single.item.version, 1);
      expect(
        (await proposals.read(id)).summary.status,
        WorkspaceProposalStatus.completed,
      );
    },
  );
  test(
    'CLI can repair a rejected update reference only by resetting the owner approval',
    () async {
      final base = await example('document');
      final seed = await cli.execute(base);
      await approve(await proposals.read(seed['proposalId'] as String));
      final original = service.owner.information.single;
      final targetPayload = await example('document');
      ((targetPayload['items'] as List).single as Map)['key'] = 'target';
      final target = await cli.execute(targetPayload);
      final descriptor = (base['items'] as List).single as Map;
      final update = <String, Object?>{
        'itemId': original.id,
        'baseVersion': original.version,
        'templateId': descriptor['templateId'],
        'templateVersion': descriptor['templateVersion'],
        'templateDigest': descriptor['templateDigest'],
        'values': {'bodyFormat': 'plain', 'body': '修改正文'},
        'relations': {
          'related': [
            {
              'kind': 'information',
              'itemKey': 'target',
              'proposalId': target['proposalId'],
            },
          ],
        },
      };
      final submitted = await cli.execute({
        'command': 'update-submit',
        'update': update,
      });
      final id = submitted['proposalId'] as String;
      await approve(await proposals.read(id));
      await service.owner.rejectImport(target['proposalId'] as String, 1);
      final blocked = await proposals.read(id);
      expect(blocked.summary.status, WorkspaceProposalStatus.needsAttention);
      expect(blocked.notice, contains('已被拒绝'));
      final other = AgentClient(server.port);
      addTearDown(other.close);
      await other.execute({'command': 'session', 'chatLabel': '另一个会话'});
      expect(
        (await other.execute({
          'command': 'update-revise',
          'proposalId': id,
          'version': blocked.summary.version,
          'update': update,
        }))['status'],
        'unauthorized',
      );
      update['relations'] = <String, Object?>{};
      final revised = await cli.execute({
        'command': 'update-revise',
        'proposalId': id,
        'version': blocked.summary.version,
        'update': update,
      });
      expect(revised['status'], 'pending');
      expect(service.owner.updateProposals.single.approved, false);
      expect(service.owner.information.single.version, 1);
      await approve(await proposals.read(id));
      expect(service.owner.information.single.version, 2);
      expect(
        service.owner.information.single.layout!.relations.values.expand(
          (r) => r,
        ),
        isEmpty,
      );
    },
  );
  test(
    'a plugin disabled after submission stays reviewable but cannot be admitted',
    () async {
      final submitted = await cli.execute(await example('server'));
      final id = submitted['proposalId'] as String;
      await service.owner.changeTemplatePackage(
        core.TemplatePackageCommand(
          operationId: 'disable-server',
          action: core.TemplatePackageAction.disable,
          packageId: 'builtin.server',
          expectedVersion: service.owner.templatePackageVersion,
          commandDigest: 'a' * 64,
        ),
      );
      final detail = await proposals.read(id);
      expect(detail.items.single.proposed.record.type.id, 'server');
      await expectLater(
        approve(detail),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'template_unavailable',
          ),
        ),
      );
      expect(service.owner.information, isEmpty);
      expect(
        service.owner.importProposals.single.state,
        core.ImportProposalState.pending,
      );
    },
  );
  test(
    'stale template and bad values return actionable errors without flattening or echoing values',
    () async {
      final payload = await example('document');
      final item = (payload['items'] as List).single as Map;
      item['templateDigest'] = '0' * 64;
      expect((await cli.execute(payload))['status'], 'template_changed');
      final invalid = await example('document');
      final fields =
          ((invalid['items'] as List).single as Map)['values'] as Map;
      fields['bodyFormat'] = 'PRIVATE-VALUE';
      fields['PRIVATE-KEY'] = 'PRIVATE-BODY';
      final result = await cli.execute(invalid);
      expect(result['status'], 'validation_failed');
      expect((result['fieldErrors'] as Map).keys, contains('bodyFormat'));
      expect(jsonEncode(result), isNot(contains('PRIVATE')));
      expect(service.owner.importProposals, isEmpty);
      expect(service.owner.information, isEmpty);
      final spoofed = await example('document');
      ((spoofed['items'] as List).single as Map)['layout'] = {};
      expect((await cli.execute(spoofed))['status'], 'invalid_request');
    },
  );
}
