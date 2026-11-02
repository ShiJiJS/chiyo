import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/owner_agent_templates.dart';
import 'package:info_desktop/workspace/owner_workspace_plugins.dart';
import 'package:info_storage/info_storage.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async {
    key = List.of(value);
  }
}

Map<String, Object?> _package(String version) => {
  'id': 'local.notes',
  'name': '资料模板',
  'version': version,
  'hostApi': 1,
  'author': '测试',
  'description': '只描述字段，不含用户资料。',
  'templates': [
    {
      'id': 'note',
      'name': '维护文档',
      'icon': 'book',
      'instructions': '将长说明保存在正文，明确选择正文格式。',
      'fields': [
        {
          'key': 'format',
          'label': '正文格式',
          'type': 'text',
          'required': true,
          'description': '选择 plain 或 markdown。',
        },
        {
          'key': 'body',
          'label': '正文',
          'type': 'multiline',
          'required': true,
          'description': '源文档中的维护步骤。',
        },
      ],
      'sections': [
        {'kind': 'text', 'title': '维护说明', 'key': 'body', 'formatKey': 'format'},
      ],
      'relations': [],
      'example': {
        'name': '维护手册',
        'summary': '服务维护步骤。',
        'values': {'format': 'markdown', 'body': '## 检查\n\n- 查看状态'},
      },
    },
  ],
};

void main() {
  test(
    'same CLI sees the real installed catalog change without copied definitions',
    () async {
      final root = await Directory.systemTemp.createTemp('agent-templates-');
      final keys = _Keys();
      var repo = await EncryptedInformationRepository.open(root.path, keys);
      var service = core.InformationService(repository: repo);
      void configure() => service.owner.configureInformationTemplates(
        () => currentAgentTemplates(service.owner),
      );
      configure();
      final server = await AgentServer.start(service.agent, port: 0);
      final cli = AgentClient(server.port);
      addTearDown(() async {
        cli.close();
        await server.close();
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      var sequence = 0;
      Future<void> change(
        core.TemplatePackageAction action, {
        String version = '1.0.0',
      }) async {
        final input = action == core.TemplatePackageAction.install
            ? core.InstalledTemplatePackage(
                id: 'local.notes',
                enabled: true,
                origin: 'PRIVATE-SOURCE-PATH',
                bytes: utf8.encode(jsonEncode(_package(version))),
              )
            : null;
        await service.owner.changeTemplatePackage(
          core.TemplatePackageCommand(
            operationId: 'templates-${++sequence}',
            action: action,
            packageId: 'local.notes',
            expectedVersion: service.owner.templatePackageVersion,
            commandDigest: 'b' * 64,
            expectedDigest: input?.digest,
          ),
          input: input,
        );
      }

      final initial = await cli.execute({'command': 'template-list'});
      expect(initial['status'], 'ok');
      for (final t in initial['templates'] as List) {
        expect(t['hasGuidance'], true, reason: t['id'] as String);
      }
      final ownerTemplates = OwnerWorkspacePlugins(
        owner: service.owner,
        changed: () {},
      );
      addTearDown(ownerTemplates.dispose);
      for (final e in ownerTemplates.templates.entries) {
        final read = await cli.execute({
          'command': 'template-read',
          'templateId': e.key,
        });
        expect((read['template'] as Map)['definition'], e.value);
      }
      await service.owner.createInformation(
        'PRIVATE-RECORD',
        'PRIVATE-DESCRIPTION',
        [const core.FieldInput('值', '', 'PRIVATE-VALUE')],
      );
      await change(core.TemplatePackageAction.install);
      final found = await cli.execute({
        'command': 'template-read',
        'templateId': 'local.notes/note',
      });
      expect(found['status'], 'ok');
      final template = found['template'] as Map;
      expect(template['hasGuidance'], true);
      expect(
        (template['definition'] as Map)['example'],
        _package('1.0.0')['templates'] is List
            ? ((_package('1.0.0')['templates'] as List).single
                  as Map)['example']
            : null,
      );
      expect(jsonEncode(found), isNot(contains('PRIVATE')));
      expect(
        (await cli.execute({
          'command': 'session',
          'chatLabel': '插件录入',
        }))['status'],
        'ok',
      );
      final submitted = await cli.execute(
        Map<String, dynamic>.from(template['submissionExample'] as Map),
      );
      expect(submitted['status'], 'pending');
      final pending = service.owner.importProposals.single;
      final receipts = await service.owner.confirmImport(
        pending.id,
        pending.version,
        pending.items,
      );
      final typed = service.owner.information.singleWhere(
        (i) => i.id == receipts.single.id,
      );
      expect(typed.layout!.typeId, 'local.notes/note');
      expect(typed.layout!.snapshot['definition'], template['definition']);
      expect(
        typed.fields.singleWhere((f) => f.name == '正文').value,
        '## 检查\n\n- 查看状态',
      );
      final plugins = await cli.execute({'command': 'plugin-list'});
      expect(jsonEncode(plugins), isNot(contains('PRIVATE')));
      expect(
        (plugins['plugins'] as List).any((p) => p['id'] == 'local.notes'),
        true,
      );
      await change(core.TemplatePackageAction.disable);
      expect(
        (await cli.execute({
          'command': 'template-read',
          'templateId': 'local.notes/note',
        }))['status'],
        'template_unavailable',
      );
      expect(
        ((await cli.execute({'command': 'template-list'}))['templates'] as List)
            .singleWhere((t) => t['id'] == 'local.notes/note')['enabled'],
        false,
      );
      await change(core.TemplatePackageAction.enable);
      await change(core.TemplatePackageAction.install, version: '2.0.0');
      final newer = await cli.execute({
        'command': 'template-read',
        'templateId': 'local.notes/note',
      });
      expect((newer['template'] as Map)['version'], '2.0.0');
      expect((newer['template'] as Map)['digest'], isNot(template['digest']));
      cli.close();
      await server.close();
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(root.path, keys);
      service = core.InformationService(repository: repo);
      configure();
      expect(
        service.agent.readInformationTemplate('local.notes/note')['status'],
        'ok',
      );
      await change(core.TemplatePackageAction.remove);
      expect(
        () => service.agent.readInformationTemplate('local.notes/note'),
        throwsA(
          isA<core.AccessFailure>().having(
            (e) => e.status,
            'status',
            'template_missing',
          ),
        ),
      );
      expect(
        service.owner.information
            .singleWhere((i) => i.name == 'PRIVATE-RECORD')
            .fields
            .single
            .value,
        'PRIVATE-VALUE',
      );
    },
  );
}
