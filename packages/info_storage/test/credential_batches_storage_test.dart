import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

const _device = 'AAAAAAAAAAAAAAAAAAAAAA';
CredentialBatchInput _input(String id) => CredentialBatchInput.fromJson({
  'protocolVersion': 3,
  'purpose': 'Synthetic login',
  'agentName': 'Trial Agent',
  'externalChatId': 'synthetic-chat',
  'items': [
    {
      'credentialId': id,
      'destination': {
        'via': 'ego',
        'target': {
          'provider': 'ego',
          'instanceId': 'synthetic-browser',
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
});
Future<ManagedCredential> _credential(InformationService service) async {
  final c = await service.owner.createStringCredential(
    name: 'Synthetic login',
    publicPurpose: 'Synthetic service',
    secret: 'PRIVATE-BATCH-PASSWORD',
  );
  return service.owner.updateCredentialMetadata(
    c.id,
    c.revision,
    name: c.name,
    publicPurpose: c.publicPurpose,
    privateNote: '',
    suggestedBinding: c.suggestedBinding,
    discoverable: true,
  );
}

void main() {
  test(
    'encrypted batches preserve live server grants, not an interrupted input capability',
    () async {
      final root = await Directory.systemTemp.createTemp('encrypted-batches-');
      addTearDown(() => root.delete(recursive: true));
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.openOnline(
        root.path,
        keys,
      );
      var runtime = await OnlineInformationRuntime.open(repository: repo);
      final c = await runtime.run(() => _credential(runtime.service));
      final session = await runtime.run(
        () => runtime.service.agent.openSession('Synthetic chat'),
      );
      final r = await runtime.run(
        () => runtime.service.agent.requestCredentialBatch(
          session,
          _device,
          _input(c.id),
          operationId: 'submit-1',
        ),
      );
      final approved = await runtime.run(
        () => runtime.service.owner.decideCredentialBatch(
          r.id,
          operationId: 'approve-1',
          revision: r.revision,
          approvedItems: ['b1'],
        ),
      );
      final started = await runtime.run(
        () => runtime.service.agent.beginCredentialBatchOperation(
          session,
          _device,
          r.id,
          operationId: 'fill-1',
        ),
      );
      await runtime.close();
      await repo.close();
      repo = await EncryptedInformationRepository.openOnline(root.path, keys);
      runtime = await OnlineInformationRuntime.open(repository: repo);
      addTearDown(() async {
        await runtime.close();
        await repo.close();
      });
      final status = runtime.service.agent.credentialBatchStatus(
        session,
        _device,
        r.id,
      );
      expect((status['items'] as List).single['grantState'], 'available');
      expect(
        repo.credentialBatches.single.items.single.expiresAt,
        approved.items.single.expiresAt,
      );
      expect(
        repo.credentialBatchOperations.single.state,
        CredentialBatchOperationState.unknown,
      );
      final repeat = await runtime.run(
        () => runtime.service.agent.beginCredentialBatchOperation(
          session,
          _device,
          r.id,
          operationId: 'fill-1',
        ),
      );
      expect(repeat.privateProof, isNull);
      expect(repeat.operation.state, CredentialBatchOperationState.unknown);
      await expectLater(
        runtime.run(
          () => runtime.service.agent.claimCredentialBatchMaterials(
            _device,
            started.privateProof!,
            {'b1': r.items.single.destination},
          ),
        ),
        throwsA(isA<CredentialUseFailure>()),
      );
      for (final file in root.listSync().whereType<File>().where(
        (f) => !f.path.endsWith('.lock'),
      )) {
        expect(
          String.fromCharCodes(await file.readAsBytes()),
          isNot(contains('PRIVATE-BATCH-PASSWORD')),
        );
      }
    },
  );

  test(
    'portable backup keeps decided batch history, drops pending work, and restores no usable grant',
    () async {
      final root = await Directory.systemTemp.createTemp('batch-backup-');
      addTearDown(() => root.delete(recursive: true));
      final repo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        TestKeyStore(),
      );
      final service = InformationService(repository: repo);
      addTearDown(() async {
        await service.close();
        await repo.close();
      });
      final c = await _credential(service);
      final session = service.agent.openSession('Synthetic chat');
      final r = await service.agent.requestCredentialBatch(
        session,
        _device,
        _input(c.id),
        operationId: 'submit-1',
      );
      await service.owner.decideCredentialBatch(
        r.id,
        operationId: 'approve-1',
        revision: r.revision,
        approvedItems: ['b1'],
      );
      await service.agent.requestCredentialBatch(
        session,
        _device,
        _input(c.id),
        operationId: 'pending-2',
      );
      final operation = await service.agent.beginCredentialBatchOperation(
        session,
        _device,
        r.id,
        operationId: 'fill-1',
      );
      final recovery = await enableTestBackups(repo.backups);
      final path = '${root.path}/history.aimbackup';
      await service.owner.exportLibrary(() => repo.backups.exportTo(path));
      expect(
        service.agent.credentialBatchStatus(session, _device, r.id)['status'],
        'approved',
      );
      expect(repo.credentialBatches, hasLength(2));
      final preview = await repo.backups.inspect(path, recovery);
      expect(preview.formatVersion, 28);
      expect(preview.credentialUseHistoryCount, 1);
      expect(preview.credentialExecutionCount, 1);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
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
      expect(target.credentialBatches, hasLength(1));
      final history = target.credentialBatches.single;
      expect(history.id, r.id);
      expect(history.archived, true);
      expect(
        restored.owner.credentialBatchItemState(history, history.items.single),
        'revoked',
      );
      expect(
        target.credentialBatchOperations.single.state,
        CredentialBatchOperationState.unknown,
      );
      expect(
        jsonEncode(history.toJson()),
        isNot(contains(operation.privateProof!)),
      );
      final newSession = restored.agent.openSession('Synthetic chat');
      await expectLater(
        restored.agent.beginCredentialBatchOperation(
          newSession,
          _device,
          r.id,
          operationId: 'after-restore',
        ),
        throwsA(isA<CredentialUseFailure>()),
      );
    },
  );
}
