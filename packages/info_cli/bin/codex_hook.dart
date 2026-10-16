import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/codex_association.dart';
import 'package:info_cli/codex_end_index.dart';

/// Receives documented SessionStart JSON on stdin. Never reads transcripts.
Future<void> main(List<String> args) async {
  final elapsed = Stopwatch()..start();
  AgentClient? client;
  try {
    var port = 47125;
    var root = CodexAssociation.defaultRoot();
    final connect = args.isNotEmpty && args.first == '--connect';
    if (connect) args = args.sublist(1);
    for (var i = 0; i < args.length; i += 2) {
      if (i + 1 >= args.length) throw const FormatException();
      if (args[i] == '--port') {
        port = int.parse(args[i + 1]);
      } else if (args[i] == '--state-root') {
        root = Directory(args[i + 1]);
      } else {
        throw const FormatException();
      }
    }
    if (port < 1 || port > 65535) throw const FormatException();
    final input = connect
        ? <String, dynamic>{
            'hook_event_name': 'SessionStart',
            'source': 'startup',
            'session_id': Platform.environment['CODEX_THREAD_ID'],
          }
        : await readInput().timeout(const Duration(seconds: 2));
    if (input['hook_event_name'] == 'SessionEnd') {
      final chat = input['session_id'];
      if (chat is! String || !validChatId(chat)) throw const FormatException();
      final rest = const Duration(seconds: 2) - elapsed.elapsed;
      final status = rest <= Duration.zero
          ? 'end_unavailable'
          : await CodexEndIndex(root).end(chat, timeout: rest);
      stdout.writeln(jsonEncode({'systemMessage': 'Agent Info: $status.'}));
      return;
    }
    if (input['hook_event_name'] == 'SubagentStart') {
      stdout.writeln(
        jsonEncode({
          'hookSpecificOutput': {
            'hookEventName': 'SubagentStart',
            'additionalContext':
                'Agent Info children use only a private child-bound association explicitly delegated by the parent with its existing proof. Ask the parent to delegate if missing. A parent/root chat ID cannot retrieve a capability. Child completion does not end the root authorization session.',
          },
        }),
      );
      return;
    }
    if (input['hook_event_name'] != 'SessionStart') {
      throw const FormatException();
    }
    final source = input['source'];
    if (source == 'compact' || source == 'resume') {
      stdout.writeln(
        jsonEncode({
          'hookSpecificOutput': {
            'hookEventName': 'SessionStart',
            'additionalContext':
                'Retain this chat\'s existing Agent Info association reference. If it was lost, do not search files or recover it by chat ID; ask to reconnect.',
          },
        }),
      );
      return;
    }
    if (!['startup', 'clear', 'fork'].contains(source)) {
      throw const FormatException();
    }
    final chat = input['session_id'];
    if (chat is! String || !validChatId(chat)) {
      throw const FormatException();
    }
    client = AgentClient(port);
    final result = await client.execute({
      'command': 'session',
      'chatLabel': 'Codex $chat',
    });
    if (result['status'] != 'ok') {
      stdout.writeln(
        jsonEncode({
          'systemMessage':
              'Agent Info: service_unavailable; no association was created. Start the information app and reconnect.',
        }),
      );
      return;
    }
    final reference = await CodexAssociation(
      chat,
      port,
      client.sessionSecret!,
    ).save(root);
    try {
      await CodexEndIndex(root).register(chat, port, client.endCapability!);
    } on Object {
      // This new session was never approved or delivered. Preserve other files.
      await File(reference).delete();
      rethrow;
    }
    stdout.writeln(
      jsonEncode({
        'hookSpecificOutput': {
          'hookEventName': 'SessionStart',
          'additionalContext': jsonEncode({
            'association': reference,
            'instruction':
                'Use this new private reference in this chat with codex_info stdin; supersedes inherited references. Delegate child-bound references only to this root chat\'s children using the existing proof. Keep capability files out of ordinary output, searches and commits. Use the agent-info-access Skill. No fields have been authorized.',
          }),
        },
      }),
    );
  } on Object {
    stdout.writeln(
      jsonEncode({
        'systemMessage':
            'Agent Info: association_unavailable; no existing grant was recovered. Reconnect after checking installation.',
      }),
    );
  } finally {
    client?.close();
  }
}

Future<Map<String, dynamic>> readInput() async {
  final bytes = <int>[];
  await for (final chunk in stdin) {
    if (bytes.length + chunk.length > 16384) throw const FormatException();
    bytes.addAll(chunk);
  }
  return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}
