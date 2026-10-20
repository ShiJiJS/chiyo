import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Compiled against the pinned schema16/backup5 source, never the current
/// package. The fixed key and all content are synthetic compatibility fixtures.
class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List<int>.filled(32, 61);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Fixed fixture key');
}

Future<void> main(List<String> args) async {
  if (args.length < 2 ||
      !{'create', 'inspect', 'inspect-backup'}.contains(args.first)) {
    stdout.writeln('{"status":"invalid_request"}');
    exitCode = 64;
    return;
  }
  EncryptedInformationRepository? repo;
  InformationService? service;
  try {
    final now = DateTime.utc(2026, 10, 19);
    repo = await EncryptedInformationRepository.open(
      args[1],
      _Keys(),
      clock: () => now,
    );
    if (args.first == 'create') {
      service = InformationService(
        repository: repo,
        clock: () => now,
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(path, 10, 100, 'sha256:${'a' * 64}'),
      );
      await service.owner.createInformation('Legacy fixture', '', [
        const FieldInput('Value', '', 'LEGACY_VALUE_ONLY'),
      ]);
      var c = await service.owner.createStringCredential(
        name: 'Legacy synthetic token',
        publicPurpose: '',
        secret: 'LEGACY_SECRET_ONLY',
      );
      c = await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'GH_TOKEN',
        discoverable: true,
      );
      final session = service.agent.openSession('Legacy private session');
      for (final use in [true, false]) {
        final request = await service.agent.requestCredentialUse(
          session,
          CredentialUseInput.fromJson({
            'command': 'request-use',
            'purpose': 'Legacy one-use fixture',
            'credentials': [
              {'alias': 'token', 'credentialId': c.id, 'version': 1},
            ],
            'launch': {
              'receiver': 'gh_token',
              'executable': Platform.resolvedExecutable,
              'argv': ['api', 'user'],
              'cwd': Directory.current.path,
              'env': {
                'GH_TOKEN': {'secret': 'token'},
              },
            },
          }),
        );
        await service.owner.decideCredentialUse(
          request.id,
          approveCredential: true,
        );
        if (use) {
          final material = await service.agent.consumeCredentialUse(
            session,
            request.id,
          );
          await service.agent.reportCredentialExecution(
            CredentialExecutionReport(
              executionId: material.executionId,
              executionCapability: material.executionCapability,
              state: 'start_failed',
              errorCode: 'process_start_failed',
              finishedAt: now,
            ),
          );
        }
      }
      final parent = Directory(args[1]).parent.path;
      final key = await repo.backups.enable();
      await repo.backups.saveRecoveryKeyTo('$parent/legacy-recovery.txt');
      await service.owner.exportLibrary(
        () => repo!.backups.exportTo('$parent/legacy5.aimbackup'),
      );
      final preview = await repo.backups.inspect(
        '$parent/legacy5.aimbackup',
        key,
      );
      final db = sqlite.sqlite3.open('${args[1]}/library.db');
      try {
        db.execute('PRAGMA key = "x\'${'3d' * 32}\'"');
        stdout.writeln(
          jsonEncode({
            'status': 'created',
            'schema': db.select('PRAGMA user_version').single.values.single,
            'backupVersion': preview.formatVersion,
          }),
        );
      } finally {
        db.close();
      }
    } else if (args.first == 'inspect-backup') {
      final key = (await File(args[3]).readAsString()).trim();
      final preview = await repo.backups.inspect(args[2], key);
      stdout.writeln(
        jsonEncode({
          'status': 'opened',
          'backupVersion': preview.formatVersion,
        }),
      );
    } else {
      stdout.writeln('{"status":"opened"}');
    }
  } on StorageFailure catch (e) {
    stdout.writeln(jsonEncode({'status': 'rejected', 'errorCode': e.code}));
  } on Object {
    stdout.writeln('{"status":"rejected","errorCode":"probe_failure"}');
  } finally {
    await service?.close();
    await repo?.close();
  }
}
