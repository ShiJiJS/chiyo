import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/protocol_json.dart';

/// JSON-lines commands never carry or print session/grant credentials.
Future<void> main(List<String> args) async {
  var port = 47125;
  if (args.isNotEmpty) {
    if (args.length != 2 ||
        args.first != '--port' ||
        int.tryParse(args.last) == null ||
        int.parse(args.last) < 1 ||
        int.parse(args.last) > 65535) {
      stdout.writeln(jsonEncode({'status': 'invalid_request'}));
      exitCode = 64;
      return;
    }
    port = int.parse(args.last);
  }
  final client = AgentClient(port);
  try {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      Map<String, dynamic> output;
      try {
        if (line.length > 262144) throw const FormatException();
        Map<String,dynamic> command;
        try {command = decodeProtocolObject(line);} on Object {
            stdout.writeln(jsonEncode({'protocolVersion': 1, 'status': 'invalid_request',
              'errorCode': 'invalid_json', 'retryable': false}));
            continue;
        }
        output = await client.execute(command);
      } on Object {
        output = {'status': 'invalid_request'};
      }
      stdout.writeln(jsonEncode(output));
    }
  } on Object {
    stdout.writeln(jsonEncode({'status': 'invalid_request'}));
  } finally {
    client.close();
  }
}
