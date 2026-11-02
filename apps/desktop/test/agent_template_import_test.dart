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
      for (final template in templates.where((t) => t['id'] != 'file')) {
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
