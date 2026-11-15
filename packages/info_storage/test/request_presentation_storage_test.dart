import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  test(
    'titles survive encrypted reopen and backup restore without resurrecting approval',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'request-presentation-',
      );
      addTearDown(() => root.delete(recursive: true));
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        keys,
      );
      var service = InformationService(repository: repo);
      final created = await service.owner.createStringCredential(
        name: 'Test login',
        publicPurpose: 'Test service',
        secret: 'SYNTHETIC_ONLY',
      );
      final c = await service.owner.updateCredentialMetadata(
        created.id,
        created.revision,
        name: created.name,
        publicPurpose: created.publicPurpose,
        privateNote: '',
        suggestedBinding: created.suggestedBinding,
        discoverable: true,
      );
      final session = service.agent.openSession('Test chat');
      final r = await service.agent.requestCredentialBatch(
        session,
        'AAAAAAAAAAAAAAAAAAAAAA',
        CredentialBatchInput.fromJson({
          'protocolVersion': 3,
          'title': '登录测试工作台',
          'purpose': '继续处理测试项目。',
          'items': [
            {
              'credentialId': c.id,
              'destination': {
                'via': 'ego',
                'target': {
                  'provider': 'ego',
                  'instanceId': 'test-browser',
                  'space': 7,
                  'pageId': 'p1',
                  'url': 'https://example.test/login',
                  'form': '#login',
                  'field': '#password',
                  'structureDigest': 'a' * 64,
                },
              },
            },
          ],
        }),
        operationId: 'submit-title',
      );
      await service.owner.decideCredentialBatch(
        r.id,
        operationId: 'approve-title',
        revision: 1,
        approvedItems: ['b1'],
      );
      final recovery = await enableTestBackups(repo.backups);
      final path = '${root.path}/history.aimbackup';
      await service.owner.exportLibrary(() => repo.backups.exportTo(path));
      expect((await repo.backups.inspect(path, recovery)).formatVersion, 33);
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        keys,
      );
      service = InformationService(repository: repo);
      expect(repo.credentialBatches.single.title, '登录测试工作台');
      expect(repo.credentialBatches.single.summary, '继续处理测试项目。');
      await service.close();
      await repo.close();
      final target = await EncryptedInformationRepository.open(
        '${root.path}/restored',
        TestKeyStore(),
      );
      final restored = InformationService(repository: target);
      addTearDown(() async {
        await restored.close();
        await target.close();
      });
      await restored.owner.restoreLibrary(
        () => target.backups.restoreFrom(path, recovery),
      );
      final history = target.credentialBatches.single;
      expect(history.title, '登录测试工作台');
      expect(history.summary, '继续处理测试项目。');
      expect(history.archived, true);
      expect(
        restored.owner.credentialBatchItemState(history, history.items.single),
        'revoked',
      );
    },
  );
}
