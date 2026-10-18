import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';

Future<void> main(List<String> args) async {
  final job = CredentialProcessJob.createForCurrentWorker(args.single);
  final identity = CredentialProcessIdentity.capture(pid)!;
  try {
    stdout.writeln(jsonEncode({'pid': pid, 'identity': identity.value}));
    await stdout.flush();
    await stdin.drain<void>().timeout(
      const Duration(seconds: 20),
      onTimeout: () {},
    );
    await job.waitForDescendants();
  } finally {
    identity.close();
    job.close();
  }
}
