import 'dart:convert';
import 'dart:io';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a stalled end call stops within its deadline and retains capabilities for a later retry',
    () async {
      final core = InformationService.fictional();
      var server = await AgentServer.start(core.agent, port: 0);
      final port = server.port;
      final root = await Directory.systemTemp.createTemp('info-deadline-test-');
      HttpServer? stalled;
      addTearDown(() async {
        await stalled?.close(force: true);
        await server.close();
        await core.close();
        await root.delete(recursive: true);
      });
      final start = await invoke(
        'bin/codex_hook.dart',
        {
          'hook_event_name': 'SessionStart',
          'source': 'startup',
          'session_id': 'deadline-root',
        },
        args: ['--port', '$port', '--state-root', root.path],
      );
      final reference = jsonDecode(
        start['hookSpecificOutput']['additionalContext'] as String,
      )['association'];
      final requested = await invoke('bin/codex_info.dart', {
        'association': reference,
        'command': 'request',
        'purpose': 'Address',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
        ],
      }, chat: 'deadline-root');
      await server.close();
      stalled = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      stalled.listen((request) {
        request.drain<void>();
      }); // Deliberately never responds.
      final watch = Stopwatch()..start();
      final failed = await invoke(
        'bin/codex_hook.dart',
        {'hook_event_name': 'SessionEnd', 'session_id': 'deadline-root'},
        args: ['--state-root', root.path],
      );
      expect(failed['systemMessage'], contains('end_unavailable'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      expect(core.owner.requests.single.state, AccessRequestState.pending);
      await stalled.close(force: true);
      stalled = null;
      server = await AgentServer.start(core.agent, port: port);
      final retried = await invoke(
        'bin/codex_hook.dart',
        {'hook_event_name': 'SessionEnd', 'session_id': 'deadline-root'},
        args: ['--state-root', root.path],
      );
      expect(retried['systemMessage'], contains('ended'));
      expect(core.owner.requests.single.id, requested['requestId']);
      expect(core.owner.requests.single.state, AccessRequestState.cancelled);
    },
  );
  test(
    'root SessionEnd ends every startup generation and its delegated child without reading a transcript',
    () async {
      final core = InformationService.fictional();
      final server = await AgentServer.start(core.agent, port: 0);
      final root = await Directory.systemTemp.createTemp('info-end-test-');
      addTearDown(() async {
        await server.close();
        await core.close();
        await root.delete(recursive: true);
      });
      final refs = <String>[];
      final ids = <String>[];
      for (var i = 0; i < 2; i++) {
        final start = await invoke(
          'bin/codex_hook.dart',
          {
            'hook_event_name': 'SessionStart',
            'source': 'startup',
            'session_id': 'same-root',
          },
          args: ['--port', '${server.port}', '--state-root', root.path],
        );
        final reference =
            jsonDecode(
                  start['hookSpecificOutput']['additionalContext'] as String,
                )['association']
                as String;
        refs.add(reference);
        final request = await invoke('bin/codex_info.dart', {
          'association': reference,
          'command': 'request',
          'purpose': 'Address',
          'fields': [
            {'itemId': 'demo-server', 'fieldId': 'host'},
          ],
        }, chat: 'same-root');
        ids.add(request['requestId'] as String);
        core.owner.approve(ids.last, [const FieldRef('demo-server', 'host')]);
      }
      final child = await invoke('bin/codex_info.dart', {
        'association': refs.first,
        'command': 'delegate',
        'childChatId': 'child',
      }, chat: 'same-root');
      final guidance = await invoke(
        'bin/codex_hook.dart',
        {
          'hook_event_name': 'SubagentStart',
          'session_id': 'same-root',
          'agent_id': 'child',
        },
        args: ['--state-root', root.path],
      );
      expect(
        guidance['hookSpecificOutput']['additionalContext'],
        isNot(contains(refs.first)),
      );
      for (final event in ['Stop', 'Interrupt', 'SubagentStop']) {
        await invoke(
          'bin/codex_hook.dart',
          {'hook_event_name': event, 'session_id': 'same-root'},
          args: ['--state-root', root.path],
        );
      }
      expect(
        (await invoke('bin/codex_info.dart', {
          'association': child['privateAssociation'],
          'command': 'read',
          'requestId': ids.first,
          'itemId': 'demo-server',
          'fieldId': 'host',
        }, chat: 'child'))['status'],
        'ok',
      );
      final ended = await invoke(
        'bin/codex_hook.dart',
        {
          'hook_event_name': 'SessionEnd',
          'session_id': 'same-root',
          'reason': 'other',
          'transcript_path': '${root.path}/nonexistent',
        },
        args: ['--state-root', root.path],
      );
      expect(ended['systemMessage'], contains('ended'));
      for (var i = 0; i < refs.length; i++) {
        expect(
          (await invoke('bin/codex_info.dart', {
            'association': refs[i],
            'command': 'claim',
            'requestId': ids[i],
          }, chat: 'same-root'))['status'],
          'unauthorized',
        );
      }
      expect(
        (await invoke('bin/codex_info.dart', {
          'association': child['privateAssociation'],
          'command': 'read',
          'requestId': ids.first,
          'itemId': 'demo-server',
          'fieldId': 'host',
        }, chat: 'child'))['status'],
        'unauthorized',
      );
      expect(
        core.owner.requests.every((r) => r.state == AccessRequestState.revoked),
        isTrue,
      );
      final duplicate = await invoke(
        'bin/codex_hook.dart',
        {'hook_event_name': 'SessionEnd', 'session_id': 'same-root'},
        args: ['--state-root', root.path],
      );
      expect(duplicate['systemMessage'], contains('no_active_session'));
    },
  );
  test(
    'a parent proof delegates only the same grant and deadline to its intended child',
    () async {
      final core = InformationService.fictional();
      final server = await AgentServer.start(core.agent, port: 0);
      final root = await Directory.systemTemp.createTemp('info-child-test-');
      addTearDown(() async {
        await server.close();
        await core.close();
        await root.delete(recursive: true);
      });
      final start = await invoke(
        'bin/codex_hook.dart',
        {
          'hook_event_name': 'SessionStart',
          'source': 'startup',
          'session_id': 'root-chat',
        },
        args: ['--port', '${server.port}', '--state-root', root.path],
      );
      final parent = jsonDecode(
        start['hookSpecificOutput']['additionalContext'] as String,
      )['association'];
      final request = await invoke('bin/codex_info.dart', {
        'association': parent,
        'command': 'request',
        'purpose': 'Address',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
        ],
      }, chat: 'root-chat');
      final id = request['requestId'] as String;
      core.owner.approve(id, [const FieldRef('demo-server', 'host')]);
      final parentGrant = await invoke('bin/codex_info.dart', {
        'association': parent,
        'command': 'claim',
        'requestId': id,
      }, chat: 'root-chat');
      final delegated = await invoke('bin/codex_info.dart', {
        'association': parent,
        'command': 'delegate',
        'childChatId': 'child-chat',
      }, chat: 'root-chat');
      expect(delegated['status'], 'ok');
      final child = delegated['privateAssociation'];
      expect(child, isNot(parent));
      expect(
        (await invoke('bin/codex_info.dart', {
          'association': child,
          'command': 'claim',
          'requestId': id,
        }, chat: 'child-chat'))['expiresAt'],
        parentGrant['expiresAt'],
      );
      for (final field in ['host', 'username']) {
        final value = await invoke('bin/codex_info.dart', {
          'association': child,
          'command': 'read',
          'requestId': id,
          'itemId': 'demo-server',
          'fieldId': field,
        }, chat: 'child-chat');
        expect(value['status'], field == 'host' ? 'ok' : 'unauthorized');
      }
      expect(
        (await invoke('bin/codex_info.dart', {
          'association': child,
          'command': 'claim',
          'requestId': id,
        }, chat: 'unrelated-chat'))['status'],
        'association_unavailable',
      );
      expect(
        (await invoke('bin/codex_info.dart', {
          'association': 'root-chat',
          'command': 'delegate',
          'childChatId': 'other-child',
        }, chat: 'root-chat'))['status'],
        'association_unavailable',
      );
      expect(core.owner.requests, hasLength(1));
    },
  );
  if (Platform.isWindows && Platform.environment['INFO_TEST_BUNDLE'] != null) {
    test(
      'the generated Windows SessionEnd command terminates a live session within its 3 second hook timeout',
      () async {
        final bundle = Platform.environment['INFO_TEST_BUNDLE']!;
        final config = jsonDecode(
          await File('$bundle/hooks.json').readAsString(),
        );
        expect((config['hooks'] as Map).keys.toSet(), {
          'SessionStart',
          'SubagentStart',
          'SessionEnd',
        });
        final definition = config['hooks']['SessionEnd'][0]['hooks'][0];
        expect(definition['timeout'], 3);
        final core = InformationService.fictional();
        final server = await AgentServer.start(core.agent, port: 0);
        final local = await Directory.systemTemp.createTemp(
          'info-rendered-end-',
        );
        addTearDown(() async {
          await server.close();
          await core.close();
          await local.delete(recursive: true);
        });
        final start = await invoke(
          'bin/codex_hook.dart',
          {
            'hook_event_name': 'SessionStart',
            'source': 'startup',
            'session_id': 'rendered-end',
          },
          args: [
            '--port',
            '${server.port}',
            '--state-root',
            '${local.path}/AgentInfo/codex',
          ],
        );
        final reference = jsonDecode(
          start['hookSpecificOutput']['additionalContext'] as String,
        )['association'];
        await invoke('bin/codex_info.dart', {
          'association': reference,
          'command': 'request',
          'purpose': 'Address',
          'fields': [
            {'itemId': 'demo-server', 'fieldId': 'host'},
          ],
        }, chat: 'rendered-end');
        final command = (definition['commandWindows'] as String).split(' ');
        final watch = Stopwatch()..start();
        final process = await Process.start(
          command.first,
          command.sublist(1),
          environment: {'LOCALAPPDATA': local.path},
        );
        final output = process.stdout.transform(utf8.decoder).join();
        final errors = process.stderr.transform(utf8.decoder).join();
        process.stdin.writeln(
          jsonEncode({
            'hook_event_name': 'SessionEnd',
            'session_id': 'rendered-end',
          }),
        );
        await process.stdin.close();
        expect(await process.exitCode.timeout(const Duration(seconds: 3)), 0);
        expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
        expect(await errors, isEmpty);
        expect(jsonDecode(await output)['systemMessage'], contains('ended'));
        expect(core.owner.requests.single.state, AccessRequestState.cancelled);
      },
    );
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
      expect(
        invalid['hookSpecificOutput']['additionalContext'],
        contains('private child-bound association'),
      );
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
      expect(
        await root.list().length,
        2,
      ); // Association plus the end-only index directory.
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
  expect(raw, isNot(contains('"endCapability"')));
  return jsonDecode(raw) as Map<String, dynamic>;
}
