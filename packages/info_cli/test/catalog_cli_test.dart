import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real CLI filters and pages public metadata before requesting a result',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final directory = await service.owner.createDirectory(
        'Owner only organization',
      );
      final tag = await service.owner.createTag('Public label');
      final unused = await service.owner.createTag('Unused public label');
      final item = await service.owner.createInformation(
        'Public server',
        'Project A',
        [const FieldInput('Host', 'Network address', 'PRIVATE-CLI-MARKER')],
      );
      await service.owner.organizeInformation(
        item.id,
        directoryId: directory.id,
        tagIds: [tag.id],
      );
      await service.owner.createInformation('Other server', 'Project B', [
        const FieldInput('Host', 'Network address', 'other.invalid'),
      ]);
      final server = await AgentServer.start(service.agent, port: 0);
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'bin/info.dart',
        '--port',
        '${server.port}',
      ]);
      final output = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      addTearDown(() async {
        await process.stdin.close();
        process.kill();
        await output.cancel();
        await server.close();
        await service.close();
      });
      Future<Map<String, dynamic>> command(Map<String, Object?> value) async {
        process.stdin.writeln(jsonEncode(value));
        expect(
          await output.moveNext().timeout(const Duration(seconds: 15)),
          isTrue,
        );
        return jsonDecode(output.current) as Map<String, dynamic>;
      }

      final page = await command({
        'command': 'catalog',
        'query': 'network',
        'directoryId': directory.id,
        'tagId': tag.id,
        'limit': 1,
      });
      expect(page['total'], 1);
      expect(
        page['tags'],
        contains(equals({'id': unused.id, 'name': unused.name})),
      );
      expect((page['items'] as List).single['tags'], [
        {'id': tag.id, 'name': tag.name},
      ]);
      expect(
        (await command({'command': 'catalog', 'typeId': 'generic'}))['total'],
        2,
      );
      expect(
        (await command({'command': 'catalog', 'typeId': 'server'}))['total'],
        0,
      );
      expect(
        (await command({'command': 'catalog', 'typeId': 1}))['status'],
        'invalid_request',
      );
      expect(
        (await command({
          'command': 'catalog',
          'query': 'Public label',
        }))['total'],
        1,
      );
      expect((page['items'] as List).single['name'], 'Public server');
      expect(page.toString(), isNot(contains('PRIVATE-CLI-MARKER')));
      expect(
        (await command({
          'command': 'catalog',
          'query': 'PRIVATE-CLI-MARKER',
        }))['items'],
        isEmpty,
      );
      expect(
        (await command({
          'command': 'catalog',
          'offset': 1,
          'limit': 1,
        }))['items'],
        [containsPair('name', 'Other server')],
      );
      expect(
        (await command({'command': 'catalog', 'limit': 101}))['status'],
        'invalid_request',
      );
      expect(
        (await command({'command': 'catalog', 'offset': 'wrong'}))['status'],
        'invalid_request',
      );
      expect(
        (await command({
          'command': 'catalog',
          'query': ['wrong'],
        }))['status'],
        'invalid_request',
      );
      await command({'command': 'session', 'chatLabel': 'test'});
      final intent = <String, Object?>{
        'command': 'request',
        'operationId': 'cli-inspect-1',
        'purpose': 'use discovered host',
        'fields': [
          {'itemId': item.id, 'fieldId': item.fields.single.id},
        ],
      };
      final request = await command(intent);
      expect(await command(intent), request);
      expect(
        await command({
          'command': 'request-status',
          'operationId': 'cli-inspect-1',
        }),
        request,
      );
      expect(
        (await command({...intent, 'purpose': 'changed'}))['status'],
        'operation_conflict',
      );
      expect(service.owner.requests, hasLength(1));
      service.owner.approve(request['requestId'] as String, [
        FieldRef(item.id, item.fields.single.id),
      ]);
      await command({'command': 'claim', 'requestId': request['requestId']});
      expect(
        (await command({
          'command': 'read',
          'requestId': request['requestId'],
          'itemId': item.id,
          'fieldId': item.fields.single.id,
        }))['value'],
        'PRIVATE-CLI-MARKER',
      );
      await process.stdin.close();
      expect(await process.exitCode, 0);
      expect(await errors, isEmpty);
    },
  );
}
