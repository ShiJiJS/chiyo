import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_agent_templates.dart';
import 'package:info_desktop/workspace/owner_workspace_plugins.dart';
import 'package:info_desktop/workspace/owner_workspace_proposals.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

void main() {
  test(
    'installed credential templates update live, keep material out of the owner projection, and remain separate from ordinary editors',
    () async {
      final root = await Directory.systemTemp.createTemp('credential-plugin-');
      final repo = await EncryptedInformationRepository.open(
        root.path,
        _Keys(),
      );
      final service = core.InformationService(repository: repo);
      service.owner.configureInformationTemplates(
        () => currentAgentTemplates(service.owner),
      );
      final server = await AgentServer.start(service.agent, port: 0),
          cli = AgentClient(0);
      cli.close();
      final agent = AgentClient(server.port);
      late OwnerWorkspaceSource library;
      final source = OwnerWorkspaceProposals(
        owner: service.owner,
        library: () => library,
        changed: () => library.notifyExternalChange(),
      );
      library = OwnerWorkspaceSource(
        owner: service.owner,
        proposals: source,
        refreshInterval: Duration.zero,
      );
      final plugins = OwnerWorkspacePlugins(
        owner: service.owner,
        changed: () {},
      );
      addTearDown(() async {
        agent.close();
        plugins.dispose();
        await library.dispose();
        await server.close();
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      final initial = await agent.execute({'command': 'template-list'});
      expect(
        (initial['templates'] as List)
            .where((t) => t['recordKind'] == 'credential')
            .length,
        3,
      );
      var sequence = 0;
      Future<void> change(
        core.TemplatePackageAction action, [
        String version = '1.0.0',
      ]) async {
        final input = action == core.TemplatePackageAction.install
            ? core.InstalledTemplatePackage(
                id: 'local.credentials',
                enabled: true,
                origin: 'PRIVATE-PLUGIN-SOURCE',
                bytes: utf8.encode(
                  jsonEncode({
                    'id': 'local.credentials',
                    'name': '业务凭据模板',
                    'version': version,
                    'hostApi': 1,
                    'author': '合成',
                    'description': '业务 Token 格式。',
                    'templates': [
                      {
                        'id': 'api',
                        'name': '业务 API 凭据',
                        'icon': 'file',
                        'recordKind': 'credential',
                        'credential': {
                          'form': 'string',
                          'secretKind': 'token',
                          'suggestedBinding': 'BUSINESS_TOKEN',
                        },
                        'instructions': 'Agent填写Token，提示已进入上下文；名称写服务用途，不能放秘密。',
                        'fields': [],
                        'sections': [],
                        'relations': [],
                        'example': {
                          'name': '业务 API Token',
                          'summary': '业务自动化接口认证。',
                          'values': {},
                        },
                      },
                    ],
                  }),
                ),
              )
            : null;
        await service.owner.changeTemplatePackage(
          core.TemplatePackageCommand(
            operationId: 'credential-plugins-${++sequence}',
            action: action,
            packageId: 'local.credentials',
            expectedVersion: service.owner.templatePackageVersion,
            commandDigest: 'b' * 64,
            expectedDigest: input?.digest,
          ),
          input: input,
        );
      }

      await change(core.TemplatePackageAction.install);
      await agent.execute({'command': 'session', 'chatLabel': '合成插件录入'});
      final read = await agent.execute({
        'command': 'template-read',
        'templateId': 'local.credentials/api',
      });
      expect(jsonEncode(read), isNot(contains('PRIVATE-PLUGIN-SOURCE')));
      final submitted = await agent.execute(
        Map<String, dynamic>.from(
          (read['template'] as Map)['submissionExample'] as Map,
        ),
      );
      expect(submitted['status'], 'pending');
      final id = submitted['proposalId'] as String;
      final detail = await source.read(id);
      expect(detail.items.single.credential!.contextExposed, true);
      expect(detail.items.single.proposed.values, isEmpty);
      expect(
        jsonEncode(detail.items.single.proposed.values),
        isNot(contains('FAKE-EXAMPLE-ONLY')),
      );
      expect(plugins.templates.containsKey('local.credentials/api'), false);
      await change(core.TemplatePackageAction.disable);
      expect(
        (await agent.execute({
          'command': 'template-read',
          'templateId': 'local.credentials/api',
        }))['status'],
        'template_unavailable',
      );
      await expectLater(
        source.change(
          WorkspaceProposalChange(
            operationId: 'stale-review',
            proposalId: id,
            version: detail.summary.version,
            reviewToken: detail.reviewToken,
            action: WorkspaceProposalAction.confirm,
            reviewed: detail.items.map(WorkspaceProposalItemReview.fromItem),
          ),
        ),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect(repo.managedCredentials, isEmpty);
      await change(core.TemplatePackageAction.enable);
      final current = await source.read(id);
      final command = WorkspaceProposalChange(
        operationId: 'credential-review',
        proposalId: id,
        version: current.summary.version,
        reviewToken: current.reviewToken,
        action: WorkspaceProposalAction.confirm,
        reviewed: current.items.map(WorkspaceProposalItemReview.fromItem),
      );
      final receipt = WorkspaceProposalExpectation(
        current,
      ).check(command, await source.change(command));
      expect(receipt.records.single.ref.kind, WorkspaceRecordKind.credential);
      expect(
        repo.managedCredentials.single.template!.typeId,
        'local.credentials/api',
      );
      expect(repo.managedCredentials.single.suggestedBinding, 'BUSINESS_TOKEN');
      expect(repo.items, isEmpty);
      expect(
        plugins.packages
            .singleWhere((p) => p.id == 'local.credentials')
            .affectedRecords,
        1,
      );
      await change(core.TemplatePackageAction.install, '2.0.0');
      final updated = await agent.execute({
        'command': 'template-read',
        'templateId': 'local.credentials/api',
      });
      expect((updated['template'] as Map)['version'], '2.0.0');
      expect(
        repo.managedCredentials.single.template!.snapshot['templateVersion'],
        '1.0.0',
      );
      await change(core.TemplatePackageAction.remove);
      expect(
        (await agent.execute({
          'command': 'template-read',
          'templateId': 'local.credentials/api',
        }))['status'],
        'template_missing',
      );
      expect(
        repo.managedCredentials.single.template!.typeId,
        'local.credentials/api',
      );
      expect(
        repo.credentialMaterials.single.bytes,
        utf8.encode('FAKE-EXAMPLE-ONLY'),
      );
    },
  );
}
