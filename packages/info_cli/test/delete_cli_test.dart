import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real CLI proposes deletion then old token stays denied after owner restore',
    () async {
      final service = InformationService.fictional();
      final server = await AgentServer.start(service.agent, port: 0);
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
        process.kill();
        await lines.cancel();
        await server.close();
        await Future.sync(service.close);
      });
      Future<Map<String, dynamic>> command(Map<String, Object?> value) async {
        process.stdin.writeln(jsonEncode(value));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 15)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      await command({'command': 'session', 'chatLabel': 'deleting chat'});
      final requested = await command({
        'command': 'request',
        'purpose': 'read',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
        ],
      });
      service.owner.approve(requested['requestId'] as String, [
        const FieldRef('demo-server', 'host'),
      ]);
      await command({'command': 'claim', 'requestId': requested['requestId']});
      final proposal = await command({
        'command': 'delete-submit',
        'itemId': 'demo-server',
        'baseVersion': 1,
        'fieldId': 'host',
      });
      expect(proposal['status'], 'pending');
      final id = proposal['proposalId'] as String;
      expect(
        (await command({
          'command': 'delete-confirm',
          'proposalId': id,
        }))['status'],
        'invalid_request',
      );
      expect(
        (await command({'command': 'recycle-list'}))['status'],
        'invalid_request',
      );
      expect(
        (await command({
          'command': 'read',
          'requestId': requested['requestId'],
          'itemId': 'demo-server',
          'fieldId': 'host',
        }))['value'],
        'demo.example.invalid',
      );
      final entry = await service.owner.confirmDelete(id, 1);
      expect(
        (await command({
          'command': 'delete-status',
          'proposalId': id,
        }))['status'],
        'confirmed',
      );
      final restored = await service.owner.restoreRecycled(entry.id);
      final restoredHost = restored.fields
          .firstWhere((f) => f.id != 'username')
          .id;
      final denied = await command({
        'command': 'read',
        'requestId': requested['requestId'],
        'itemId': 'demo-server',
        'fieldId': 'host',
      });
      expect(denied, {'status': 'unauthorized'});
      final fresh = await command({
        'command': 'request',
        'purpose': 'restored',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': restoredHost},
        ],
      });
      service.owner.approve(fresh['requestId'] as String, [
        FieldRef('demo-server', restoredHost),
      ]);
      await command({'command': 'claim', 'requestId': fresh['requestId']});
      expect(
        (await command({
          'command': 'read',
          'requestId': fresh['requestId'],
          'itemId': 'demo-server',
          'fieldId': restoredHost,
        }))['value'],
        'demo.example.invalid',
      );
      await process.stdin.close();
      expect(await process.exitCode, 0);
      expect(await errors, isEmpty);
    },
  );
}
