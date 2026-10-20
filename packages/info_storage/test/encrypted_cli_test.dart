import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real CLI obtains only approved persisted fields through the local service',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'encrypted-cli-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final keys = WindowsDatabaseKeyStore('${directory.path}/test.dpapi');
      var store = await EncryptedInformationRepository.open(
        directory.path,
        keys,
      );
      final owner = InformationService(repository: store).owner;
      final template = await owner.createTemplate('Server', '', [
        const TemplateFieldInput('Address', 'Host name'),
        const TemplateFieldInput(
          'Notes',
          'Operational notes',
          kind: FieldKind.textNote,
        ),
      ]);
      final item = await owner.createInformationFromTemplate(
        template.id,
        1,
        'Fictional server',
        '',
        {
          template.fields.first.id: 'fictional-reopened.invalid',
          template.fields.last.id: 'not-approved-fictional',
        },
      );
      await store.close();
      store = await EncryptedInformationRepository.open(directory.path, keys);
      addTearDown(store.close);
      final service = InformationService(repository: store);
      final server = await AgentServer.start(service.agent, port: 0);
      addTearDown(server.close);
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'bin/info.dart',
        '--port',
        '${server.port}',
      ], workingDirectory: '../info_cli');
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      addTearDown(() async {
        await process.stdin.close();
        process.kill();
        await lines.cancel();
        await service.close();
      });
      Future<Map<String, dynamic>> command(Map<String, dynamic> input) async {
        process.stdin.writeln(jsonEncode(input));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 20)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      final catalog = await command({'command': 'catalog'});
      expect(catalog.toString(), isNot(contains('fictional-reopened.invalid')));
      final listed = (catalog['items'] as List).single as Map<String, dynamic>;
      final publicFields = (listed['fields'] as List)
          .cast<Map<String, dynamic>>();
      expect(publicFields.last['kind'], 'textNote');
      await command({'command': 'session', 'chatLabel': 'encrypted fixture'});
      final ref = FieldRef(
        listed['id'] as String,
        publicFields.first['id'] as String,
      );
      final request = await command({
        'command': 'request',
        'purpose': 'test',
        'fields': [ref.toJson()],
      });
      final id = request['requestId'] as String;
      service.owner.approve(id, [ref]);
      await command({'command': 'claim', 'requestId': id});
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          ...ref.toJson(),
        }))['value'],
        'fictional-reopened.invalid',
      );
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          'itemId': item.id,
          'fieldId': item.fields.last.id,
        }))['status'],
        'unauthorized',
      );
      await process.stdin.close();
      expect(await process.exitCode, 0);
      expect(await errors, isEmpty);
    },
    skip: !Platform.isWindows,
  );
}
