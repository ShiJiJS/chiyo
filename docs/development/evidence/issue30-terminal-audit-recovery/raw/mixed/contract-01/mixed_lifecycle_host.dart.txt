// Test-only resident host for an encrypted-storage fixture in another process.
// Private session proofs arrive on stdin and are never echoed or put in argv.
import 'dart:convert';
import 'dart:io';
import 'package:info_cli/credential_execution_host.dart';

Future<void> main() async {
  CredentialExecutionHost? host;
  try {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final message = jsonDecode(line) as Map<String, dynamic>;
      Map<String, dynamic> reply;
      if (message['action'] == 'initialize' && host == null) {
        host = CredentialExecutionHost(
          port: message['port'] as int,
          workerExecutable: message['worker'] as String,
        );
        reply = {'status': 'ready'};
      } else if (message['action'] == 'drain') {
        await host!.drain();
        reply = {'status': 'ok'};
      } else if (message['action'] == 'close') {
        await host!.drain();
        host.close();
        stdout.writeln('{"status":"closed"}');
        await stdout.flush();
        return;
      } else {
        reply = await host!.execute(
          message['session'] as String,
          Map<String, dynamic>.from(message['input'] as Map),
        );
      }
      stdout.writeln(jsonEncode(reply));
      await stdout.flush();
    }
  } on Object {
    stdout.writeln('{"status":"fixture_failed"}');
    exitCode = 70;
  } finally {
    host?.close();
  }
}
