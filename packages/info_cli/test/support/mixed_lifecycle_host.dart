// Test-only resident host for an encrypted-storage fixture in another process.
// Private session proofs arrive on stdin and are never echoed or put in argv.
import 'dart:convert';
import 'dart:io';
import 'package:info_cli/credential_execution_host.dart';

Future<void> main() async {
  void phase(String value) {
    final directory = Platform.environment['INFO_TEST_HOST_PHASE_DIRECTORY'];
    if (directory == null) return;
    File('$directory/host-$pid.jsonl').writeAsStringSync(
      '${jsonEncode({'pid': pid, 'phase': value})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  CredentialExecutionHost? host;
  phase('started');
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
        phase('close-drain-started');
        await host!.drain();
        phase('close-drain-complete');
        host.close();
        phase('host-close-complete');
        stdout.writeln('{"status":"closed"}');
        await stdout.flush();
        phase('close-reply-flushed');
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
    phase('stdin-eof');
  } on Object {
    stdout.writeln('{"status":"fixture_failed"}');
    exitCode = 70;
  } finally {
    phase('finally-entered');
    host?.close();
    phase('finally-complete');
  }
}
