import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import '../../info_core/test/fixtures/credential_import_fixture.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'credential drafts, cyclic admission and owner receipts are encrypted, atomic and recoverable',
    () async {
      final root = await Directory.systemTemp.createTemp('credential-import-');
      final keys = TestKeyStore();
      late EncryptedInformationRepository repo;
      late InformationService service;
      Future<void> open() async {
        repo = await EncryptedInformationRepository.open(
          '${root.path}/library',
          keys,
        );
        service = InformationService(repository: repo);
        configureCredentialImports(service);
      }

      Future<void> close() async {
        await service.close();
        await repo.close();
      }

      await open();
      addTearDown(() async {
        await close();
        await root.delete(recursive: true);
      });
      ImportProposal proposal(String id) =>
          service.owner.importProposals.singleWhere((p) => p.id == id);
      Future<OwnerProposalReceipt> approve(
        String id,
        String operation,
        String key,
      ) {
        final p = proposal(id);
        return service.owner.performProposalDecision(
          OwnerProposalCommand(
            operationId: operation,
            proposalId: id,
            kind: ProposalKind.addition,
            confirm: true,
            version: p.version,
            reviewToken: 'b' * 64,
            commandDigest: 'd' * 64,
          ),
          validate: () {
            if (proposal(id).version != p.version)
              throw const AccessFailure('proposal_changed');
          },
          decide: () async {
            await service.owner.confirmImport(
              id,
              p.version,
              p.items.where((i) => i.key == key).toList(),
            );
          },
        );
      }

      int sql(String statement) {
        final db = sqlite3.open('${root.path}/library/library.db');
        try {
          final hex = keys.key!
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join();
          db.execute('PRAGMA key = "x\'$hex\'"');
          if (statement.startsWith('PRAGMA'))
            return db.select(statement).single.values.single as int;
          db.execute(statement);
          return 0;
        } finally {
          db.close();
        }
      }

      final session = service.agent.openSession('合成凭据审批');
      final input = [
        credentialInput(
          'password',
          'accountPassword',
          CredentialImportInput.owner(),
          pending: [ImportPendingReference('information', 'note')],
        ),
        ImportItemInput(
          '合成说明',
          '',
          [],
          key: 'note',
          templateId: 'note',
          templateVersion: '1',
          templateDigest: 'a' * 64,
          values: {'body': 'PRIVATE-NOTE'},
          pendingRelations: {
            'related': [ImportPendingReference('credential', 'password')],
          },
        ),
      ];
      final id = await service.agent.submitImport(
        session,
        input,
        operationId: 'synthetic-intake',
      );
      expect(
        await service.agent.submitImport(
          session,
          input,
          operationId: 'synthetic-intake',
        ),
        id,
      );
      await service.owner.fillImportCredential(
        id,
        proposal(id).version,
        'password',
        'PRIVATE-PASSWORD-KEEP',
      );
      expect(
        (await approve(id, 'password-approval', 'password')).awaitingKeys,
        ['password'],
      );
      expect(repo.managedCredentials, isEmpty);
      await close();
      await open();
      expect(sql('PRAGMA user_version'), 45);
      expect(proposal(id).approvedKeys, {'password'});
      expect(
        utf8.decode(proposal(id).items.first.credential!.material!),
        'PRIVATE-PASSWORD-KEEP',
      );
      sql(
        "CREATE TRIGGER fail_credential_import BEFORE INSERT ON owner_proposal_operations WHEN NEW.operation_id='note-approval' BEGIN SELECT RAISE(ABORT, 'synthetic'); END",
      );
      await expectLater(
        approve(id, 'note-approval', 'note'),
        throwsA(isA<StorageFailure>()),
      );
      expect(repo.items, isEmpty);
      expect(repo.managedCredentials, isEmpty);
      expect(repo.credentialMaterials, isEmpty);
      await close();
      await open();
      expect(repo.managedCredentials, isEmpty);
      expect(proposal(id).approvedKeys, {'password'});
      sql('DROP TRIGGER fail_credential_import');
      final result = await approve(id, 'note-approval', 'note');
      expect(result.records.length, 1);
      expect(repo.items.length, 1);
      expect(repo.managedCredentials.length, 1);
      final credential = repo.managedCredentials.single;
      expect(credential.linkedItemIds, [repo.items.single.id]);
      expect(
        repo.items.single.layout!.relations['related']!.single.id,
        credential.id,
      );
      expect(proposal(id).items, isEmpty);
      expect(
        jsonEncode(proposal(id).toJson()),
        isNot(contains(base64Encode(utf8.encode('PRIVATE-PASSWORD-KEEP')))),
      );
      await close();
      await open();
      expect(
        repo.managedCredentials.single.template!.typeId,
        'credential.accountPassword',
      );
      expect(
        utf8.decode(repo.credentialMaterials.single.bytes),
        'PRIVATE-PASSWORD-KEEP',
      );
      expect(
        (await service.owner.ownerProposalReceipt(
          'note-approval',
        ))!.records.single.id,
        repo.items.single.id,
      );

      Future<void> editLinks(String operation, List<String> links) async {
        final c = repo.managedCredentials.single;
        await service.owner.saveCredentialRecord(
          operation,
          CredentialRecordInput(
            action: CredentialRecordAction.edit,
            commandDigest: 'e' * 64,
            credentialId: c.id,
            expectedRevision: c.revision,
            expectedMaterialVersion: c.version,
            name: c.name,
            publicPurpose: c.publicPurpose,
            privateNote: c.privateNote,
            suggestedBinding: c.suggestedBinding,
            linkedItemIds: links,
          ),
        );
      }

      await editLinks('owner-detach', []);
      expect(
        repo.managedCredentials.single.template!.relations.values.expand(
          (v) => v,
        ),
        isEmpty,
      );
      await editLinks('owner-reattach', [repo.items.single.id]);
      expect(
        repo.managedCredentials.single.template!.relations.values
            .expand((v) => v)
            .single
            .id,
        repo.items.single.id,
      );
      await repo.backups.enable();
      await repo.backups.saveRecoveryKeyTo('${root.path}/recovery-key.txt');
      final recoveryKey = (await repo.backups.recoveryKey())!;
      final backupPath = '${root.path}/complete.aim';
      await repo.backups.exportTo(backupPath);
      final backup = await repo.backups.inspect(backupPath, recoveryKey);
      expect(backup.formatVersion, 16);
      final restored = await EncryptedInformationRepository.open(
        '${root.path}/restored',
        TestKeyStore(),
      );
      try {
        await restored.backups.restore(backup);
        expect(
          restored.managedCredentials.single.template!.relations.values
              .expand((v) => v)
              .single
              .id,
          restored.items.single.id,
        );
        expect(
          utf8.decode(restored.credentialMaterials.single.bytes),
          'PRIVATE-PASSWORD-KEEP',
        );
      } finally {
        await restored.close();
      }
      // Whole database, WAL and portable backup remain ciphertext on disk.
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        if (file.path.endsWith('recovery-key.txt')) continue;
        final bytes = await file.readAsBytes();
        final text = latin1.decode(bytes);
        expect(text, isNot(contains('PRIVATE-PASSWORD-KEEP')));
        expect(
          text,
          isNot(contains(base64Encode(utf8.encode('PRIVATE-PASSWORD-KEEP')))),
        );
      }
    },
  );
}
