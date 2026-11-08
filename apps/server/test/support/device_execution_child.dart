import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_remote/agent_connection.dart';

// Private bootstrap travels through stdin, never process arguments or disk.
Future<void> main() async {
  final input =
      jsonDecode(await stdin.transform(utf8.decoder).join())
          as Map<String, dynamic>;
  final client = AgentClient.remote(
    AgentConnectionProfile.fromPrivateJson(
      input['connection'] as Map<String, dynamic>,
    ),
    sessionSecret: input['sessionSecret'] as String,
    deviceFileStateDirectory: Directory(input['deviceFiles'] as String),
  );
  try {
    stdout.writeln(
      jsonEncode(
        await client.execute(input['operation'] as Map<String, dynamic>),
      ),
    );
    await stdout.flush();
    await client.drainCredentialExecutions();
  } finally {
    client.close();
  }
}
