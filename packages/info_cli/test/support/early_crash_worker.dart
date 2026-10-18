import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';

// A synthetic worker that dies after starting a child but before publishing its
// target identity. It uses the real Windows job and the same two-phase protocol.
Future<void> main() async {
  final input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  if (!await input.moveNext()) exit(70);
  final plan = jsonDecode(input.current) as Map<String, dynamic>;
  final job = CredentialProcessJob.createForCurrentWorker(
    plan['jobName'] as String,
  );
  await File(plan['statePath'] as String).writeAsString(
    jsonEncode({
      'state': 'ready',
      'receiptVersion': 2,
      'workerPid': pid,
      'jobName': job.name,
    }),
    flush: true,
  );
  if (!await input.moveNext() || input.current != 'start') exit(70);
  await Process.start(
    plan['executable'] as String,
    (plan['argv'] as List).cast<String>(),
    workingDirectory: plan['cwd'] as String,
    environment: Platform.environment,
    includeParentEnvironment: false,
    runInShell: false,
    mode: ProcessStartMode.detachedWithStdio,
  );
  final ready = File('${plan['cwd']}/target-ready');
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await ready.exists() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  exit(71);
}
