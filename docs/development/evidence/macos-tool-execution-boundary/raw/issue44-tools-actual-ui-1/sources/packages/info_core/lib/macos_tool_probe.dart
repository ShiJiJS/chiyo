import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Version-only child uses the isolated probe environment, before runtime
/// material is prepared or injected. A newly
/// extracted notarized macOS tool can take longer than the Windows 5s probe on
/// first launch. Bound both its lifetime and output, and reap it on timeout.
Future<ProcessResult> probeMacOsToolVersion(
  String executable,
  String argument,
  String directory,
  Map<String, String> environment,
) async {
  final process = await Process.start(
    executable,
    [argument],
    workingDirectory: directory,
    environment: environment,
    includeParentEnvironment: false,
    runInShell: false,
  );
  final output = <int>[], errors = <int>[];
  var total = 0, overflow = false, ended = false;
  final stdoutDone = Completer<void>(), stderrDone = Completer<void>();
  void collect(List<int> bytes, List<int> destination) {
    total += bytes.length;
    if (total > 65536) {
      overflow = true;
      if (!ended) process.kill(ProcessSignal.sigkill);
    } else {
      destination.addAll(bytes);
    }
  }

  final stdout = process.stdout.listen(
    (b) => collect(b, output),
    onDone: () {
      if (!stdoutDone.isCompleted) stdoutDone.complete();
    },
    onError: (Object e, StackTrace s) {
      if (!stdoutDone.isCompleted) stdoutDone.completeError(e, s);
    },
  );
  final stderr = process.stderr.listen(
    (b) => collect(b, errors),
    onDone: () {
      if (!stderrDone.isCompleted) stderrDone.complete();
    },
    onError: (Object e, StackTrace s) {
      if (!stderrDone.isCompleted) stderrDone.completeError(e, s);
    },
  );
  try {
    final result = await Future.wait<Object?>([
      process.exitCode.then((code) {
        ended = true;
        return code;
      }),
      stdoutDone.future,
      stderrDone.future,
    ]).timeout(const Duration(seconds: 30));
    if (overflow) {
      throw const FormatException('Tool version output exceeded limit');
    }
    return ProcessResult(
      process.pid,
      result.first as int,
      utf8.decode(output, allowMalformed: true),
      utf8.decode(errors, allowMalformed: true),
    );
  } finally {
    if (!ended) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
    }
    await stdout.cancel();
    await stderr.cancel();
  }
}
