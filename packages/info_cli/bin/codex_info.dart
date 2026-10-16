import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/codex_association.dart';
import 'package:info_core/protocol_json.dart';

/// One command per process, with a private reference passed on stdin, not argv.
Future<void> main(List<String> args) async {
  AgentClient? client;
  Map<String, dynamic> result;
  try {
    if (args.isNotEmpty) throw const FormatException();
    final bytes = <int>[];
    await for (final chunk in stdin) {
      if (bytes.length + chunk.length > 262144) throw const FormatException();
      bytes.addAll(chunk);
    }
    final input = decodeProtocolObject(utf8.decode(bytes));
    final commandInput = Map<String,dynamic>.of(input)..remove('association');
    final association = await CodexAssociation.load(
      input['association'] as String,
      Platform.environment['CODEX_THREAD_ID'] ?? '',
    );
    client = AgentClient(
      association.port,
      sessionSecret: association.secret,
      sourceAgent: 'Codex',
    );
    if (input['command'] == 'delegate') {
      final child = input['childChatId'];
      if (child is! String ||
          !validChatId(child) ||
          child == association.chatId) {
        throw const FormatException();
      }
      final live = await client.execute({'command': 'session-check'});
      if (live['status'] != 'ok') {
        result = live;
      } else {
        final reference = await CodexAssociation(
          child,
          association.port,
          association.secret,
          rootChatId: association.rootChatId,
        ).save(File(input['association'] as String).parent);
        result = {'status': 'ok', 'privateAssociation': reference};
      }
    } else if (input['command'] == 'read') {
      final claim = await client.execute({
        'command': 'claim',
        'requestId': input['requestId'],
      });
      result = claim['status'] == 'ok' ? await client.execute(commandInput) : claim;
    } else if (input['command'] == 'session') {
      result = {'status': 'invalid_request'};
    } else {
      result = await client.execute(commandInput);
    }
  } on Object {
    result = {'status': 'association_unavailable'};
  } finally {
    client?.close();
  }
  stdout.writeln(jsonEncode(result));
}
