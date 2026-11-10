import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real CLI submits explicit correction without old values or approval ability',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final item = await service.owner.createInformation('Server', 'Before', [
        const FieldInput('Host', 'Address', 'OLD-SECRET-CLI'),
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
        process.kill();
        await output.cancel();
        await server.close();
        service.close();
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
        'externalChatId': 'synthetic-update-cli-test',
        'chatLabel': 'CLI updater',
      });
      final catalog = (await command({'command': 'catalog'}))['items'] as List;
      final metadata = catalog.single as Map<String, dynamic>;
      final fields =
          (metadata['fields'] as List).single as Map<String, dynamic>;
      final submitted = await command({
        'command': 'update-submit',
        'title': '合成资料变更',
        'purpose': '执行合成验收的资料变更',
        'update': {
          'itemId': metadata['id'],
          'baseVersion': metadata['version'],
          'description': 'After',
          'changes': [
            {
              'operation': 'correct',
              'fieldId': fields['id'],
              'value': 'NEW-SECRET-CLI',
            },
          ],
        },
      });
      expect(submitted['status'], 'pending');
      expect(submitted.toString(), isNot(contains('SECRET')));
      final id = submitted['proposalId'];
      expect(
        (await command({
          'command': 'update-preview',
          'proposalId': id,
        }))['status'],
        'invalid_request',
      );
      expect(
        (await command({
          'command': 'update-confirm',
          'proposalId': id,
        }))['status'],
        'invalid_request',
      );
      expect(
        service.owner.information.single.fields.single.value,
        'OLD-SECRET-CLI',
      );
      await service.owner.confirmUpdate(id as String, 1);
      final status = await command({
        'command': 'update-status',
        'proposalId': id,
      });
      expect(status['status'], 'confirmed');
      expect(status.toString(), isNot(contains('SECRET')));
      final ref = {'itemId': item.id, 'fieldId': item.fields.single.id};
      final requested = await command({
        'command': 'request',
        'purpose': 'connect',
        'fields': [ref],
      });
      service.owner.approve(requested['requestId'] as String, [
        FieldRef(item.id, item.fields.single.id),
      ]);
      await command({'command': 'claim', 'requestId': requested['requestId']});
      final read = await command({
        'command': 'read',
        'requestId': requested['requestId'],
        ...ref,
      });
      expect(read['value'], 'NEW-SECRET-CLI');
      await process.stdin.close();
      expect(await process.exitCode, 0);
      expect(await errors, isEmpty);
    },
  );
}
