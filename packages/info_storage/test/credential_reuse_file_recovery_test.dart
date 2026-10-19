import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

Future<void> _until(
  FutureOr<bool> Function() condition,
  String reason, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  final compiled = Platform.environment['D6_COMPILED_CLI'];
  test(
    'v2 file operations retain independent leases through revoke, CLI death and encrypted reopen',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'reuse-file-recovery-',
      );
      final work = await Directory('${root.path}/work').create();
      await File('${work.path}/ssm').writeAsString(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  final name=args[args.indexOf('--name')+1];
  final material=File(Platform.environment['AWS_SHARED_CREDENTIALS_FILE']!);
  final exact=await material.readAsString()=='[default]\naws_access_key_id=TEST_ACCESS_ONLY\naws_secret_access_key=SYNTHETIC_MULTIOP_ONLY\n';
  final ready=File('ready-$name.tmp');
  await ready.writeAsString(jsonEncode({'matches':exact,
    'configEmpty':await File(Platform.environment['AWS_CONFIG_FILE']!).length()==0,
    'sessionAbsent':!Platform.environment.containsKey('INFO_SESSION_SECRET'),
    'materialPath':material.path}),flush:true);
  await ready.rename('ready-$name.json');
  final deadline=DateTime.now().add(const Duration(seconds:40));var count=0;
  while(!await File('release-$name').exists()){
    if(DateTime.now().isAfter(deadline))exit(70);
    stdout.add(List<int>.filled(8192,120));await stdout.flush();
    // Immutable heartbeat files avoid reader/writer sharing races on Windows.
    await File('beat-$name-${++count}').writeAsString('alive',flush:true);
    await Future<void>.delayed(const Duration(milliseconds:20));
  }
  await File('finished-$name').writeAsString('done',flush:true);
}
''');
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(
        '${root.path}/library',
        keys,
      );
      final executable = File(Platform.resolvedExecutable),
          stat = await File(Platform.resolvedExecutable).stat();
      final digest = 'sha256:${sha256.convert(await executable.readAsBytes())}';
      InformationService createService() => InformationService(
        repository: repo,
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(
              executable.path,
              stat.size,
              stat.modified.microsecondsSinceEpoch,
              digest,
            ),
      );
      var service = createService();
      final server = await AgentServer.start(
        service.agent,
        port: 0,
        enableReusableCredentialUse: true,
      );
      final cli = await Process.start(compiled!, ['--port', '${server.port}']);
      final lines = StreamIterator(
        cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = cli.stderr.drain<void>();
      addTearDown(() async {
        for (final name in ['one', 'two']) {
          await File('${work.path}/release-$name').writeAsString('release');
        }
        cli.kill();
        await cli.exitCode.timeout(const Duration(seconds: 5));
        await lines.cancel();
        await errors;
        await server.close();
        await service.close();
        await repo.close();
        repo = await EncryptedInformationRepository.open(
          '${root.path}/library',
          keys,
        );
        service = createService();
        bool settled() => service.owner.credentialExecutions.every(
          (e) =>
              (e.materialLease == null || e.cleanupState == 'complete') &&
              (e.jobName == null ||
                  CredentialProcessJob.isActive(e.jobName!) == false),
        );
        var safe = false;
        try {
          await _until(
            () async {
              await service.owner.reconcileCredentialMaterialCleanup();
              return settled();
            },
            'Registered fixture processes or material did not finish',
            timeout: const Duration(seconds: 8),
          );
          safe = true;
        } finally {
          await service.close();
          await repo.close();
        }
        if (safe) {
          final actual = await root.resolveSymbolicLinks(),
              temp = await Directory.systemTemp.resolveSymbolicLinks();
          if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
              !actual.toLowerCase().startsWith(
                '${temp.toLowerCase()}${Platform.pathSeparator}',
              )) {
            throw StateError('Unexpected fixture root');
          }
          await root.delete(recursive: true);
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

      int beats(String name) {
        var maximum = 0;
        for (final file in work.listSync().whereType<File>()) {
          final match = RegExp(
            '^beat-$name-([0-9]+)\$',
          ).firstMatch(file.uri.pathSegments.last);
          if (match != null) {
            final n = int.parse(match[1]!);
            if (n > maximum) maximum = n;
          }
        }
        return maximum;
      }

      var credential = await service.owner.createFileCredential(
        name: 'Synthetic reusable file',
        publicPurpose: '',
        fileName: 'credentials.ini',
        bytes: utf8.encode(
          '[default]\naws_access_key_id=TEST_ACCESS_ONLY\naws_secret_access_key=SYNTHETIC_MULTIOP_ONLY\n',
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
        'chatLabel': 'Reusable file operations',
      });
      Map<String, dynamic> launch(String name) => {
        'receiver': 'aws_shared_credentials',
        'executable': executable.path,
        'argv': [
          'ssm',
          'get-parameter',
          '--name',
          name,
          '--region',
          'us-east-1',
        ],
        'cwd': work.path,
        'env': {
          'AWS_SHARED_CREDENTIALS_FILE': {'file': 'file'},
        },
      };
      final requested = await command({
        'protocolVersion': 2,
        'command': 'request-use',
        'purpose': 'Two independent file operations',
        'credentials': [
          {'alias': 'file', 'credentialId': credential.id, 'version': 1},
        ],
        'launch': launch('one'),
      });
      expect(requested['status'], 'pending');
      final requestId = requested['requestId'] as String;
      await service.owner.decideCredentialUse(
        requestId,
        approveCredential: true,
      );
      final expires =
          service.owner.credentialUseRequests.single.credentialExpiresAt;
      Map<String, dynamic> operation(String name) => {
        'protocolVersion': 2,
        'command': 'run-use',
        'requestId': requestId,
        'operationId': 'operation-$name',
        'launch': launch(name),
      };
      final first = await command(operation('one')),
          second = await command(operation('two'));
      expect(first['status'], 'accepted');
      expect(second['status'], 'accepted');
      final ids = [
        first['executionId'] as String,
        second['executionId'] as String,
      ];
      await _until(
        () =>
            File('${work.path}/ready-one.json').existsSync() &&
            File('${work.path}/ready-two.json').existsSync() &&
            service.owner.credentialExecutions.every(
              (e) => e.state == 'running',
            ) &&
            beats('two') > 0,
        'Both file operations must be running',
      );
      final before = {
        for (final e in service.owner.credentialExecutions) e.id: e,
      };
      final paths = ids.map((id) => before[id]!.materialLease!.path).toList();
      expect(paths.toSet(), hasLength(2));
      expect(before.values.map((e) => e.jobName).toSet(), hasLength(2));
      for (var i = 0; i < 2; i++) {
        final name = ['one', 'two'][i],
            ready =
                jsonDecode(
                      await File(
                        '${work.path}/ready-$name.json',
                      ).readAsString(),
                    )
                    as Map;
        expect(
          ready['matches'] && ready['configEmpty'] && ready['sessionAbsent'],
          isTrue,
        );
        expect(
          ready['materialPath'],
          '${paths[i]}${Platform.pathSeparator}credential.bin',
        );
        expect(before[ids[i]]!.workerPid, isNotNull);
        expect(before[ids[i]]!.createdAt, isNotNull);
      }
      await service.owner.revokeCredentialUse(requestId);
      final denied = await command(operation('three'));
      expect(denied['errorCode'], 'grant_revoked');
      expect(denied['operationClaimed'], isFalse);
      expect(service.owner.credentialExecutions, hasLength(2));
      expect(
        service.owner.credentialUseRequests.single.credentialExpiresAt,
        expires,
      );
      expect(paths.every((p) => Directory(p).existsSync()), isTrue);
      final duplicate = await command(operation('two'));
      expect(duplicate['duplicate'], isTrue);
      expect(duplicate['executionId'], ids[1]);
      await File('${work.path}/release-one').writeAsString('release');
      await _until(
        () => service.owner.credentialExecutions.any(
          (e) =>
              e.id == ids[0] &&
              e.state == 'exited' &&
              e.cleanupState == 'complete',
        ),
        'First operation must finish and clean only its own files',
      );
      expect(await Directory(paths[0]).exists(), isFalse);
      expect(await Directory(paths[1]).exists(), isTrue);
      final heartbeat = beats('two');
      expect(cli.kill(), isTrue);
      await cli.exitCode;
      await server.close();
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(
        '${root.path}/library',
        keys,
      );
      service = createService();
      final reopened = {
        for (final e in service.owner.credentialExecutions) e.id: e,
      };
      expect(reopened[ids[0]]!.state, 'exited');
      expect(reopened[ids[0]]!.exitCode, 0);
      expect(reopened[ids[1]]!.state, 'unknown');
      expect(reopened[ids[1]]!.exitCode, isNull);
      expect(reopened[ids[1]]!.cleanupState, 'needs_check');
      for (final id in ids) {
        expect(reopened[id]!.createdAt, before[id]!.createdAt);
        expect(
          reopened[id]!.operationPlan!.planHash,
          before[id]!.operationPlan!.planHash,
        );
        expect(
          reopened[id]!.operationFingerprint,
          before[id]!.operationFingerprint,
        );
      }
      await expectLater(
        service.owner.cleanupCredentialExecution(ids[1]),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'cleanup_busy',
          ),
        ),
      );
      expect(await Directory(paths[1]).exists(), isTrue);
      await _until(
        () => beats('two') > heartbeat + 20,
        'Second approved child must continue draining after CLI death',
      );
      final other = service.agent.openSession('After reopen');
      await expectLater(
        service.agent.beginCredentialUseOperation(
          other,
          CredentialOperationInput.fromJson(operation('two')),
        ),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'session_mismatch',
          ),
        ),
      );
      await File('${work.path}/release-two').writeAsString('release');
      await _until(() async {
        await service.owner.reconcileCredentialMaterialCleanup();
        return service.owner.credentialExecutions.every(
          (e) => e.cleanupState == 'complete',
        );
      }, 'Second registered material must clean after its Job ends');
      expect(await File('${work.path}/finished-two').exists(), isTrue);
      expect(paths.any((p) => Directory(p).existsSync()), isFalse);
      final recovered = service.owner.credentialExecutions.singleWhere(
        (e) => e.id == ids[1],
      );
      expect(recovered.state, 'unknown');
      expect(recovered.exitCode, isNull);
      expect(
        service.owner.credentialUseRequests.single.attemptConsumed,
        isFalse,
      );
      expect(
        service.owner.credentialGrantState(
          service.owner.credentialUseRequests.single,
        ),
        'revoked',
      );
      final key = await enableTestBackups(repo.backups),
          backup = '${root.path}/recovery.aimbackup';
      await service.owner.exportLibrary(() => repo.backups.exportTo(backup));
      final target = await EncryptedInformationRepository.open(
        '${root.path}/restored',
        TestKeyStore(),
      );
      addTearDown(target.close);
      final preview = await target.backups.restoreFrom(backup, key);
      expect(preview.formatVersion, 6);
      expect(preview.credentialExecutionCount, 2);
      for (final e in target.credentialExecutions) {
        expect(e.createdAt, before[e.id]!.createdAt);
      }
      expect(
        target.credentialExecutions.every(
          (e) =>
              e.materialLease == null &&
              e.jobName == null &&
              e.operationPlan != null &&
              e.cleanupState == 'not_needed',
        ),
        isTrue,
      );
    },
    skip: !Platform.isWindows || compiled == null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
