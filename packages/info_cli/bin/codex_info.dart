import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/codex_association.dart';

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
    final input = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final association = await CodexAssociation.load(
      input['association'] as String,
      Platform.environment['CODEX_THREAD_ID'] ?? '',
    );
    client = AgentClient(association.port, sessionSecret: association.secret);
    if (input['command'] == 'read') {
      final claim = await client.execute({
        'command': 'claim',
        'requestId': input['requestId'],
      });
      result = claim['status'] == 'ok' ? await client.execute(input) : claim;
    } else if (input['command'] == 'session') {
      result = {'status': 'invalid_request'};
    } else {
      result = await client.execute(input);
    }
  } on Object {
    result = {'status': 'association_unavailable'};
  } finally {
    client?.close();
  }
  stdout.writeln(jsonEncode(result));
}
