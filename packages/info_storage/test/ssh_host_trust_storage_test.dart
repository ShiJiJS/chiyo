import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import '../../info_core/test/ssh_credential_use_test.dart' show knownHostBytes;

void main() {
  test(
    'explicitly confirmed SSH host data survives encrypted reopening and clearing without reading user SSH configuration',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'ssh-trust-storage-',
      );
      final keys = TestKeyStore();
      var repository = await EncryptedInformationRepository.open(
        folder.path,
        keys,
      );
      var service = InformationService(repository: repository);
      addTearDown(() async {
        await service.close();
        await repository.close();
        await folder.delete(recursive: true);
      });
      expect(service.owner.sshKnownHosts, isNull);
      final confirmed = await service.owner.configureSshKnownHosts(
        'explicit-confirmed-hosts',
        knownHostBytes(),
      );
      await service.close();
      await repository.close();
      repository = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: repository);
      expect(service.owner.sshKnownHosts!.id, confirmed.id);
      expect(service.owner.sshKnownHosts!.sha256, confirmed.sha256);
      expect(service.owner.sshKnownHosts!.bytes, knownHostBytes());
      await service.owner.clearSshKnownHosts();
      await service.close();
      await repository.close();
      repository = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: repository);
      expect(service.owner.sshKnownHosts, isNull);
    },
  );
}
