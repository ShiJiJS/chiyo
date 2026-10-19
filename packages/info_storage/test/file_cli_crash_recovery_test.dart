import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  final compiled = Platform.environment['D6_COMPILED_CLI'];
  test(
    'compiled CLI death preserves an active file task, and encrypted reopen cleans only after its registered process group ends',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'file-cli-crash-recovery-',
      );
      final release = File('${root.path}/release'),
          ready = File('${root.path}/ready'),
          finished = File('${root.path}/finished'),
          heartbeat = File('${root.path}/heartbeat');
      await File('${root.path}/ssm').writeAsString(r'''
import 'dart:io';
Future<void> main(List<String> args) async {
  final material=File(Platform.environment['AWS_SHARED_CREDENTIALS_FILE']!);
  final exact=(await material.readAsString()).contains('SYNTHETIC_CRASH_ONLY') && await File(Platform.environment['AWS_CONFIG_FILE']!).length()==0;
  await File('ready').writeAsString(exact?'yes':'no',flush:true);
  final deadline=DateTime.now().add(const Duration(seconds:15));var count=0;
  while(!await File('release').exists()){
    if(DateTime.now().isAfter(deadline))exit(70);
    stdout.add(List<int>.filled(8192,120));await stdout.flush();
    await File('heartbeat').writeAsString('${++count}',flush:true);
    await Future<void>.delayed(const Duration(milliseconds:10));
  }
  await File('finished').writeAsString('done',flush:true);
}
''');
      final keys = TestKeyStore();
      var repository = await EncryptedInformationRepository.open(
        root.path,
        keys,
      );
      final exe = File(Platform.resolvedExecutable),
          stat = await File(Platform.resolvedExecutable).stat();
      final digest = 'sha256:${sha256.convert(await exe.readAsBytes())}';
      InformationService createService() => InformationService(
        repository: repository,
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(
              exe.path,
              stat.size,
              stat.modified.microsecondsSinceEpoch,
              digest,
            ),
      );
      var service = createService();
      final server = await AgentServer.start(service.agent, port: 0);
      final cli = await Process.start(compiled!, ['--port', '${server.port}']);
      final lines = StreamIterator(
        cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = cli.stderr.drain<void>();
      String? materialPath, executionId;
      addTearDown(() async {
        await release.writeAsString('release');
        cli.kill();
        await cli.exitCode;
        await lines.cancel();
        await errors;
        await server.close();
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        if (executionId != null) {
          while (!await finished.exists() &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
        await service.close();
        await repository.close();
        repository = await EncryptedInformationRepository.open(root.path, keys);
        service = createService();
        try {
          final end = DateTime.now().add(const Duration(seconds: 5));
          while (service.owner.credentialMaterialChecks.isNotEmpty &&
              DateTime.now().isBefore(end)) {
            await service.owner.reconcileCredentialMaterialCleanup();
            if (service.owner.credentialMaterialChecks.isNotEmpty) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          }
          if (service.owner.credentialExecutions.every(
            (e) => e.cleanupState == 'complete',
          )) {
            await service.close();
            await repository.close();
            final resolved = await root.resolveSymbolicLinks(),
                parent = await Directory.systemTemp.resolveSymbolicLinks();
            if (resolved.toLowerCase() == root.absolute.path.toLowerCase() &&
                resolved.toLowerCase().startsWith(
                  '${parent.toLowerCase()}${Platform.pathSeparator}',
                ) &&
                root.path
                    .split(Platform.pathSeparator)
                    .last
                    .startsWith('file-cli-crash-recovery-')) {
              await root.delete(recursive: true);
            }
          }
        } finally {
          await service.close();
          await repository.close();
        }
      });
      Future<Map<String, dynamic>> command(Map<String, Object?> input) async {
        cli.stdin.writeln(jsonEncode(input));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      var credential = await service.owner.createFileCredential(
        name: 'Synthetic crash file',
        publicPurpose: '',
        fileName: 'credentials',
        bytes: utf8.encode(
          '[default]\naws_access_key_id=TEST_ONLY\naws_secret_access_key=SYNTHETIC_CRASH_ONLY\n',
        ),
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'AWS_SHARED_CREDENTIALS_FILE',
        discoverable: true,
      );
      await command({
        'command': 'session',
        'chatLabel': 'Synthetic file crash',
      });
      final request = await command({
        'protocolVersion': 1,
        'command': 'request-use',
        'purpose': 'Verify durable file recovery',
        'credentials': [
          {'alias': 'file', 'credentialId': credential.id, 'version': 1},
        ],
        'launch': {
          'receiver': 'aws_shared_credentials',
          'executable': exe.path,
          'argv': ['ssm', 'get-parameter', '--region', 'us-east-1'],
          'cwd': root.path,
          'env': {
            'AWS_SHARED_CREDENTIALS_FILE': {'file': 'file'},
          },
        },
      });
      expect(request['status'], 'pending');
      await service.owner.decideCredentialUse(
        request['requestId'] as String,
        approveCredential: true,
      );
      final started = await command({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': request['requestId'],
      });
      expect(started['status'], 'accepted');
      executionId = started['executionId'] as String;
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await ready.exists() ||
          !await heartbeat.exists() ||
          service.owner.credentialExecutions.single.state != 'running') {
        expect(
          DateTime.now().isBefore(deadline),
          isTrue,
          reason: 'Controlled file task did not start',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await ready.readAsString(), 'yes');
      final record = service.owner.credentialExecutions.single;
      expect(record.jobName, isNotNull);
      materialPath = record.materialLease!.path;
      // The independent receiver truncates before publishing each heartbeat.
      // An empty in-progress write is not a stopped process or valid baseline.
      Future<int> committedHeartbeat() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (DateTime.now().isBefore(deadline)) {
          final value = int.tryParse(await heartbeat.readAsString());
          if (value != null) return value;
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        fail('Synthetic heartbeat never published a complete counter');
      }

      final before = await committedHeartbeat();
      expect(cli.kill(), isTrue);
      await cli.exitCode;
      await service.close();
      await server.close();
      await repository.close();
      repository = await EncryptedInformationRepository.open(root.path, keys);
      service = createService();
      expect(service.owner.credentialExecutions.single.state, 'unknown');
      expect(
        service.owner.credentialExecutions.single.cleanupState,
        'needs_check',
      );
      expect(await service.owner.reconcileCredentialMaterialCleanup(), 1);
      expect(await Directory(materialPath).exists(), isTrue);
      final progressDeadline = DateTime.now().add(const Duration(seconds: 2));
      var progressed = false;
      while (DateTime.now().isBefore(progressDeadline)) {
        try {
          progressed = int.parse(await heartbeat.readAsString()) > before + 3;
        } on FormatException {
          /* Concurrent synthetic heartbeat write. */
        }
        if (progressed) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        progressed,
        isTrue,
        reason:
            'The approved child must survive CLI death and continue while its material is retained',
      );
      await release.writeAsString('release');
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (service.owner.credentialMaterialChecks.isNotEmpty) {
        await service.owner.reconcileCredentialMaterialCleanup();
        if (service.owner.credentialMaterialChecks.isEmpty) break;
        expect(DateTime.now().isBefore(end), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await finished.exists(), isTrue);
      expect(await Directory(materialPath).exists(), isFalse);
      final recovered = service.owner.credentialExecutions.single;
      expect(recovered.state, 'unknown');
      expect(recovered.exitCode, isNull);
      expect(recovered.cleanupState, 'complete');
      expect(
        service.owner.credentialUseRequests.single.attemptConsumed,
        isTrue,
      );
    },
    skip: !Platform.isWindows || compiled == null,
    timeout: const Timeout(Duration(seconds: 35)),
  );
}
