import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real CLI process claims only approved fields without printing credentials',
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
        core.close();
      });
      Future<Map<String, dynamic>> command(Map<String, dynamic> input) async {
        process.stdin.writeln(jsonEncode(input));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 15)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      expect((await command({'command': 'catalog'}))['status'], 'ok');
      final session = await command({
        'command': 'session',
        'chatLabel': 'chat',
      });
      expect(session, {'status': 'ok'});
      final request = await command({
        'command': 'request',
        'purpose': 'demo',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
          {'itemId': 'demo-server', 'fieldId': 'username'},
        ],
      });
      final id = request['requestId'] as String;
      expect(request['status'], 'pending');
      expect(
        (await command({'command': 'claim', 'requestId': id}))['status'],
        'pending',
      );
      final waited = await command({
        'command': 'wait',
        'requestId': id,
        'timeoutMs': 20,
      });
      expect(waited['status'], 'pending');
      expect(waited['waitTimedOut'], isTrue);
      expect(waited['requestId'], id);
      expect(core.owner.requests, hasLength(1));
      core.owner.approve(id, [const FieldRef('demo-server', 'host')]);
      expect(
        (await command({
          'command': 'wait',
          'requestId': id,
          'timeoutMs': 0,
        }))['status'],
        'approved',
      );
      final claim = await command({'command': 'claim', 'requestId': id});
      expect(claim['status'], 'ok');
      expect(claim.containsKey('token'), isFalse);
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          'itemId': 'demo-server',
          'fieldId': 'host',
        }))['value'],
        'demo.example.invalid',
      );
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          'itemId': 'demo-server',
          'fieldId': 'username',
        }))['status'],
        'unauthorized',
      );
      core.owner.revoke(id);
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          'itemId': 'demo-server',
          'fieldId': 'host',
        }))['status'],
        'unauthorized',
      );
      await server.close();
      expect(
        (await command({'command': 'catalog'}))['status'],
        'service_unavailable',
      );
      await process.stdin.close();
      expect(await process.exitCode, 0);
      expect(await errors, isEmpty);
    },
  );
}
