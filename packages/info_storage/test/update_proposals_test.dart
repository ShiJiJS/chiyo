import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'reviewed updates and prior versions persist encrypted with removed fields gone',
    () async {
      final folder = await Directory.systemTemp.createTemp('info-updates-');
      addTearDown(() => folder.delete(recursive: true));
      final keys = TestKeyStore();
      var store = await EncryptedInformationRepository.open(folder.path, keys);
      var service = InformationService(repository: store);
      final item = await service.owner
          .createInformation('Server', 'Old public', [
            const FieldInput('Host', '', 'OLD-SECRET-92342'),
            const FieldInput('User', '', 'KEEP-SECRET-92342'),
          ]);
      final session = service.agent.openSession('update chat');
      final id = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, 1, [
          FieldChange.replace(
            item.fields.first.id,
            const FieldInput('Email', 'New meaning', 'NEW-SECRET-92342'),
          ),
        ], description: 'New public'),
      );
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: store);
      expect(
        service.owner.previewUpdate(id).before.fields.first.value,
        'OLD-SECRET-92342',
      );
      await service.owner.confirmUpdate(id, 1);
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      addTearDown(store.close);
      service = InformationService(repository: store);
      addTearDown(service.close);
      expect(service.owner.information.single.fields, hasLength(2));
      expect(
        service.owner.information.single.fields.any(
          (f) => f.id == item.fields.first.id,
        ),
        isFalse,
      );
      expect(
        service.owner.information.single.fields.first.value,
        'NEW-SECRET-92342',
      );
      expect(
        service.owner.informationRevisions.single.item.fields.first.value,
        'OLD-SECRET-92342',
      );
      expect(
        service.owner.updateProposals.single.state,
        UpdateProposalState.confirmed,
      );
      expect((await service.owner.confirmUpdate(id, 1)).version, 2);
      for (final file in folder.listSync().whereType<File>()) {
        if (file.path.endsWith('.lock')) continue;
        expect(
          String.fromCharCodes(file.readAsBytesSync()),
          isNot(contains('SECRET-92342')),
        );
      }
    },
  );
}
