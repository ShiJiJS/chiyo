import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real CLI reads restored current content but no historical command, parameter or search reveals old values',
    () async {
      final core = InformationService.fictional();
      final server = await AgentServer.start(core.agent, port: 0);
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'bin/info.dart',
        '--port',
        '${server.port}',
      ]);
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      addTearDown(() async {
        await process.stdin.close();
        process.kill();
        await lines.cancel();
        await server.close();
        await core.close();
        expect(await errors, isEmpty);
      });
      Future<Map<String, dynamic>> command(Map<String, dynamic> input) async {
        process.stdin.writeln(jsonEncode(input));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 15)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      await command({
        'command': 'session',
        'externalChatId': 'synthetic-revisions-cli-test',
        'chatLabel': 'fictional history chat',
      });
      final request = await command({
        'command': 'request',
        'purpose': 'connect',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
        ],
      });
      final id = request['requestId'] as String;
      core.owner.approve(id, [const FieldRef('demo-server', 'host')]);
      await command({'command': 'claim', 'requestId': id});
      await core.owner.correctValue(
        const FieldRef('demo-server', 'host'),
        'NEW-CURRENT-94715.invalid',
      );
      final read = {
        'command': 'read',
        'requestId': id,
        'itemId': 'demo-server',
        'fieldId': 'host',
        'version': 1,
      };
      expect((await command(read))['value'], 'NEW-CURRENT-94715.invalid');
      expect(
        (await command({
          'command': 'catalog',
          'query': 'demo.example.invalid',
        }))['items'],
        isEmpty,
      );
      for (final name in ['history', 'revisions', 'restore-revision']) {
        final denied = await command({
          'command': name,
          'itemId': 'demo-server',
          'version': 1,
        });
        expect(denied['status'], isNot('ok'));
        expect(denied.toString(), isNot(contains('demo.example.invalid')));
      }
      final client = HttpClient();
      try {
        for (final path in ['/revisions', '/history', '/revision/restore']) {
          final req = await client.postUrl(
            Uri.parse('http://127.0.0.1:${server.port}$path'),
          );
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode({'itemId': 'demo-server', 'version': 1}));
          final response =
              jsonDecode(
                    await (await req.close()).transform(utf8.decoder).join(),
                  )
                  as Map;
          expect(response['status'], 'unauthorized');
          expect(response.toString(), isNot(contains('demo.example.invalid')));
        }
      } finally {
        client.close(force: true);
      }
      await core.owner.restoreRevision('demo-server', 1, 2);
      expect((await command(read))['value'], 'demo.example.invalid');
      expect(
        (await command({
          'command': 'catalog',
          'query': 'NEW-CURRENT-94715.invalid',
        }))['items'],
        isEmpty,
      );
    },
  );
}
