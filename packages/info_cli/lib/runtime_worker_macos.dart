import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/macos_runtime_target.dart';

/// Darwin implementation of the same private, two-gate worker protocol.
/// Control is stdin + private receipts; the target inherits only output pipes.
Future<void> runMacOsRuntimeWorker() async {
  final input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  File? state;
  MacOsRuntimeTarget? target;
  CredentialProcessJob? group;
  CredentialProcessIdentity? identity;
  String? name;
  Future<void> write(Map<String, Object?> facts) async {
    final suffix = facts['state'] == 'ready'
        ? ''
        : facts['state'] == 'started'
        ? '.started'
        : '.finished';
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
    final temporary = Platform.environment['TMPDIR'];
    if (temporary == null ||
        File(path).parent.path != Directory(temporary).path ||
        File(path).uri.pathSegments.last != 'worker-state.json') {
      throw const FormatException();
    }
    state = File(path);
    name = plan['jobName'] as String;
    group = CredentialProcessJob.createForCurrentWorker(name);
    await write({
      'state': 'ready',
      'receiptVersion': 2,
      'workerPid': pid,
      'jobName': name,
    });
    // EOF before registration never creates a target.
    if (!await input.moveNext() || input.current != 'start') {
      throw const FormatException();
    }
    target = MacOsRuntimeTarget.spawn(
      plan['executable'] as String,
      (plan['argv'] as List).cast<String>(),
      Platform.environment,
    );
    identity = CredentialProcessIdentity.capture(target.pid);
    if (identity == null) throw StateError('process_identity_unavailable');
    await write({
      'state': 'started',
      'workerPid': pid,
      'pid': target.pid,
      'jobName': name,
      'processCreatedAt': identity.value,
    });
    // The supervisor captures the still-suspended target before closing stdin.
    await input.moveNext();
    target.resume();
    final result = await target.exitCode;
    await group.waitForDescendants();
    await write({
      'state': 'exited',
      'workerPid': pid,
      'pid': target.pid,
      'jobName': name,
      'processCreatedAt': identity.value,
      'exitCode': result,
    });
  } on Object {
    if (target != null) {
      // Once the launch gate was released, a supervisor loss does not cancel
      // an admitted command. Keep draining via inherited native descriptors.
      try {
        target.resume();
        await target.exitCode;
        await group?.waitForDescendants();
      } on Object {
        /* Preserve unknown. */
      }
    }
    if (state != null) {
      try {
        await write({'state': target == null ? 'start_failed' : 'unknown'});
      } on Object {
        /* Missing receipt stays unknown. */
      }
    }
    exitCode = 70;
  } finally {
    identity?.close();
    group?.close();
    await input.cancel();
  }
}
