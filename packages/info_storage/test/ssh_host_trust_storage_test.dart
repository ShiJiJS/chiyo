import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'storage_test.dart' show TestKeyStore;
import '../../info_core/test/fixtures/ssh_session_fixture.dart' show knownHostBytes;

void main() {
  test(
    'schema15 upgrades without losing existing information, and format5 restores confirmed SSH trust',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'ssh-trust-upgrade-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final keys = TestKeyStore();
      var repository = await EncryptedInformationRepository.open(
        folder.path,
        keys,
      );
      var service = InformationService(repository: repository);
      await service.owner.createInformation('Existing before schema16', '', [
        const FieldInput('Host', '', 'synthetic.invalid'),
      ]);
      await service.close();
      await repository.close();
      final legacy = sqlite3.open('${folder.path}/library.db');
      legacy.execute(
        'PRAGMA key = "x\'${keys.key!.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}\'"',
      );
      legacy.execute('DROP TABLE ssh_host_trust');
      legacy.execute('DROP TABLE credential_focused_fills');
      legacy.execute('DROP TABLE library_format');
      legacy.execute('DROP TABLE information_deliveries');
      legacy.execute('DROP TABLE information_file_fields');
      legacy.execute('DROP TABLE information_attachment_versions');
      legacy.execute('DROP TABLE information_draft_commits');
      legacy.execute('DROP TABLE information_file_stages');
      legacy.execute(
        'ALTER TABLE credential_runtime_requests RENAME TO credential_use_requests',
      );
      legacy.execute(
        'ALTER TABLE credential_operations RENAME TO credential_executions',
      );
      legacy.execute('PRAGMA user_version = 15');
      legacy.close();
      repository = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: repository);
      addTearDown(() async {
        await service.close();
        await repository.close();
      });
      expect(service.owner.information.single.name, 'Existing before schema16');
      expect(service.owner.sshKnownHosts, isNull);
      await service.owner.configureSshKnownHosts(
        'confirmed after upgrade',
        knownHostBytes(),
      );
      await repository.backups.enable();
      await repository.backups.saveRecoveryKeyTo('${folder.path}/recovery.txt');
      final recovery = (await repository.backups.recoveryKey())!;
      await repository.backups.exportTo('${folder.path}/complete.aimbackup');
      await service.close();
      await repository.close();
      final restored = await EncryptedInformationRepository.open(
        '${folder.path}/restored',
        TestKeyStore(),
      );
      await restored.backups.restoreFrom(
        '${folder.path}/complete.aimbackup',
        recovery,
      );
      expect(restored.sshHostTrust!.bytes, knownHostBytes());
      expect(restored.sshHostTrust!.name, 'confirmed after upgrade');
      await restored.close();
      repository = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: repository);
      expect(service.owner.sshKnownHosts!.name, 'confirmed after upgrade');
    },
  );
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
