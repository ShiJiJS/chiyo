import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';

class Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

void main() {
  for (final legacy in [1, 12, 13]) {
    test(
      'schema $legacy migrates directly to credential storage with request facts and backup four',
      () async {
        final folder = await Directory.systemTemp.createTemp(
          'credential-migration-$legacy-',
        );
        addTearDown(() => folder.delete(recursive: true));
        final keys = Keys()..key = List.filled(32, 17);
        if (legacy != 1) {
          final initial = await EncryptedInformationRepository.open(
            folder.path,
            keys,
          );
          final service = InformationService(repository: initial);
          await service.owner.createInformation('Existing', '', [
            const FieldInput('Host', '', 'synthetic.invalid'),
          ]);
          await initial.backups.enable();
          if (legacy == 13) {
            await initial.backups.saveRecoveryKeyTo(
              '${folder.path}/before-key.txt',
            );
          }
          await service.close();
          await initial.close();
        }
        final fixture = sqlite3.open('${folder.path}/library.db');
        fixture.execute('PRAGMA key = "x\'${'11' * 32}\'"');
        if (legacy == 1) {
          fixture.execute(
            'CREATE TABLE information_items(id TEXT PRIMARY KEY,name TEXT NOT NULL,description TEXT NOT NULL)',
          );
          fixture.execute(
            'CREATE TABLE information_fields(id TEXT PRIMARY KEY,item_id TEXT NOT NULL,name TEXT NOT NULL,description TEXT NOT NULL,value TEXT NOT NULL)',
          );
          fixture.execute(
            "INSERT INTO information_items VALUES('legacy','Existing','')",
          );
          fixture.execute(
            "INSERT INTO information_fields VALUES('legacy-host','legacy','Host','','synthetic.invalid')",
          );
        } else {
          fixture.execute('DROP TABLE credential_materials');
          fixture.execute('DROP TABLE managed_credentials');
          if (legacy == 12) {
            fixture.execute('DROP TABLE request_history');
            fixture.execute(
              'ALTER TABLE backup_configuration DROP COLUMN recovery_saved',
            );
          }
        }
        fixture.execute('PRAGMA user_version = $legacy');
        fixture.close();
        var store = await EncryptedInformationRepository.open(
          folder.path,
          keys,
        );
        var service = InformationService(repository: store);
        expect(service.owner.information.single.name, 'Existing');
        expect(service.owner.credentials, isEmpty);
        final item = service.owner.information.single;
        final session = service.agent.openSession('Synthetic migration');
        final request = service.agent.request(session, 'Synthetic request', [
          FieldRef(item.id, item.fields.single.id),
        ]);
        service.owner.deny(request.id);
        expect((await service.owner.history()).requests.single.id, request.id);
        await store.backups.enable();
        expect(await store.backups.recoveryKeySaved(), legacy == 13);
        if (legacy != 13) {
          await store.backups.saveRecoveryKeyTo('${folder.path}/after-key.txt');
        }
        final key = (await store.backups.recoveryKey())!;
        await service.owner.exportLibrary(
          () => store.backups.exportTo('${folder.path}/format-four.aim'),
        );
        final snapshot = await store.backups.inspect(
          '${folder.path}/format-four.aim',
          key,
        );
        expect(snapshot.formatVersion, 4);
        expect(snapshot.requestHistoryCount, 1);
        final credential = await service.owner.createStringCredential(
          name: 'Synthetic token',
          publicPurpose: 'API',
          secret: 'fictional',
        );
        await service.close();
        await store.close();
        store = await EncryptedInformationRepository.open(folder.path, keys);
        service = InformationService(repository: store);
        expect(service.owner.credential(credential.id).version, 1);
        expect((await service.owner.history()).requests.single.id, request.id);
        expect(await store.backups.recoveryKeySaved(), isTrue);
        await service.close();
        await store.close();
      },
    );
  }
  test(
    'SQLCipher vault reopens string/file versions without source files or plaintext',
    () async {
      final folder = await Directory.systemTemp.createTemp('credential-vault-');
      addTearDown(() => folder.delete(recursive: true));
      final keys = Keys();
      var store = await EncryptedInformationRepository.open(folder.path, keys);
      var service = InformationService(repository: store);
      addTearDown(() => service.close());
      addTearDown(() => store.close());
      final string = await service.owner.createStringCredential(
        name: 'Token',
        publicPurpose: 'API',
        secret: 'FICTIONAL-SECRET-63831',
      );
      final file = await service.owner.createFileCredential(
        name: 'Key',
        publicPurpose: 'SSH',
        fileName: 'synthetic.key',
        bytes: 'FICTIONAL-FILE-BYTES-63831'.codeUnits,
      );
      await store.backups.enable();
      await store.backups.saveRecoveryKeyTo(
        '${folder.path}/synthetic-recovery.key',
      );
      await expectLater(
        store.backups.exportTo('${folder.path}/incomplete.backup'),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'credentials_backup_not_supported',
          ),
        ),
      );
      await service.owner.rotateStringCredential(
        string.id,
        1,
        'FICTIONAL-ROTATED-63831',
      );
      final vault = store as CredentialRepository;
      final current = vault.credentialMaterials.last;
      await expectLater(
        vault.commitCredentials(vault.managedCredentials, [
          for (final m in vault.credentialMaterials)
            if (identical(m, current))
              CredentialMaterial(
                credentialId: m.credentialId,
                version: m.version,
                bytes: [99],
                createdAt: m.createdAt,
                retiredAt: m.retiredAt,
                fileName: m.fileName,
              )
            else
              m,
        ]),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'credential_version_immutable',
          ),
        ),
      );
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: store);
      addTearDown(store.close);
      addTearDown(service.close);
      expect(service.owner.credentials.length, 2);
      expect(service.owner.credential(string.id).version, 2);
      expect(service.owner.credential(file.id).fileName, 'synthetic.key');
      expect(
        (store as CredentialRepository).credentialMaterials
            .where((m) => m.credentialId == file.id)
            .single
            .bytes,
        'FICTIONAL-FILE-BYTES-63831'.codeUnits,
      );
      for (final entry in folder.listSync().whereType<File>().where(
        (f) => !f.path.endsWith('.lock'),
      )) {
        expect(
          String.fromCharCodes(entry.readAsBytesSync()),
          isNot(contains('FICTIONAL-')),
        );
      }
    },
  );
}
