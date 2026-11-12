import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/codex_association.dart';
import 'package:info_cli/codex_end_index.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/automatic_connection.dart';

/// Receives documented SessionStart JSON on stdin. Never reads transcripts.
Future<void> main(List<String> args) async {
  final elapsed = Stopwatch()..start();
  // Reserve 100 ms for bounded output/termination within the 2 second callback.
  const operationBudget = Duration(milliseconds: 1900);
  AgentClient? client;
  try {
    var port = 47125;
    String? connectionFile;
    var explicitPort = false;
    var root = CodexAssociation.defaultRoot();
    final connect = args.isNotEmpty && args.first == '--connect';
    if (connect) args = args.sublist(1);
    for (var i = 0; i < args.length; i += 2) {
      if (i + 1 >= args.length) throw const FormatException();
      if (args[i] == '--port') {
        explicitPort = true;
        port = int.parse(args[i + 1]);
      } else if (args[i] == '--connection') {
        connectionFile = args[i + 1];
      } else if (args[i] == '--state-root') {
        root = Directory(args[i + 1]);
      } else {
        throw const FormatException();
      }
    }
    if (port < 1 || port > 65535 || explicitPort && connectionFile != null) {
      throw const FormatException();
    }
    final input = connect
        ? <String, dynamic>{
            'hook_event_name': 'SessionStart',
            'source': 'startup',
            'session_id': Platform.environment['CODEX_THREAD_ID'],
          }
        : await readInput(operationBudget - elapsed.elapsed);
    if (input['hook_event_name'] == 'SessionEnd') {
      final chat = input['session_id'];
      if (chat is! String || !validChatId(chat)) throw const FormatException();
      final rest = operationBudget - elapsed.elapsed;
      final status = rest <= Duration.zero
          ? 'end_unavailable'
          : await CodexEndIndex(root).end(chat, timeout: rest);
      stdout.writeln(jsonEncode({'systemMessage': 'Agent Info: $status.'}));
      // End has no work that may outlive the callback. Stop any timed-out OS
      // operation rather than leaving a pending HTTP/file Future in the VM.
      try {
        await stdout.flush().timeout(const Duration(milliseconds: 100));
      } on Object {
        /* Hook deadline wins. */
      }
      exit(0);
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
                'Retain this chat\'s existing Agent Info association reference. If it is missing or the session is confirmed invalid, automatically run this bundle\'s info-codex-hook --connect once with the configured connection and state root; no separate user confirmation is required. This creates a new unapproved session, never restores old grants. Do not search files or recover capabilities by chat ID. A transport failure alone keeps the original session and requests; denied or revoked requests must not be automatically resubmitted.',
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
    if (connectionFile == null && !explicitPort) {
      connectionFile = (await discoverAgentConnection())?.path;
    }
    final connection = connectionFile == null
        ? null
        : await AgentConnectionProfile.read(File(connectionFile).absolute);
    client = connection == null
        ? AgentClient(port)
        : AgentClient.remote(connection);
    final result = await client.openLifecycleSession('Codex $chat');
    if (result['status'] != 'ok') {
      stdout.writeln(
        jsonEncode({
          'systemMessage': connection == null
              ? 'Agent Info: service_unavailable; no association was created. Start the information app and reconnect.'
              : 'Agent Info: service_unavailable; no association was created. Check the information server connection and retry.',
        }),
      );
      return;
    }
    final reference = await CodexAssociation(
      chat,
      connection?.address.port ?? port,
      client.sessionSecret!,
      connection: connection,
    ).save(root);
    try {
      await CodexEndIndex(root).register(
        chat,
        connection?.address.port ?? port,
        client.endCapability!,
        connection: connection,
      );
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

Future<Map<String, dynamic>> readInput(Duration budget) async {
  final bytes = <int>[];
  final watch = Stopwatch()..start();
  final input = StreamIterator<List<int>>(stdin);
  try {
    while (true) {
      final remaining = budget - watch.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('input_deadline');
      if (!await input.moveNext().timeout(remaining)) break;
      final chunk = input.current;
      if (bytes.length + chunk.length > 16384) throw const FormatException();
      bytes.addAll(chunk);
    }
  } finally {
    await input.cancel();
  }
  return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}
