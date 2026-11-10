import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'both CLI help entry points work without a connection or private association',
    () async {
      for (final entry in ['info.dart', 'codex_info.dart']) {
        final result = await Process.run(Platform.resolvedExecutable, [
          'run',
          'bin/$entry',
          '--help',
        ]);
        expect(result.exitCode, 0);
        final help = jsonDecode(result.stdout as String) as Map;
        expect(help['status'], 'ok');
        expect(
          (help['submissionFields'] as Map).keys,
          containsAll(['title', 'agentName', 'externalChatId', 'purpose']),
        );
        expect(help.containsKey('association'), false);
      }
    },
  );
  test(
    'real CLI process claims only approved fields without printing credentials',
    () async {
      final core = InformationService.fictional();
      final server = await AgentServer.start(core.agent, port: 0);
      final delivered = Platform.environment['INFO_TEST_DELIVERY'];
      final process = await Process.start(
        delivered == null
            ? Platform.resolvedExecutable
            : '$delivered/cli/info.exe',
        [
          if (delivered == null) ...['run', 'bin/info.dart'],
          '--port',
          '${server.port}',
        ],
      );
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
      expect(
        (await command({'command': 'help'}))['submissionFields'],
        contains('title'),
      );
      final session = await command({
        'command': 'session',
        'chatLabel': 'chat',
        'externalChatId': 'synthetic-cli-chat',
      });
      expect(session, {'status': 'ok'});
      final incomplete = await command({
        'command': 'import-submit',
        'items': [],
      });
      expect(incomplete['errorCode'], 'invalid_submission_metadata');
      expect(incomplete['fieldErrors'], contains('title'));
      expect(core.owner.importProposals, isEmpty);
      final request = await command({
        'command': 'request',
        'agentName': 'Synthetic process Agent',
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
      expect(core.owner.requests.single.agentName, 'Synthetic process Agent');
      expect(core.owner.requests.single.externalChatId, 'synthetic-cli-chat');
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
      final beforeRevoke = await core.owner.history();
      expect(beforeRevoke.requests.single.agentName, 'Synthetic process Agent');
      expect(beforeRevoke.grants.single.requestId, id);
      expect(beforeRevoke.accesses.map((record) => record.outcome), [
        AccessOutcome.allowed,
        AccessOutcome.unauthorized,
      ]);
      await core.owner.revokeFromHistory(beforeRevoke.grants.single.id);
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          'itemId': 'demo-server',
          'fieldId': 'host',
        }))['status'],
        'unauthorized',
      );
      final afterRevoke = await core.owner.history();
      expect(
        afterRevoke.grants.single.events.last.kind,
        GrantEventKind.revoked,
      );
      expect(afterRevoke.accesses.last.grantId, afterRevoke.grants.single.id);
      expect(
        afterRevoke.toJson().toString(),
        isNot(contains('demo.example.invalid')),
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
