import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import '../../info_core/test/fixtures/file_import_fixture.dart';

void main() {
  test(
    'CLI privately uploads a maximum-size original, retries, and preserves explicit version choice after approval',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'ordinary-import-cli-',
      );
      final repo = MemoryInformationRepository();
      final service = InformationService(repository: repo);
      configureFileImports(service);
      final server = await AgentServer.start(service.agent, port: 0);
      final cli = AgentClient(server.port);
      addTearDown(() async {
        cli.close();
        await server.close();
        await service.close();
        await root.delete(recursive: true);
      });
      await cli.execute({'command': 'session', 'chatLabel': '普通文件录入'});
      final file = File('${root.path}/中文 synthetic \'\u0024().pdf');
      final bytes = List<int>.generate(
        informationFileByteLimit,
        (i) => i % 251,
      );
      await file.writeAsBytes(bytes);
      final revision = File('${root.path}/修订.txt');
      await revision.writeAsString('PRIVATE-REVISED');
      final input = <String, dynamic>{
        'command': 'import-submit',
        'operationId': 'originals-once',
        'items': [
          {
            'key': 'resume',
            'name': '后端岗位简历',
            'description': '用户提供的材料。',
            'templateId': 'file',
            'templateVersion': '1',
            'templateDigest': 'a' * 64,
            'values': {'file': 'primary'},
            'attachments': [
              {
                'key': 'primary',
                'name': '原文',
                'templateField': 'file',
                'currentVersion': 1,
                'versions': [
                  {
                    'filePath': file.path,
                    'label': '已确认的当前稿',
                    'sourceNote': '用户明确标为当前。',
                  },
                  {
                    'filePath': revision.path,
                    'label': '历史修订',
                    'sourceNote': '来源明确标为旧稿。',
                  },
                ],
              },
            ],
          },
        ],
      };
      final submitted = await cli.execute(input);
      expect(submitted['status'], 'pending');
      expect(jsonEncode(submitted), isNot(contains(root.path)));
      expect(repo.items, isEmpty);
      final id = submitted['proposalId'] as String;
      expect((await cli.execute(input))['proposalId'], id);
      expect(repo.importProposals.length, 1);
      final p = repo.importProposals.single;
      final originals = p.items.single.attachments.single.versions;
      expect(originals.first.upload!.byteLength, informationFileByteLimit);
      expect(originals.first.upload!.mediaType, 'application/pdf');
      expect(
        (await service.owner.readImportOriginal(
          id,
          'resume',
          'primary',
          1,
        )).bytes,
        bytes,
      );
      final other = AgentClient(server.port);
      try {
        await other.execute({'command': 'session', 'chatLabel': '其他会话'});
        expect(
          (await other.execute({
            'command': 'import-file-status',
            'operationId': originals.first.upload!.operationId,
          }))['status'],
          'not_found',
        );
      } finally {
        other.close();
      }
      await service.owner.confirmImport(id, p.version, p.items);
      expect(repo.items.single.fields.single.attachment!.attachmentVersion, 1);
      expect(
        (await service.owner.readInformationAttachment(
          repo.items.single.fields.single.attachment!,
        )).bytes,
        bytes,
      );
      expect((await repo.informationFileStagingUsage()).files, 0);
      await file.delete();
      expect(
        (await cli.execute({
          'command': 'import-status',
          'operationId': 'originals-once',
        }))['status'],
        'confirmed',
      );
      expect(
        (await cli.execute({
          'command': 'import-file-status',
          'operationId': originals.first.upload!.operationId,
        }))['consumed'],
        true,
      );
    },
  );

  test(
    'invalid file paths, oversized originals, and missing operation ids create no formal data or disclosures; empty ordinary files work',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'ordinary-import-invalid-',
      );
      final repo = MemoryInformationRepository();
      final service = InformationService(repository: repo);
      configureFileImports(service);
      final server = await AgentServer.start(service.agent, port: 0);
      final cli = AgentClient(server.port);
      addTearDown(() async {
        cli.close();
        await server.close();
        await service.close();
        await root.delete(recursive: true);
      });
      await cli.execute({'command': 'session', 'chatLabel': '普通文件错误检查'});
      final empty = File('${root.path}/empty.txt');
      await empty.create();
      final oversized = File('${root.path}/large.bin');
      final handle = await oversized.open(mode: FileMode.write);
      await handle.truncate(informationFileByteLimit + 1);
      await handle.close();
      Map<String, dynamic> input(String path, {bool operation = true}) => {
        'command': 'import-submit',
        if (operation) 'operationId': 'one-file',
        'items': [
          {
            'name': '合成资料',
            'templateId': 'file',
            'templateVersion': '1',
            'templateDigest': 'a' * 64,
            'values': {'file': 'primary'},
            'attachments': [
              {
                'key': 'primary',
                'name': '原文',
                'templateField': 'file',
                'currentVersion': 1,
                'versions': [
                  {'filePath': path},
                ],
              },
            ],
          },
        ],
      };
      for (final command in [
        input('${root.path}/missing.txt'),
        input(oversized.path),
        input(empty.path, operation: false),
      ]) {
        final result = await cli.execute(command);
        expect(result['status'], isNot('pending'));
        expect(jsonEncode(result), isNot(contains(root.path)));
        expect(repo.importProposals, isEmpty);
        expect(repo.items, isEmpty);
      }
      final submitted = await cli.execute(input(empty.path));
      expect(submitted['status'], 'pending');
      final p = repo.importProposals.single;
      await service.owner.confirmImport(p.id, p.version, p.items);
      expect(
        (await service.owner.readInformationAttachment(
          repo.items.single.fields.single.attachment!,
        )).bytes,
        isEmpty,
      );
    },
  );
}
