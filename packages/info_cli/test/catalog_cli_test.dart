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

      final empty = await service.owner.createDirectory(
        'Empty child',
        parentId: directory.id,
      );
      final directories = await command({'command': 'directory-list'});
      expect(directories['status'], 'ok');
      expect(directories['complete'], true);
      expect(directories['total'], 2);
      expect((directories['directories'] as List).last['pathIds'], [
        directory.id,
        empty.id,
      ]);
      expect(jsonEncode(directories), isNot(contains('PRIVATE-CLI-MARKER')));
      expect(
        (await command({'command': 'directory-list', 'limit': 1}))['status'],
        'invalid_request',
      );
      expect(
        (await command({'command': 'capabilities'}))['capabilities'],
        contains('information-directory-discovery.v1'),
      );
      final sibling = await service.owner.createDirectory('New root');
      final selection = LibrarySelection(directoryIds: [sibling.id]),
          position = LibraryMovePosition(
            LibraryEntryRef('directory', directory.id),
          );
      final placement = await service.owner.previewLibraryMove(
        selection,
        null,
        position: position,
      );
      await service.owner.moveLibrarySelection(
        'cli-order-fixture',
        selection,
        null,
        placement.token,
        position: position,
      );
      final ordered = await command({'command': 'directory-list'});
      final roots = (ordered['directories'] as List)
          .where((d) => d['parentId'] == null)
          .toList();
      expect(roots.map((d) => d['id']), [sibling.id, directory.id]);
      expect(roots.map((d) => d['order']), [0, 1]);
      final removal = await service.owner.previewLibraryRecycle(selection);
      await service.owner.recycleLibrarySelection(
        'cli-recycle-fixture',
        selection,
        removal.token,
      );
      final current = await command({'command': 'directory-list'});
      expect(
        (current['directories'] as List).any((d) => d['id'] == sibling.id),
        false,
      );
      expect((current['directories'] as List).first['order'], 0);

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
