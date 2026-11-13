import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  test(
    'private reveal submission recovery survives storage reopen but never enters portable backup',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'private-reveal-submission-',
      );
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        keys,
      );
      var service = InformationService(repository: repo);
      addTearDown(() async {
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      var c = await service.owner.createStringCredential(
        name: 'Synthetic',
        publicPurpose: '',
        secret: 'PRIVATE-SYNTHETIC',
      );
      c = await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'TOKEN',
        discoverable: true,
      );
      final session = service.agent.openSession('Synthetic private recovery');
      final request = await service.agent.requestCredentialReveal(
        session,
        CredentialRevealInput.fromJson({
          'protocolVersion': 2,
          'command': 'request-reveal',
          'credentialId': c.id,
          'version': 1,
          'purpose': 'Synthetic fallback',
          'fallbackReason': 'Synthetic target unsupported',
          'operationId': 'create-reveal-once',
        }),
      );
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      final privateBinding =
          repo.credentialUseRequests.single.submissionSessionBinding;
      expect(privateBinding, isNotNull);
      final recovery = await enableTestBackups(repo.backups);
      final path = '${root.path}/portable.aimbackup';
      await service.owner.exportLibrary(() => repo.backups.exportTo(path));
      final archive = await AttachmentBackupContainer.openValidated(
        path,
        recovery,
      );
      expect(archive.formatVersion, 27);
      archive.close();
      final target = await EncryptedInformationRepository.open(
        '${root.path}/restored',
        TestKeyStore(),
      );
      final restored = InformationService(repository: target);
      try {
        await restored.owner.restoreLibrary(
          () => target.backups.restoreFrom(path, recovery),
        );
        expect(
          target.credentialUseRequests.single.submissionOperationId,
          isNull,
        );
        expect(
          target.credentialUseRequests.single.submissionSessionBinding,
          isNull,
        );
        expect(
          restored.owner.credentialGrantState(
            target.credentialUseRequests.single,
          ),
          isNot('available'),
        );
      } finally {
        await restored.close();
        await target.close();
      }
      await service.close();
      await repo.close();
      final db = sqlite.sqlite3.open('${root.path}/source/library.db');
      final hex = keys.key!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      expect(db.select('PRAGMA user_version').single.values.single, 66);
      db.close();
      repo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        keys,
      );
      service = InformationService(repository: repo);
      expect(
        repo.credentialUseRequests.single.submissionOperationId,
        'create-reveal-once',
      );
      expect(
        repo.credentialUseRequests.single.submissionSessionBinding,
        privateBinding,
      );
      expect(
        service.owner.credentialGrantState(repo.credentialUseRequests.single),
        isNot('available'),
      );
    },
  );
  test('program receiver facts also require the new backup reader', () async {
    final root = await Directory.systemTemp.createTemp(
      'synthetic-program-storage-',
    );
    final repo = await EncryptedInformationRepository.open(
      root.path,
      TestKeyStore(),
    );
    final service = InformationService(
      repository: repo,
      credentialExecutableInspector: (path, receiver) async =>
          ExecutableIdentity(path, 10, 100, 'sha256:${'a' * 64}'),
    );
    addTearDown(() async {
      await service.close();
      await repo.close();
      await root.delete(recursive: true);
    });
    var c = await service.owner.createStringCredential(
      name: 'Synthetic program',
      publicPurpose: '',
      secret: 'SYNTHETIC_PROGRAM_STORAGE',
    );
    c = await service.owner.updateCredentialMetadata(
      c.id,
      c.revision,
      name: c.name,
      publicPurpose: '',
      privateNote: '',
      suggestedBinding: 'TOKEN',
      discoverable: true,
    );
    final session = service.agent.openSession('Synthetic program');
    final request = await service.agent.requestCredentialUse(
      session,
      CredentialUseInput.fromJson({
        'protocolVersion': 2,
        'command': 'request-use',
        'purpose': 'Synthetic program input',
        'credentials': [
          {'alias': 'token', 'credentialId': c.id, 'version': 1},
        ],
        'launch': {
          'receiver': 'program_stdin',
          'executable': Platform.resolvedExecutable,
          'argv': ['synthetic'],
          'cwd': Directory.current.path,
          'env': <String, dynamic>{},
          'stdin': {'secret': 'token'},
        },
      }),
    );
    await service.owner.decideCredentialUse(
      request.id,
      approveCredential: true,
    );
    final recovery = await enableTestBackups(repo.backups);
    final path = '${root.path}/program.aimbackup';
    await service.owner.exportLibrary(() => repo.backups.exportTo(path));
    final archive = await AttachmentBackupContainer.openValidated(
      path,
      recovery,
    );
    expect(archive.formatVersion, 27);
    archive.close();
    expect(
      (await repo.backups.inspect(path, recovery)).credentialUseHistoryCount,
      1,
    );
  });

  test(
    'encrypted reveal history survives restart and backup without reviving permission',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'synthetic-reveal-storage-',
      );
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        keys,
      );
      var service = InformationService(repository: repo);
      addTearDown(() async {
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      var c = await service.owner.createStringCredential(
        name: 'Synthetic',
        publicPurpose: '',
        secret: 'SYNTHETIC_REVEAL_STORAGE',
      );
      c = await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'TOKEN',
        discoverable: true,
      );
      final session = service.agent.openSession('Synthetic');
      final r = await service.agent.requestCredentialReveal(
        session,
        CredentialRevealInput.fromJson({
          'protocolVersion': 2,
          'command': 'request-reveal',
          'credentialId': c.id,
          'version': 1,
          'purpose': 'Synthetic fallback',
          'fallbackReason': 'Synthetic unavailable input',
        }),
      );
      await service.owner.decideCredentialUse(r.id, approveCredential: true);
      expect(
        (await service.agent.readCredentialReveal(
          session,
          r.id,
          'read-1',
        ))['secret'],
        'SYNTHETIC_REVEAL_STORAGE',
      );
      expect(
        jsonEncode(repo.credentialUseRequests.single.toJson()),
        isNot(contains('SYNTHETIC_REVEAL_STORAGE')),
      );
      final recovery = await enableTestBackups(repo.backups);
      final path = '${root.path}/reveal.aimbackup';
      await service.owner.exportLibrary(() => repo.backups.exportTo(path));
      final archive = await AttachmentBackupContainer.openValidated(
        path,
        recovery,
      );
      expect(archive.formatVersion, 27);
      archive.close();
      final preview = await repo.backups.inspect(path, recovery);
      expect(preview.credentialUseHistoryCount, 1);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/restored',
        TestKeyStore(),
      );
      final restored = InformationService(repository: target);
      try {
        await restored.owner.restoreLibrary(
          () => target.backups.restoreFrom(path, recovery),
        );
        expect(
          target.credentialUseRequests.single.revealReads.single.operationId,
          'read-1',
        );
        expect(
          restored.owner.credentialGrantState(
            target.credentialUseRequests.single,
          ),
          isNot('available'),
        );
        expect(
          await restored.owner.readStringCredential(c.id, 1),
          'SYNTHETIC_REVEAL_STORAGE',
        );
      } finally {
        await restored.close();
        await target.close();
      }
      await service.close();
      await repo.close();
      final db = sqlite.sqlite3.open('${root.path}/source/library.db');
      final hex = keys.key!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      expect(db.select('PRAGMA user_version').single.values.single, 64);
      db.close();
      repo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        keys,
      );
      service = InformationService(repository: repo);
      expect(repo.credentialUseRequests.single.isReveal, isTrue);
      expect(
        repo.credentialUseRequests.single.revealReads.single.operationId,
        'read-1',
      );
      expect(
        service.owner.credentialGrantState(repo.credentialUseRequests.single),
        isNot('available'),
      );
    },
  );
}
