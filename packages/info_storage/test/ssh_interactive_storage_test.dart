import 'dart:io';

import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';
import '../../info_core/test/fixtures/ssh_session_fixture.dart'
    show knownHostBytes;

void main() {
  test('SSH destination and nonmaterial operation persist with content-triggered format and portable backup', () async {
    final root = await Directory.systemTemp.createTemp('ssh-storage-');
    final keys = TestKeyStore();
    final repo = await EncryptedInformationRepository.open(root.path, keys);
    final service = InformationService(repository: repo);
    addTearDown(() async {
      await service.close();
      await repo.close();
      await root.delete(recursive: true);
    });
    final session = service.agent.openSession('SSH synthetic');
    const device = 'AAAAAAAAAAAAAAAAAAAAAA';
    var credential = await service.owner.createStringCredential(
      name: 'Synthetic login',
      publicPurpose: 'Test only',
      secret: 'fake-password',
    );
    credential = await service.owner.updateCredentialMetadata(
      credential.id,
      credential.revision,
      name: credential.name,
      publicPurpose: credential.publicPurpose,
      privateNote: '',
      suggestedBinding: '',
      discoverable: true,
    );
    await service.owner.configureSshKnownHosts(
      'Synthetic trust',
      knownHostBytes(),
    );
    final request = await service.agent.requestCredentialBatch(
      session,
      device,
      CredentialBatchInput.fromJson({
        'protocolVersion': 3,
        'purpose': 'Test synthetic SSH',
        'agentName': 'Test Agent',
        'externalChatId': 'test-chat',
        'items': [
          {
            'credentialId': credential.id,
            'version': credential.version,
            'destination': {
              'via': 'ssh',
              'target': {
                'host': 'example.test',
                'port': 22,
                'user': 'fixture',
                'authentication': 'password',
                'credentialUse': 'login',
                'validity': 'session',
              },
            },
          },
        ],
      }),
      operationId: 'request',
    );
    await service.owner.decideCredentialBatch(
      request.id,
      operationId: 'approve',
      revision: request.revision,
      approvedItems: ['b1'],
      lifetime: null,
    );
    final operation = await service.agent.beginCredentialBatchOperation(
      session,
      device,
      request.id,
      operationId: 'run',
      sshContext: SshSessionOperationContext(
        kind: 'run',
        sessionId: 'ssh-test',
        runId: 'run',
        digest: 'sha256:${'a' * 64}',
        byteLength: 4,
      ),
    );
    await service.agent.authorizeCredentialBatchInput(
      device,
      operation.privateProof!,
    );
    await service.agent.finishCredentialBatchOperation(
      device,
      operation.privateProof!,
      CredentialBatchOperationState.filled,
      itemResults: {'b1': 'sent'},
    );
    final recovery = await enableTestBackups(repo.backups);
    final path = '${root.path}/ssh.aimbackup';
    await service.owner.exportLibrary(() => repo.backups.exportTo(path));
    final preview = await repo.backups.inspect(path, recovery);
    expect(preview.formatVersion, 31);
    final restoredRoot = Directory('${root.path}/restored');
    final restored = await EncryptedInformationRepository.open(
      restoredRoot.path,
      TestKeyStore(),
    );
    final restoredService = InformationService(repository: restored);
    addTearDown(() async {
      await restoredService.close();
      await restored.close();
    });
    await restoredService.owner.restoreLibrary(
      () => restored.backups.restoreFrom(path, recovery),
    );
    expect(
      restored
          .credentialBatches
          .single
          .items
          .single
          .destination
          .ssh!
          .credentialUse,
      'login',
    );
    expect(restored.credentialBatches.single.archived, isTrue);
    expect(restored.credentialBatchOperations.single.materialClaimed, isFalse);
    expect(restored.credentialBatchOperations.single.sshContext!.kind, 'run');
    expect(
      () => restoredService.agent.checkSshSessionGrant(
        restoredService.agent.openSession('different'),
        device,
        request.id,
      ),
      throwsA(isA<CredentialUseFailure>()),
    );
  });
}
