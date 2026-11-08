import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'runtime_worker_macos.dart';
import 'device_information_files.dart';

Future<void> _forwardOutput(
  Stream<List<int>> source,
  IOSink destination,
) async {
  var connected = true;
  // The CLI may disappear while the approved process keeps running. Observe
  // the sink error and discard further bytes, but keep draining the OS pipe.
  unawaited(
    destination.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
  );
  await for (final chunk in source) {
    if (!connected) continue;
    try {
      destination.add(chunk);
      await destination.flush();
    } on Object {
      connected = false;
    }
  }
}

/// Internal process launcher, not a JSON-lines agent command. The parent sends
/// only the already approved executable/argv/cwd and a non-secret state path.
/// The worker's environment was built by the executor; it has no session proof.
Future<void> main([List<String> args = const []]) async {
  if (args.length == 1 && args.single == '--information-file-guardian') {
    return runInformationFileGuardian();
  }
  if (args.isNotEmpty) {
    exitCode = 64;
    return;
  }
  if (Platform.isMacOS) return runMacOsRuntimeWorker();
  final input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  File? state;
  Process? target;
  CredentialProcessIdentity? identity;
  CredentialProcessJob? job;
  Future<void>? outDone, errDone;
  Future<void> write(Map<String, Object?> facts) async {
    // Each phase is published once to its own path. A reader may retain an
    // earlier Windows handle indefinitely without blocking later receipts.
    final suffix = switch (facts['state']) {
      'ready' => '',
      'started' => '.started',
      _ => '.finished',
    };
    final file = File('${state!.path}$suffix');
    final temporary = File('${file.path}.next');
    await temporary.writeAsString(jsonEncode(facts), flush: true);
    await temporary.rename(file.path);
  }

  try {
    if (!await input.moveNext() || utf8.encode(input.current).length > 262144) {
      throw const FormatException();
    }
    final plan = jsonDecode(input.current) as Map<String, dynamic>;
    final path = plan['statePath'] as String;
    // Only the parent-created execution TEMP directory is writable here.
    final temp = Platform.environment['TEMP'];
    if (temp == null ||
        File(path).parent.path != Directory(temp).path ||
        File(path).uri.pathSegments.last != 'worker-state.json') {
      throw const FormatException();
    }
    state = File(path);
    final name = plan['jobName'] as String;
    if (!RegExp(
      r'^Local\\AgentInfoRuntime-[A-Za-z0-9_-]{32}$',
    ).hasMatch(name)) {
      throw const FormatException();
    }
    // Crucially, no target exists before this process has joined its job.
    job = CredentialProcessJob.createForCurrentWorker(name);
    await write({
      'state': 'ready',
      'receiptVersion': 2,
      'workerPid': pid,
      'jobName': name,
    });
    // The supervisor first persists this worker's verified job membership.
    // EOF or supervisor failure before that acknowledgement cannot launch.
    if (!await input.moveNext() || input.current != 'start') {
      throw const FormatException();
    }
    target = await Process.start(
      plan['executable'] as String,
      (plan['argv'] as List).cast<String>(),
      workingDirectory: plan['cwd'] as String,
      environment: Platform.environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    outDone = _forwardOutput(target.stdout, stdout);
    errDone = _forwardOutput(target.stderr, stderr);
    identity = CredentialProcessIdentity.capture(target.pid);
    await target.stdin.close();
    await write({
      'state': 'started',
      'workerPid': pid,
      'pid': target.pid,
      'jobName': name,
      'processCreatedAt': identity?.value,
    });
    // Keep the process handle until the parent has captured the identity, even
    // if a very short command already exited. EOF acknowledges that capture.
    final acknowledged = input.moveNext();
    final result = await target.exitCode;
    await Future.wait([outDone, errDone]);
    await acknowledged;
    await job.waitForDescendants();
    await write({
      'state': 'exited',
      'workerPid': pid,
      'pid': target.pid,
      'jobName': name,
      'processCreatedAt': identity?.value,
      'exitCode': result,
    });
    try {
      await stdout.flush();
    } on Object {
      /* The CLI may already be gone. */
    }
    try {
      await stderr.flush();
    } on Object {
      /* The CLI may already be gone. */
    }
  } on Object {
    if (target != null) {
      await target.exitCode;
      try {
        await Future.wait([?outDone, ?errDone]);
      } on Object {
        // Preserve unknown when output cannot be completely drained.
      }
      try {
        await job?.waitForDescendants();
      } on Object {
        // No trustworthy tree-end fact is inferred from a failed query.
      }
    }
    if (state != null) {
      try {
        await write({'state': target == null ? 'start_failed' : 'unknown'});
      } on Object {
        // The parent must treat an absent final state as unknown.
      }
    }
    exitCode = 70;
  } finally {
    identity?.close();
    job?.close();
    await input.cancel();
  }
}
