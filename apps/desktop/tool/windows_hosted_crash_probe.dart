// Explicit QA entry point; never imported by the production application.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart' show InformationApp;
import 'package:info_storage/info_storage.dart';
import '../integration_test/support/isolated_desktop.dart';

void require(bool condition, String fact) {
  if (!condition) throw StateError(fact);
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('WINDOWS_HOSTED_CRASH_QA') ||
      !Platform.isWindows ||
      args.length != 2 ||
      !{'run', 'verify'}.contains(args[1])) {
    exit(64);
  }
  final configFile = File(args[0]);
  final root = configFile.parent;
  require(
    root.parent.uri.pathSegments.contains('native-hosted-crash'),
    'probe boundary',
  );
  require(
    RegExp(
      r'^synthetic-[a-f0-9]{32}$',
    ).hasMatch(root.uri.pathSegments.where((s) => s.isNotEmpty).last),
    'probe name',
  );
  require(
    (await root.resolveSymbolicLinks()).toLowerCase() ==
        root.absolute.path.toLowerCase(),
    'probe link',
  );
  final config =
      jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
  try {
    if (args[1] == 'run') {
      final fixture = await IsolatedDesktopFixture.start(
        credentialWorkerExecutable: config['worker'] as String,
      );
      final service = fixture.service;
      runApp(
        InformationApp(
          service: service,
          port: fixture.port,
          runtime: fixture.bootstrap.runtime,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      final keys = config['keys'] as String;
      final host = (await File(
        '$keys/host.pub',
      ).readAsString()).split(' ').take(2).join(' ');
      await service.owner.configureSshKnownHosts(
        'Synthetic crash host',
        utf8.encode('[127.0.0.1]:${config['port']} $host\n'),
      );
      var credential = await service.owner.createFileCredential(
        name: 'Synthetic crash key',
        publicPurpose: 'Isolated GUI process death',
        fileName: 'synthetic_ed25519',
        bytes: await File('$keys/client').readAsBytes(),
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: credential.publicPurpose,
        privateNote: '',
        suggestedBinding: 'ssh_key',
        discoverable: true,
      );
      final client = AgentClient(
        fixture.port,
        hostedCredentialExecutions: true,
      );
      await client.execute({
        'command': 'session',
        'chatLabel': 'Synthetic GUI crash',
      });
      final request = await client.execute({
        'command': 'request-use',
        'purpose': 'Synthetic GUI crash recovery',
        'credentials': [
          {'alias': 'ssh_key', 'credentialId': credential.id, 'version': 1},
        ],
        'launch': {
          'receiver': 'ssh_identity',
          'executable': config['ssh'],
          'argv': [
            '-T',
            '-o',
            'BatchMode=yes',
            '-i',
            {'file': 'ssh_key'},
            '-p',
            config['port'],
            'fixture@127.0.0.1',
            '/bin/sleep',
            '15',
          ],
          'cwd': fixture.root.path,
          'env': <String, Object?>{},
        },
      });
      require(request['status'] == 'pending', 'request pending');
      await service.owner.decideCredentialUse(
        request['requestId'] as String,
        approveCredential: true,
      );
      final run = await client.execute({
        'command': 'run-use',
        'requestId': request['requestId'],
      });
      require(run['status'] == 'accepted', 'accepted');
      final id = run['executionId'] as String;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (true) {
        final record = service.owner.credentialExecutions.singleWhere(
          (e) => e.id == id,
        );
        if (record.state == 'running') {
          require(
            CredentialProcessJob.isActive(record.jobName!) == true,
            'live job',
          );
          break;
        }
        require(DateTime.now().isBefore(deadline), 'running deadline');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // Synthetic session proof stays only in this ignored, private QA directory.
      await File('${root.path}/ready.json').writeAsString(
        jsonEncode({
          'profile': fixture.root.path,
          'executionId': id,
          'oldSession': client.sessionSecret,
        }),
        flush: true,
      );
      final crash = File('${root.path}/crash-now');
      while (!await crash.exists()) {
        require(DateTime.now().isBefore(deadline), 'crash control deadline');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // Deliberately bypass Dart finally/runtime.stop/repository.close. Only
      // this explicitly isolated GUI process is terminated.
      require(Process.killPid(pid), 'terminate own GUI');
      await Future<void>.delayed(const Duration(seconds: 2));
      throw StateError('GUI unexpectedly survived termination');
    }
    final ready =
        jsonDecode(await File('${root.path}/ready.json').readAsString()) as Map;
    final profile = Directory(ready['profile'] as String);
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    require(
      (await profile.resolveSymbolicLinks()).toLowerCase() ==
              profile.absolute.path.toLowerCase() &&
          profile.parent.path.toLowerCase() == temp.toLowerCase() &&
          profile.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .last
              .startsWith('aim-native-approval-'),
      'profile boundary',
    );
    final repository = await EncryptedInformationRepository.open(
      profile.path,
      WindowsDatabaseKeyStore('${profile.path}/database-key.dpapi'),
    );
    final service = InformationService(repository: repository);
    try {
      // Production DesktopRuntime.start performs this maintenance on reopen.
      await service.owner.reconcileCredentialMaterialCleanup();
      var record = service.owner.credentialExecutions.singleWhere(
        (e) => e.id == ready['executionId'],
      );
      require(
        record.state == 'unknown' &&
            record.exitCode == null &&
            record.finishedAt == null,
        'unknown after GUI death',
      );
      require(
        record.supervisorPid != null && record.workerPid != null,
        'private registration retained',
      );
      require(
        CredentialProcessJob.isActive(record.jobName!) == true,
        'SSH survives GUI death',
      );
      await service.owner.reconcileCredentialMaterialCleanup();
      require(
        await Directory(record.materialLease!.path).exists(),
        'live material retained',
      );
      var oldProofRejected = false;
      try {
        service.agent.credentialExecutionStatus(
          ready['oldSession'] as String,
          record.id,
        );
      } on CredentialUseFailure catch (e) {
        oldProofRejected = e.code == 'session_required';
      }
      require(oldProofRejected, 'old session rejected');
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (CredentialProcessJob.isActive(record.jobName!) != false) {
        require(DateTime.now().isBefore(deadline), 'job end deadline');
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      await service.owner.reconcileCredentialMaterialCleanup();
      record = service.owner.credentialExecutions.singleWhere(
        (e) => e.id == record.id,
      );
      require(
        record.state == 'unknown' &&
            record.exitCode == null &&
            record.cleanupState == 'complete',
        'unknown cleaned',
      );
      require(
        !await Directory(record.materialLease!.path).exists(),
        'material removed after job end',
      );
      require(
        service.owner.credentialUseRequests.every((r) => r.attemptConsumed),
        'no replay',
      );
      await File('${root.path}/result.json').writeAsString(
        jsonEncode({
          'guiProcessDied': true,
          'sshSurvived': true,
          'unknownWithoutExitCode': true,
          'activeMaterialRetained': true,
          'oldProofRejected': true,
          'endedMaterialRemoved': true,
          'attemptRemainsConsumed': true,
        }),
        flush: true,
      );
    } finally {
      await service.close();
      await repository.close();
    }
    exit(0);
  } on Object catch (e) {
    // Do not serialize exception contents, plans, keys or private session data.
    await File('${root.path}/failure.json').writeAsString(
      jsonEncode({
        'type': e.runtimeType.toString(),
        if (e is StateError) 'fact': e.message.toString(),
      }),
      flush: true,
    );
    exit(70);
  }
}
