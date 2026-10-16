import 'package:info_cli/agent_client.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'agent CLI can only read its assigned task and submit metadata-only changes',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final item = await service.owner.createInformation('Notes', '', [
        const FieldInput('URL', '', 'PRIVATE-URL'),
      ]);
      final directory = await service.owner.createDirectory('Owner category');
      final server = await AgentServer.start(service.agent, port: 0);
      final a = AgentClient(server.port), b = AgentClient(server.port);
      addTearDown(() async {
        a.close();
        b.close();
        await server.close();
        await service.close();
      });
      await a.execute({'command': 'session', 'chatLabel': 'Assigned'});
      await b.execute({'command': 'session', 'chatLabel': 'Other'});
      final request = await a.execute({
        'command': 'organize-request',
        'itemIds': [item.id],
        'purpose': '整理分类',
      });
      final taskId = request['taskId'] as String;
      expect(request['status'], 'pending');
      final waited = await a.execute({
        'command': 'organize-wait',
        'taskId': taskId,
        'timeoutMs': 0,
      });
      expect(waited['waitTimedOut'], true);
      expect(service.owner.organizationTasks, hasLength(1));
      expect(
        (await a.execute({
          'command': 'organize-metadata',
          'taskId': taskId,
        }))['status'],
        'pending',
      );
      await service.owner.approveOrganization(taskId, [item.id]);
      expect(
        (await a.execute({'command': 'organize-tasks'}))['tasks'],
        hasLength(1),
      );
      expect(
        (await b.execute({'command': 'organize-tasks'}))['tasks'],
        isEmpty,
      );
      expect(
        (await b.execute({
          'command': 'organize-metadata',
          'taskId': taskId,
        }))['status'],
        'unauthorized',
      );
      final metadata = await a.execute({
        'command': 'organize-metadata',
        'taskId': taskId,
      });
      expect(metadata['status'], 'ok');
      expect(metadata.toString(), contains('Owner category'));
      expect(metadata.toString(), isNot(contains('PRIVATE-URL')));
      final invalid = await a.execute({
        'command': 'organize-submit',
        'taskId': taskId,
        'changes': [
          {'itemId': item.id, 'baseVersion': 1, 'value': 'overwritten'},
        ],
      });
      expect(invalid['status'], 'invalid_request');
      final submitted = await a.execute({
        'command': 'organize-submit',
        'taskId': taskId,
        'changes': [
          OrganizationChange(
            itemId: item.id,
            baseVersion: 1,
            directoryId: directory.id,
          ).toJson(),
        ],
      });
      expect(submitted['status'], 'confirmed');
      expect(service.owner.information.single.directoryId, directory.id);
      expect(
        (await a.execute({
          'command': 'organize-confirm',
          'taskId': taskId,
        }))['status'],
        'invalid_request',
      );
      await service.owner.confirmOrganization(taskId);
      expect(service.owner.information.single.directoryId, directory.id);
      expect(
        service.owner.information.single.fields.single.value,
        'PRIVATE-URL',
      );
    },
  );
}
