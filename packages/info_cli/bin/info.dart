import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/desktop_control.dart';
import 'package:info_core/protocol_json.dart';
import 'package:info_remote/agent_connection.dart';

/// JSON-lines commands never carry or print session/grant credentials.
Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'app') {
    final result = await desktopControlCommand(args);
    stdout.writeln(jsonEncode(result.output));
    exitCode = result.exitCode;
    return;
  }
  var port = 47125;
  AgentConnectionProfile? connection;
  if (args.isNotEmpty) {
    if (args.length == 2 && args.first == '--connection') {
      try {
        connection = await AgentConnectionProfile.read(File(args.last));
      } on Object {
        stdout.writeln(jsonEncode({'status': 'connection_unavailable'}));
        exitCode = 64;
        return;
      }
    } else {
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
  }
  AgentClient client;
  try {
    client = connection == null
        ? AgentClient(port)
        : AgentClient.remote(connection);
  } on Object {
    stdout.writeln(jsonEncode({'status': 'connection_unavailable'}));
    exitCode = 64;
    return;
  }
  try {
    await for (final record in _boundedLines(stdin)) {
      if (record.error != null) {
        stdout.writeln(jsonEncode(_protocolError(record.error!)));
        continue;
      }
      Map<String, dynamic> output;
      try {
        Map<String, dynamic> command;
        try {
          command = decodeProtocolObject(record.line!);
        } on Object {
          stdout.writeln(
            jsonEncode({
              'protocolVersion': 1,
              'status': 'invalid_request',
              'errorCode': 'invalid_json',
              'retryable': false,
            }),
          );
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
    await client.drainCredentialExecutions();
    client.close();
  }
}

Map<String, Object?> _protocolError(String code) => {
  'protocolVersion': 1,
  'status': 'invalid_request',
  'errorCode': code,
  'retryable': false,
  'attemptConsumed': false,
};

// Bound storage before decoding, rather than letting LineSplitter accumulate an
// unlimited line. A rejected byte line cannot terminate the protocol stream.
Stream<({String? line, String? error})> _boundedLines(
  Stream<List<int>> input,
) async* {
  final bytes = <int>[];
  var overflow = false;
  ({String? line, String? error}) finish() {
    if (overflow) return (line: null, error: 'limit_exceeded');
    try {
      return (line: utf8.decode(bytes), error: null);
    } on FormatException {
      return (line: null, error: 'invalid_json');
    }
  }

  await for (final chunk in input) {
    for (final byte in chunk) {
      if (byte == 10) {
        yield finish();
        bytes.clear();
        overflow = false;
      } else if (!overflow) {
        if (bytes.length == 262143) {
          overflow = true;
          bytes.clear();
        } else {
          bytes.add(byte);
        }
      }
    }
  }
  if (overflow || bytes.isNotEmpty) yield finish();
}
