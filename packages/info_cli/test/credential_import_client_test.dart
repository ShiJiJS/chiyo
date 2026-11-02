import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import '../../info_core/test/fixtures/credential_import_fixture.dart';

void main() {
  test(
    'CLI sends a whole file privately and retries the same intake without creating a second credential',
    () async {
      final root = await Directory.systemTemp.createTemp('credential-cli-');
      final repo = MemoryInformationRepository();
      final service = InformationService(repository: repo);
      configureCredentialImports(service);
      final server = await AgentServer.start(service.agent, port: 0);
      final cli = AgentClient(server.port);
      addTearDown(() async {
        cli.close();
        await server.close();
        await service.close();
        await root.delete(recursive: true);
      });
      await cli.execute({'command': 'session', 'chatLabel': '合成文件录入'});
      final response = await cli.execute({
        'command': 'template-read',
        'templateId': 'credential.file',
      });
      final template = response['template'] as Map;
      final input = Map<String, dynamic>.from(
        template['submissionExample'] as Map,
      );
      input['operationId'] = 'whole-file-once';
      final item = Map<String, dynamic>.from(
        (input['items'] as List).single as Map,
      );
      final file = File('${root.path}/中文 synthetic \'\u0024().key');
      final bytes = List<int>.generate(1048576, (i) => i % 256);
      await file.writeAsBytes(bytes);
      item['credential'] = {
        'source': 'agentFile',
        'contextExposed': false,
        'filePath': file.path,
      };
      input['items'] = [item];
      final first = await cli.execute(input);
      expect(first['status'], 'pending');
      final id = first['proposalId'] as String;
      expect(jsonEncode(first), isNot(contains(file.path)));
      expect(repo.managedCredentials, isEmpty);
      final repeat = await cli.execute(input);
      expect(repeat['proposalId'], id);
      expect(repo.importProposals.length, 1);
      final p = service.owner.importProposals.single;
      expect(p.items.single.credential!.material, bytes);
      await file.delete();
      final recovered = await cli.execute({
        'command': 'import-status',
        'operationId': 'whole-file-once',
      });
      expect(recovered['proposalId'], id);
      expect(recovered['status'], 'pending');
      await service.owner.confirmImport(id, p.version, p.items);
      expect(
        repo.managedCredentials.single.fileName,
        file.uri.pathSegments.last,
      );
      expect(repo.credentialMaterials.single.bytes, bytes);
      expect(
        (await cli.execute({
          'command': 'import-status',
          'proposalId': id,
        }))['status'],
        'confirmed',
      );
      expect(repo.items, isEmpty);
      final text = Map<String, dynamic>.from(
        ((await cli.execute({
                  'command': 'template-read',
                  'templateId': 'credential.token',
                }))['template']
                as Map)['submissionExample']
            as Map,
      );
      text['operationId'] = 'token-once';
      final token = await cli.execute(text);
      final tokenProposal = repo.importProposals.singleWhere(
        (p) => p.id == token['proposalId'],
      );
      await service.owner.confirmImport(
        tokenProposal.id,
        tokenProposal.version,
        tokenProposal.items,
      );
      expect((await cli.execute(text))['proposalId'], tokenProposal.id);
      final modified = Map<String, dynamic>.from(
        (text['items'] as List).single as Map,
      );
      modified['credential'] = {
        'source': 'agentString',
        'contextExposed': true,
        'secret': 'FAKE-CHANGED',
      };
      expect(
        (await cli.execute({
          ...text,
          'items': [modified],
        }))['status'],
        'operation_conflict',
      );
      expect(repo.managedCredentials.length, 2);
      final other = AgentClient(server.port);
      try {
        await other.execute({'command': 'session', 'chatLabel': '其他会话'});
        expect(
          (await other.execute({
            'command': 'import-status',
            'operationId': 'whole-file-once',
          }))['status'],
          'not_found',
        );
      } finally {
        other.close();
      }
    },
  );

  test(
    'missing, empty, oversized files and forged private material never create proposals or echo input',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'credential-cli-invalid-',
      );
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      configureCredentialImports(service);
      final server = await AgentServer.start(service.agent, port: 0);
      final cli = AgentClient(server.port);
      addTearDown(() async {
        cli.close();
        await server.close();
        await service.close();
        await root.delete(recursive: true);
      });
      await cli.execute({'command': 'session', 'chatLabel': '合成错误输入'});
      final empty = File('${root.path}/empty.key');
      await empty.create();
      final large = File('${root.path}/large.key');
      await large.writeAsBytes(List.filled(1048577, 65));
      for (final material in [
        for (final path in ['${root.path}/missing.key', empty.path, large.path])
          {'source': 'agentFile', 'contextExposed': false, 'filePath': path},
        {
          'source': 'owner',
          'contextExposed': false,
          'material': 'PRIVATE-FORGED',
        },
      ]) {
        final result = await cli.execute({
          'command': 'import-submit',
          'items': [
            {
              'name': '合成凭据',
              'templateId': 'credential.file',
              'templateVersion': '1',
              'templateDigest': 'c' * 64,
              'values': {},
              'credential': material,
            },
          ],
        });
        expect(result['status'], isNot('pending'));
        expect(jsonEncode(result), isNot(contains(root.path)));
        expect(jsonEncode(result), isNot(contains('PRIVATE-FORGED')));
        expect(service.owner.importProposals, isEmpty);
      }
    },
  );
}
