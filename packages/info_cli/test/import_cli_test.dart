import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real CLI submits private multi-item import and reports decision without values',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
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
      Future<Map<String, dynamic>> command(Map<String, Object?> input) async {
        process.stdin.writeln(jsonEncode(input));
        expect(
          await output.moveNext().timeout(const Duration(seconds: 15)),
          isTrue,
        );
        return jsonDecode(output.current) as Map<String, dynamic>;
      }

      await command({
        'command': 'session',
        'externalChatId': 'synthetic-import-cli-test',
        'chatLabel': 'CLI import',
      });
      final receipt = await command({
        'command': 'import-submit',
        'title': '合成资料变更',
        'purpose': '执行合成验收的资料变更',
        'items': [
          {
            'name': 'First',
            'fields': [
              {
                'name': 'Notes',
                'value': 'PRIVATE-NOTE-${'x' * 17000}',
                'kind': 'textNote',
              },
            ],
            'suggestedDirectory': 'Servers',
          },
          {
            'name': 'Second',
            'fields': [
              {'name': 'Host', 'value': 'second.invalid'},
            ],
          },
        ],
      });
      expect(receipt['status'], 'pending');
      expect(receipt.toString(), isNot(contains('PRIVATE-NOTE')));
      expect((await command({'command': 'catalog'}))['items'], isEmpty);
      final id = receipt['proposalId'];
      expect(
        (await command({
          'command': 'import-status',
          'proposalId': id,
        }))['status'],
        'pending',
      );
      final proposal = service.owner.importProposals.single;
      await service.owner.confirmImport(
        proposal.id,
        proposal.version,
        proposal.items,
      );
      expect(
        (await command({
          'command': 'import-status',
          'proposalId': id,
        }))['status'],
        'confirmed',
      );
      final saved = await command({
        'command': 'import-status',
        'proposalId': id,
      });
      final directory = service.owner.directories.single;
      expect((saved['items'] as List).first['savedLocation'], {
        'directoryId': directory.id,
        'path': ['Servers'],
      });
      expect((saved['items'] as List).last['savedLocation'], {
        'directoryId': null,
        'path': [],
      });
      await service.owner.updateDirectory(directory.id, 'Renamed');
      expect(
        (await command({
          'command': 'import-status',
          'proposalId': id,
        }))['items'],
        saved['items'],
      );
      expect(saved.toString(), isNot(contains('PRIVATE-NOTE')));
      expect((await command({'command': 'catalog'}))['items'], hasLength(2));
      expect(
        (await command({
          'command': 'import-confirm',
          'proposalId': id,
        }))['status'],
        'invalid_request',
      );
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          'itemId': service.owner.information.first.id,
          'fieldId': service.owner.information.first.fields.first.id,
        }))['status'],
        'unauthorized',
      );
      final denied = await command({
        'command': 'import-submit',
        'title': '合成资料变更',
        'purpose': '执行合成验收的资料变更',
        'items': [
          {
            'name': 'Rejected',
            'fields': [
              {'name': 'Host', 'value': 'rejected.invalid'},
            ],
          },
        ],
      });
      await service.owner.rejectImport(denied['proposalId'] as String, 1);
      expect(
        (await command({
          'command': 'import-status',
          'proposalId': denied['proposalId'],
        }))['status'],
        'rejected',
      );
      expect(service.owner.information, hasLength(2));
      await process.stdin.close();
      expect(await process.exitCode, 0);
      expect(await errors, isEmpty);
    },
  );
}
