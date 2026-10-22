import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';

// Public protocol driver only. The ordinary installed app and its Keychain
// are unmodified. Private session/grant capabilities stay inside AgentClient.
Future<void> main() async {
  final client = AgentClient(47125, hostedCredentialExecutions: true);
  try {
    await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final input = Map<String, dynamic>.from(jsonDecode(line) as Map);
      if (input['command'] == 'qa-close') break;
      final result = await client.execute(input);
      await File('/Users/jiangxinyi/Documents/Project/agent-info/build/macos-adaptation/issue44-ordinary-ssh-20261023/public-client.jsonl').writeAsString(jsonEncode({'at': DateTime.now().toUtc().toIso8601String(), 'input': input, 'result': result}) + '\n', mode: FileMode.append, flush: true);
      stdout.writeln(jsonEncode(result));
    }
  } finally {
    await client.drainCredentialExecutions();
    client.close();
  }
}
