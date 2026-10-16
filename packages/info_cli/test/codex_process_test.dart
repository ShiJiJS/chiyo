import 'dart:convert';
import 'dart:io';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  if (Platform.isWindows && Platform.environment['INFO_TEST_BUNDLE'] != null) {
    test(
      'rendered Windows hook command forwards documented JSON stdin',
      () async {
        final bundle = Platform.environment['INFO_TEST_BUNDLE']!;
        final config = jsonDecode(
          await File('$bundle/hooks.json').readAsString(),
        );
        final command =
            (config['hooks']['SessionStart'][0]['hooks'][0]['commandWindows']
                    as String)
                .split(' ');
        final process = await Process.start(command.first, command.sublist(1));
        final output = process.stdout.transform(utf8.decoder).join();
        final errors = process.stderr.transform(utf8.decoder).join();
        process.stdin.writeln(
          jsonEncode({
            'hook_event_name': 'SessionStart',
            'source': 'compact',
            'session_id': 'chat',
          }),
        );
        await process.stdin.close();
        expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0);
        expect(await errors, isEmpty);
        final result = jsonDecode(await output);
        expect(
          (result['hookSpecificOutput']['additionalContext'] as String)
              .contains('Retain'),
          true,
        );
      },
    );
  }

  test(
    'explicit reconnect creates a fresh association without recovering grants',
    () async {
      final core = InformationService.fictional();
      final server = await AgentServer.start(core.agent, port: 0);
      final root = await Directory.systemTemp.createTemp('info-codex-test-');
      addTearDown(() async {
        await server.close();
        await core.close();
        await root.delete(recursive: true);
      });
      final hook = await invoke(
        'bin/codex_hook.dart',
        {},
        chat: 'reconnect-chat',
        args: [
          '--connect',
          '--port',
          '${server.port}',
          '--state-root',
          root.path,
        ],
      );
      final reference = jsonDecode(
        hook['hookSpecificOutput']['additionalContext'] as String,
      )['association'];
      final result = await invoke('bin/codex_info.dart', {
        'association': reference,
        'command': 'claim',
        'requestId': 'known-request',
      }, chat: 'reconnect-chat');
      expect(result['status'], 'unauthorized');
      expect(core.owner.requests, isEmpty);
    },
  );

  test(
    'known chat and request IDs cannot recover a capability, even by restarting the hook',
    () async {
      final core = InformationService.fictional();
      final server = await AgentServer.start(core.agent, port: 0);
      final root = await Directory.systemTemp.createTemp('info-codex-test-');
      addTearDown(() async {
        await server.close();
        await core.close();
        await root.delete(recursive: true);
      });
      Future<String> start(String source) async {
        final hook = await invoke(
          'bin/codex_hook.dart',
          {
            'hook_event_name': 'SessionStart',
            'source': source,
            'session_id': 'known-chat',
          },
          args: ['--port', '${server.port}', '--state-root', root.path],
        );
        return jsonDecode(
              hook['hookSpecificOutput']['additionalContext'] as String,
            )['association']
            as String;
      }

      final first = await start('startup');
      final request = await invoke('bin/codex_info.dart', {
        'association': first,
        'command': 'request',
        'purpose': 'demo',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
        ],
      }, chat: 'known-chat');
      final id = request['requestId'] as String;
      core.owner.approve(id, [const FieldRef('demo-server', 'host')]);
      for (final source in ['startup', 'fork', 'clear']) {
        final other = await start(source);
        expect(other, isNot(first));
        expect(
          (await invoke('bin/codex_info.dart', {
            'association': other,
            'command': 'claim',
            'requestId': id,
          }, chat: 'known-chat'))['status'],
          'unauthorized',
        );
      }
      expect(core.owner.requests.length, 1);
      await core.close();
      expect(
        (await invoke('bin/codex_info.dart', {
          'association': first,
          'command': 'claim',
          'requestId': id,
        }, chat: 'known-chat'))['status'],
        'unauthorized',
      );
    },
  );

  test(
    'malformed associations and hook input fail without leaking input or reading transcripts',
    () async {
      expect(
        await invoke('bin/codex_info.dart', {
          'association': 'known-chat',
          'command': 'claim',
          'requestId': 'known-request',
        }, chat: 'known-chat'),
        {'status': 'association_unavailable'},
      );
      final root = await Directory.systemTemp.createTemp('info-codex-test-');
      addTearDown(() => root.delete(recursive: true));
      final transcript = File('${root.path}/private-transcript');
      // A nonexistent transcript is deliberate: the adapter must not read it.
      final compact = await invoke(
        'bin/codex_hook.dart',
        {
          'hook_event_name': 'SessionStart',
          'source': 'compact',
          'session_id': 'known-chat',
          'transcript_path': transcript.path,
        },
        args: ['--state-root', root.path],
      );
      expect(
        compact['hookSpecificOutput']['additionalContext'],
        contains('Retain'),
      );
      expect(await root.list().length, 0);
      final invalid = await invoke(
        'bin/codex_hook.dart',
        {'hook_event_name': 'SubagentStart', 'session_id': 'known-chat'},
        args: ['--state-root', root.path],
      );
      expect(invalid['systemMessage'], contains('association_unavailable'));
      expect(await root.list().length, 0);
    },
  );

  test(
    'hook association supports distinct CLI processes without reapproval',
    () async {
      final core = InformationService.fictional();
      final server = await AgentServer.start(core.agent, port: 0);
      final root = await Directory.systemTemp.createTemp('info-codex-test-');
      addTearDown(() async {
        await server.close();
        await core.close();
        await root.delete(recursive: true);
      });
      final hook = await invoke(
        'bin/codex_hook.dart',
        {
          'hook_event_name': 'SessionStart',
          'source': 'startup',
          'session_id': 'chat-a',
        },
        args: ['--port', '${server.port}', '--state-root', root.path],
      );
      expect(
        hook.containsKey('hookSpecificOutput'),
        true,
        reason: jsonEncode(hook),
      );
      final context =
          jsonDecode(hook['hookSpecificOutput']['additionalContext'] as String)
              as Map<String, dynamic>;
      final reference = context['association'] as String;
      Future<Map<String, dynamic>> call(
        Map<String, dynamic> command, {
        String chat = 'chat-a',
        String? association,
      }) => invoke('bin/codex_info.dart', {
        'association': association ?? reference,
        ...command,
      }, chat: chat);
      final request = await call({
        'command': 'request',
        'purpose': 'test',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
        ],
      });
      expect(request['status'], 'pending');
      final id = request['requestId'] as String;
      core.owner.approve(id, [const FieldRef('demo-server', 'host')]);
      final claim = await call({'command': 'claim', 'requestId': id});
      expect(claim['status'], 'ok');
      final resumed = await invoke(
        'bin/codex_hook.dart',
        {
          'hook_event_name': 'SessionStart',
          'source': 'resume',
          'session_id': 'chat-a',
        },
        args: ['--port', '${server.port}', '--state-root', root.path],
      );
      expect(
        resumed['hookSpecificOutput']['additionalContext'],
        contains('Retain'),
      );
      expect(await root.list().length, 1);
      for (var i = 0; i < 2; i++) {
        expect(
          await call({
            'command': 'read',
            'requestId': id,
            'itemId': 'demo-server',
            'fieldId': 'host',
          }),
          {'status': 'ok', 'value': 'demo.example.invalid'},
        );
      }
      expect(core.owner.requests.length, 1);
      expect(
        (await call({'command': 'claim', 'requestId': id}))['expiresAt'],
        claim['expiresAt'],
      );
      expect(
        (await call({
          'command': 'claim',
          'requestId': id,
        }, chat: 'chat-b'))['status'],
        'association_unavailable',
      );
      expect(
        (await call({
          'command': 'claim',
          'requestId': id,
        }, association: 'chat-a'))['status'],
        'association_unavailable',
      );
      core.owner.revoke(id);
      expect(
        (await call({
          'command': 'read',
          'requestId': id,
          'itemId': 'demo-server',
          'fieldId': 'host',
        }))['status'],
        'unauthorized',
      );
    },
  );
}

Future<Map<String, dynamic>> invoke(
  String bin,
  Map<String, dynamic> input, {
  List<String> args = const [],
  String? chat,
}) async {
  final bundle = Platform.environment['INFO_TEST_BUNDLE'];
  final executable = bundle == null
      ? Platform.resolvedExecutable
      : '$bundle/${bin.contains('hook') ? 'info-codex-hook' : 'info-codex'}${Platform.isWindows ? '.exe' : ''}';
  final process = await Process.start(
    executable,
    [
      if (bundle == null) ...['run', bin],
      ...args,
    ],
    environment: {'CODEX_THREAD_ID': chat ?? ''},
  );
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  process.stdin.writeln(jsonEncode(input));
  await process.stdin.close();
  expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0);
  expect(await err, isEmpty);
  final raw = await out;
  expect(raw, isNot(contains('sessionSecret')));
  expect(raw, isNot(contains('"token"')));
  return jsonDecode(raw) as Map<String, dynamic>;
}
