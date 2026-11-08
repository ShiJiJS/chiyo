import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real encrypted host reopens with the same save receipt and content',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-server-host-');
      addTearDown(() => root.delete(recursive: true));
      final key = File('${root.path}/database.key');
      await key.writeAsBytes(List.generate(32, (i) => i));
      expect((await Process.run('chmod', ['600', key.path])).exitCode, 0);
      final keys = MountedDatabaseKeyStore(key.path);
      final data = '${root.path}/data';
      final input = InformationDraftInput(
        name: '合成主机',
        description: '服务重开验收',
        fields: [
          const InformationDraftField.text('地址', '', 'synthetic.invalid'),
        ],
      );
      var repo = await EncryptedInformationRepository.open(data, keys);
      var service = InformationService(repository: repo);
      late InformationRecordReceipt receipt;
      try {
        receipt = await service.owner.saveInformationRecord('save-1', input);
      } finally {
        await service.close();
        await repo.close();
      }
      repo = await EncryptedInformationRepository.open(data, keys);
      service = InformationService(repository: repo);
      try {
        final retry = await service.owner.saveInformationRecord(
          'save-1',
          input,
        );
        expect(retry.toJson(), receipt.toJson());
        expect(service.owner.information, hasLength(1));
        expect(
          service.owner.information.single.fields.single.value,
          'synthetic.invalid',
        );
        expect(
          String.fromCharCodes(
            await File('$data/library.db').readAsBytes(),
          ).contains('synthetic.invalid'),
          isFalse,
        );
      } finally {
        await service.close();
        await repo.close();
      }
      final original = await File('$data/library.db').readAsBytes();
      await key.delete();
      await expectLater(
        EncryptedInformationRepository.open(data, keys),
        throwsA(isA<StorageFailure>()),
      );
      expect(await File('$data/library.db').readAsBytes(), original);
      expect(await key.exists(), isFalse);
      await key.writeAsBytes(List.filled(32, 55));
      await Process.run('chmod', ['600', key.path]);
      await expectLater(
        EncryptedInformationRepository.open(data, keys),
        throwsA(isA<StorageFailure>()),
      );
      expect(await File('$data/library.db').readAsBytes(), original);
    },
  );
}
