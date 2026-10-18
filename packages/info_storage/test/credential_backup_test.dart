import 'backup_setup.dart';
import 'dart:io';
import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';

Future<void> _changeBackup(
  String source,
  String target,
  String key,
  void Function(Map<String, dynamic>) change,
) async {
  await File(source).copy(target);
  final db = sqlite3.open(target);
  try {
    final hex = base64Url
        .decode(key.substring('aim-recovery-v1:'.length))
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    final payload =
        jsonDecode(
              db.select('SELECT payload FROM backup_snapshot').single['payload']
                  as String,
            )
            as Map<String, dynamic>;
    change(payload);
    db.execute('UPDATE backup_snapshot SET payload=?', [jsonEncode(payload)]);
  } finally {
    db.close();
  }
}

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

void main() {
  test(
    'restored credential history contains no pending authority or private process registration',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'synthetic-credential-history-backup-',
      );
      addTearDown(() => root.delete(recursive: true));
      final now = DateTime.utc(2026, 10, 18);
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        _Keys(),
        clock: () => now,
      );
      addTearDown(source.close);
      final service = InformationService(
        repository: source,
        clock: () => now,
        credentialExecutableInspector: (p, r) async =>
            ExecutableIdentity(p, 1, 1, 'sha256:fixture'),
      );
      addTearDown(service.close);
      var c = await service.owner.createStringCredential(
        name: 'Synthetic',
        publicPurpose: '',
        secret: 'synthetic-only',
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
      final session = service.agent.openSession('Synthetic source session');
      final info = await service.owner.createInformation(
        'Synthetic server',
        '',
        [const FieldInput('Host', '', 'synthetic.invalid')],
      );
      Future<CredentialUseRequest> request() =>
          service.agent.requestCredentialUse(
            session,
            CredentialUseInput.fromJson({
              'command': 'request-use',
              'readFields': [
                {'itemId': info.id, 'fieldId': info.fields.single.id},
              ],
              'purpose': 'Synthetic',
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
      final pending = await request(),
          unused = await request(),
          used = await request();
      await service.owner.decideCredentialUse(
        unused.id,
        approveCredential: true,
      );
      await service.owner.decideCredentialUse(used.id, approveCredential: true);
      final material = await service.agent.consumeCredentialUse(
        session,
        used.id,
      );
      await source.commitCredentialRuntime(source.credentialUseRequests, [
        source.credentialExecutions.single.changed({
          'supervisorPid': 99991,
          'supervisorCreatedAt': 'windows:111',
          'workerPid': 99992,
          'workerCreatedAt': 'windows:222',
          'jobName':
              'Local\\AgentInfoRuntime-SYNTHETIC_ONLY_1234567890123456789',
        }),
      ]);
      final recovery = await enableTestBackups(source.backups),
          path = '${root.path}/history.aimbackup';
      await service.owner.exportLibrary(() => source.backups.exportTo(path));
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
        clock: () => now,
      );
      addTearDown(target.close);
      final restored = InformationService(repository: target, clock: () => now);
      addTearDown(restored.close);
      await restored.owner.restoreLibrary(
        () => target.backups.restoreFrom(path, recovery),
      );
      expect(
        restored.owner.credentialUseRequests.map((r) => r.id),
        unorderedEquals([unused.id, used.id]),
      );
      expect(
        restored.owner.credentialUseRequests.any((r) => r.id == pending.id),
        isFalse,
      );
      expect(
        restored.owner.credentialGrantState(
          restored.owner.credentialUseRequests.firstWhere(
            (r) => r.id == unused.id,
          ),
        ),
        'revoked',
      );
      final execution = restored.owner.credentialExecutions.single;
      expect(execution.state, 'unknown');
      expect(execution.finishedAt, isNull);
      expect(execution.cleanupState, 'not_needed');
      expect(execution.restoredAt, now);
      final facts = jsonEncode(execution.toStorageJson());
      for (final absent in [
        '99991',
        'windows:111',
        '99992',
        'windows:222',
        'Local\\',
        material.executionCapability,
        session,
      ]) {
        expect(facts, isNot(contains(absent)));
      }
      await expectLater(
        restored.agent.consumeCredentialUse(session, unused.id),
        throwsA(isA<CredentialUseFailure>()),
      );
      final portable = '${root.path}/portable-history.aimbackup';
      await _changeBackup(path, portable, recovery, (payload) {
        for (final row
            in payload['tables']['credential_use_requests'] as List) {
          final r = jsonDecode(row['payload'] as String);
          for (final key in ['plan', 'requestedPlan']) {
            if (r[key] == null) continue;
            r[key]['executable'] = '/usr/bin/gh';
            r[key]['executableIdentity']['path'] = '/usr/bin/gh';
            r[key]['cwd'] = '/workspace';
          }
          row['payload'] = jsonEncode(r);
        }
      });
      expect(
        (await source.backups.inspect(portable, recovery)).formatVersion,
        5,
      );
    },
  );
  test(
    'format five restores credential bytes, versions, states and links under a fresh local key',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'synthetic-credential-backup-',
      );
      addTearDown(() => root.delete(recursive: true));
      final now = DateTime.utc(2026, 10, 18);
      final sourceKeys = _Keys(), targetKeys = _Keys();
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        sourceKeys,
        clock: () => now,
      );
      addTearDown(source.close);
      final service = InformationService(repository: source, clock: () => now);
      addTearDown(service.close);
      final item = await service.owner.createInformation('Server', '', [
        const FieldInput('Host', '', 'synthetic.invalid'),
      ]);
      var token = await service.owner.createStringCredential(
        name: 'Synthetic token',
        publicPurpose: 'Test only',
        secret: 'synthetic-v1',
      );
      token = await service.owner.rotateStringCredential(
        token.id,
        token.revision,
        'synthetic-v2',
      );
      await service.owner.setCredentialEnabled(token.id, token.revision, false);
      final file = await service.owner.createFileCredential(
        name: 'Synthetic file',
        publicPurpose: 'Test only',
        fileName: 'fixture.key',
        bytes: [0, 128, 255, 10],
        expiresAt: now.subtract(const Duration(days: 1)),
      );
      await service.owner.setCredentialLinks(file.id, file.revision, [item.id]);
      final recovery = await enableTestBackups(source.backups);
      final path = '${root.path}/complete.aimbackup';
      await service.owner.exportLibrary(() => source.backups.exportTo(path));
      final preview = await source.backups.inspect(path, recovery);
      expect(preview.formatVersion, 5);
      expect(preview.credentialCount, 2);
      expect(preview.credentialVersionCount, 3);
      for (final mutation in [
        'unknown-secret-field',
        'bad-material',
        'wrong-version',
        'missing-material',
      ]) {
        final broken = '${root.path}/$mutation.aimbackup';
        await _changeBackup(path, broken, recovery, (payload) {
          final tables = payload['tables'];
          if (mutation == 'missing-material') {
            (tables['credential_materials'] as List).clear();
          } else if (mutation == 'unknown-secret-field') {
            final row = tables['managed_credentials'][0],
                j = jsonDecode(
                  tables['managed_credentials'][0]['payload'] as String,
                );
            j['sourceFilePath'] = 'C:/synthetic-private-source.key';
            row['payload'] = jsonEncode(j);
          } else {
            final row = tables['credential_materials'][0],
                j = jsonDecode(
                  tables['credential_materials'][0]['payload'] as String,
                );
            if (mutation == 'bad-material') {
              j['bytes'] = 'not base64';
            } else {
              j['version'] = 99;
            }
            row['payload'] = jsonEncode(j);
          }
        });
        await expectLater(
          source.backups.inspect(broken, recovery),
          throwsA(
            isA<StorageFailure>().having(
              (e) => e.code,
              'code',
              'invalid_backup',
            ),
          ),
        );
      }
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        targetKeys,
        clock: () => now,
      );
      addTearDown(target.close);
      final restored = InformationService(repository: target, clock: () => now);
      addTearDown(restored.close);
      await restored.owner.restoreLibrary(
        () => target.backups.restore(preview),
      );
      expect(targetKeys.key, isNot(sourceKeys.key));
      expect(restored.owner.information.single.id, item.id);
      expect(restored.owner.credential(token.id).enabled, isFalse);
      expect(restored.owner.credential(token.id).version, 2);
      expect(
        restored.owner.credentialAvailability(
          restored.owner.credential(file.id),
        ),
        CredentialAvailability.expired,
      );
      expect(
        restored.owner.credentialsForInformation(item.id).single.id,
        file.id,
      );
      expect(
        target.credentialMaterials
            .where((m) => m.credentialId == file.id)
            .single
            .bytes,
        [0, 128, 255, 10],
      );
      expect(
        target.credentialMaterials
            .where((m) => m.credentialId == token.id)
            .map((m) => m.version),
        [1, 2],
      );
      expect(await target.backups.recoveryKey(), isNull);
    },
  );
}
