// Explicit native AOT receiver for private-key/Job/output-filter validation.
// Never connects to a service or reads the invoking user's configuration.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length == 2 && args.first == '--descendant') {
    final gate = File(args.last);
    final end = DateTime.now().add(const Duration(minutes: 3));
    while (!await gate.exists() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    exit(0);
  }
  final name = File(
    Platform.resolvedExecutable,
  ).uri.pathSegments.last.toLowerCase();
  if (args.length == 1 && {'--version', '-V'}.contains(args.single)) {
    if (name == 'ssh.exe') {
      stderr.writeln(
        'OpenSSH_for_Windows_9.5p2, synthetic validation receiver',
      );
    } else {
      stdout.writeln(
        name == 'gh.exe' ? 'gh version 2.102.0' : 'aws-cli/2.38.1',
      );
    }
    return;
  }
  final kind = name.split('.').first;
  final work = Directory.current;
  final counter = File('${work.path}/$kind-counter');
  await counter.writeAsString('started\n', mode: FileMode.append, flush: true);
  if (Platform.environment.containsKey('CHIYO_POISON_AUTH')) exit(39);
  List<int> secret;
  if (kind == 'ssh') {
    final i = args.indexOf('-i');
    if (i < 0 ||
        !args.contains('PasswordAuthentication=no') ||
        !args.contains('StrictHostKeyChecking=yes')) {
      exit(40);
    }
    final material = File(args[i + 1]);
    secret = await material.readAsBytes();
    if (!utf8
        .decode(secret)
        .startsWith('-----BEGIN OPENSSH PRIVATE KEY-----')) {
      exit(41);
    }
    final config = args.indexOf('-F');
    if (config < 0 || await File(args[config + 1]).length() != 0) exit(42);
    final hosts = args.singleWhere((v) => v.startsWith('UserKnownHostsFile='));
    if (await File(
          hosts.substring('UserKnownHostsFile='.length).replaceAll('"', ''),
        ).length() ==
        0) {
      exit(43);
    }
  } else if (kind == 'aws') {
    secret = await File(
      Platform.environment['AWS_SHARED_CREDENTIALS_FILE']!,
    ).readAsBytes();
  } else {
    secret = utf8.encode(Platform.environment['GH_TOKEN']!);
  }
  stdout.writeln('WINDOWS_RECEIVER_STARTED');
  // Deliberately split a secret across writes. Only filtered output may escape.
  final middle = secret.length ~/ 2;
  stdout.add(secret.sublist(0, middle));
  await stdout.flush();
  await Future<void>.delayed(const Duration(milliseconds: 20));
  stderr.add(secret.sublist(0, middle));
  // Each stream also gets the whole secret, exercising both independent masks.
  stdout.add(secret.sublist(middle));
  stderr.add(secret.sublist(middle));
  await stdout.flush();
  await stderr.flush();
  final gate = File('${work.path}/$kind-release');
  if (File('${work.path}/tree-mode').existsSync()) {
    final child = await Process.start(
      Platform.resolvedExecutable,
      ['--descendant', gate.path],
      environment: {'SystemRoot': Platform.environment['SystemRoot']!},
      includeParentEnvironment: false,
    );
    await File(
      '${work.path}/descendant-pid',
    ).writeAsString('${child.pid}', flush: true);
    child.stdout.listen((_) {});
    child.stderr.listen((_) {});
    stdout.writeln('PARENT_EXITED_WITH_LIVE_DESCENDANT');
    await stdout.flush();
    exit(0);
  }
  final end = DateTime.now().add(const Duration(minutes: 3));
  while (!await gate.exists() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  stdout.writeln('WINDOWS_RECEIVER_COMPLETED');
}
