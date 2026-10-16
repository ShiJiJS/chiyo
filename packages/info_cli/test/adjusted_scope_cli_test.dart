import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real CLI learns and reads the owner-adjusted range and fixed expiry',
    () async {
      var now = DateTime.utc(2026, 10, 16);
      final core = InformationService(
        repository: MemoryInformationRepository(),
        clock: () => now,
      );
      final first = await core.owner.createInformation('Server A', '', [
        const FieldInput('Address', '', 'a.invalid'),
      ]);
      final second = await core.owner.createInformation('Server B', '', [
        const FieldInput('Private notes', '', 'Connect through test network'),
      ]);
      final requested = FieldRef(first.id, first.fields.single.id);
      final selected = FieldRef(second.id, second.fields.single.id);
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

      await command({'command': 'session', 'chatLabel': 'chat'});
      final request = await command({
        'command': 'request',
        'purpose': 'Need connection information',
        'fields': [requested.toJson()],
      });
      final id = request['requestId'] as String;
      core.owner.approve(id, [selected], lifetime: const Duration(minutes: 30));
      final claim = await command({'command': 'claim', 'requestId': id});
      expect(claim['status'], 'ok');
      expect(claim['fields'], [selected.toJson()]);
      expect(claim['expiresAt'], '2026-10-16T00:30:00.000Z');
      expect(
        claim['scopeNotice'],
        contains('New items and fields require a new request'),
      );
      expect(claim.containsKey('token'), isFalse);
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          ...selected.toJson(),
        }))['value'],
        'Connect through test network',
      );
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          ...requested.toJson(),
        }))['status'],
        'unauthorized',
      );
      now = now.add(const Duration(minutes: 30));
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          ...selected.toJson(),
        }))['status'],
        'unauthorized',
      );
      await process.stdin.close();
      expect(await process.exitCode, 0);
      expect(await errors, isEmpty);
    },
  );
}
