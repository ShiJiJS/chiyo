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
      final result = await client.execute(input);
      await File('${File.fromUri(Platform.script).parent.path}/public-client.jsonl').writeAsString(jsonEncode({'at': DateTime.now().toUtc().toIso8601String(), 'input': input, 'result': result}) + '\n', mode: FileMode.append, flush: true);
      stdout.writeln(jsonEncode(result));
    }
  } finally {
    client.close();
  }
}
