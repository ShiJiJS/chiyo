import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

class Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

void main() {
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
