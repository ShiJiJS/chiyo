import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/server_configuration.dart';
import 'package:test/test.dart';

void main() {
  test(
    'existing single-device backup restores into a separately keyed server',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-backup-import-',
      );
      addTearDown(() => root.delete(recursive: true));
      await initializeServerSecrets('${root.path}/old-secrets');
      await initializeServerSecrets('${root.path}/new-secrets');
      final source = await EncryptedInformationRepository.open(
        '${root.path}/old-data',
        MountedDatabaseKeyStore('${root.path}/old-secrets/database.key'),
      );
      final old = InformationService(repository: source);
      final backup = '${root.path}/portable-backup';
      late String recoveryKey;
      late String itemId;
      try {
        // Same storage and manual backup API as the shipped single-device App.
        final item = await old.owner.createInformation(
          'Existing synthetic record',
          'portable fixture',
          [const FieldInput('Address', '', 'existing.synthetic.invalid')],
        );
        itemId = item.id;
        recoveryKey = await source.backups.enable();
        await source.backups.saveRecoveryKeyTo('${root.path}/recovery-key');
        await source.backups.exportTo(backup);
      } finally {
        await old.close();
        await source.close();
      }
      final targetKeys = MountedDatabaseKeyStore(
        '${root.path}/new-secrets/database.key',
      );
      var target = await EncryptedInformationRepository.open(
        '${root.path}/new-data',
        targetKeys,
      );
      try {
        final contents = await target.backups.inspect(backup, recoveryKey);
        expect(contents.informationCount, 1);
        await target.backups.restore(contents);
      } finally {
        await target.close();
      }
      target = await EncryptedInformationRepository.open(
        '${root.path}/new-data',
        targetKeys,
      );
      final restored = InformationService(repository: target);
      try {
        expect(restored.owner.information.single.id, itemId);
        expect(
          restored.owner.information.single.fields.single.value,
          'existing.synthetic.invalid',
        );
        expect(
          await target.backups.inspect(backup, recoveryKey),
          isA<BackupContents>(),
        );
        expect(
          await File('${root.path}/new-secrets/owner.token').readAsBytes(),
          isNot(
            await File('${root.path}/old-secrets/owner.token').readAsBytes(),
          ),
        );
        expect(
          await File('${root.path}/new-secrets/server.id').readAsBytes(),
          isNot(await File('${root.path}/old-secrets/server.id').readAsBytes()),
        );
      } finally {
        await restored.close();
        await target.close();
      }
    },
  );
}
