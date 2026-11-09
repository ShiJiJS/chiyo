import 'support/encrypted_artifacts.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import '../../info_core/test/fixtures/file_import_fixture.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  test(
    'pending originals survive restart; related admission and receipt rollback together, with exact versions restored from backup',
    () async {
      final root = await Directory.systemTemp.createTemp('file-intake-sql-');
      final keys = TestKeyStore();
      var now = DateTime.utc(2026, 11, 3);
      late EncryptedInformationRepository repo;
      late InformationService service;
      Future<void> open() async {
        repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          keys,
          clock: () => now,
        );
        service = InformationService(repository: repo, clock: () => now);
        configureFileImports(service);
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
          repo.importProposals.singleWhere((p) => p.id == id);
      int sql(String statement) {
        final db = sqlite3.open('${root.path}/data/library.db');
        try {
          final hex = keys.key!
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
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

      final session = service.agent.openSession('合成文件审批');
      Future<InformationImportUpload> upload(String id, String value) =>
          service.agent.uploadImportFile(
            session,
            operationId: id,
            originalName: '$id.pdf',
            mediaType: 'application/pdf',
            bytes: Uint8List.fromList(utf8.encode(value)),
          );
      final first = await upload('first', 'PRIVATE-ORIGINAL-A'),
          second = await upload('second', 'PRIVATE-ORIGINAL-B'),
          target = await upload('target', 'PRIVATE-TARGET');
      final id = await service.agent.submitImport(session, [
        fileInput(
          'resume',
          [first, second],
          current: 2,
          pending: [ImportPendingReference('information', 'target')],
        ),
        fileInput('target', [target]),
      ]);
      await expectLater(
        service.owner.confirmImport(id, proposal(id).version, [
          proposal(id).items.first,
        ]),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'proposal_incomplete',
          ),
        ),
      );
      expect(repo.items, isEmpty);
      expect(proposal(id).approvedKeys, isEmpty);
      await close();
      await open();
      expect(sql('PRAGMA user_version'), 47);
      expect(
        (await service.owner.readImportOriginal(
          id,
          'resume',
          'primary',
          1,
        )).bytes,
        utf8.encode('PRIVATE-ORIGINAL-A'),
      );
      now = now.add(const Duration(days: 2));
      await repo.pruneImportFiles(now, {first.id, second.id, target.id});
      expect(
        (await service.owner.readImportOriginal(
          id,
          'resume',
          'primary',
          2,
        )).bytes,
        utf8.encode('PRIVATE-ORIGINAL-B'),
      );
      Future<OwnerProposalReceipt> approve() {
        final p = proposal(id);
        return service.owner.performProposalDecision(
          OwnerProposalCommand(
            operationId: 'file-decision',
            proposalId: id,
            kind: ProposalKind.addition,
            confirm: true,
            version: p.version,
            reviewToken: 'b' * 64,
            commandDigest: 'c' * 64,
          ),
          validate: () {
            if (proposal(id).version != p.version)
              throw const AccessFailure('proposal_changed');
          },
          decide: () async {
            await service.owner.confirmImport(id, p.version, p.items);
          },
        );
      }

      sql(
        "CREATE TRIGGER fail_file_receipt BEFORE INSERT ON owner_proposal_operations WHEN NEW.operation_id='file-decision' BEGIN SELECT RAISE(ABORT,'synthetic'); END",
      );
      await expectLater(approve(), throwsA(isA<StorageFailure>()));
      expect(repo.items, isEmpty);
      expect((await repo.informationAttachmentUsage()).availableVersions, 0);
      expect((await repo.importFileUpload(first.id))!.consumed, false);
      await close();
      await open();
      sql('DROP TRIGGER fail_file_receipt');
      await approve();
      expect(repo.items.length, 2);
      expect((await repo.informationFileStagingUsage()).files, 0);
      final resume = repo.items.singleWhere((i) => i.name == 'resume');
      expect(resume.fields.single.attachment!.attachmentVersion, 2);
      final versions = await repo.informationAttachmentVersions(
        resume.fields.single.attachment!.attachmentId,
      );
      expect(versions.length, 2);
      expect(versions.first.label, '来源版本1');
      expect(
        (await service.owner.readInformationAttachment(
          versions.first.reference,
        )).bytes,
        utf8.encode('PRIVATE-ORIGINAL-A'),
      );
      expect((await repo.importFileUpload(first.id))!.consumed, true);
      expect(proposal(id).items, isEmpty);
      now = now.add(const Duration(days: 800));
      await service.owner.purgeInformationAttachments();
      final key = await enableTestBackups(repo.backups);
      final path = '${root.path}/complete.aim';
      await repo.backups.exportTo(path);
      final restored = await EncryptedInformationRepository.open(
        '${root.path}/restored',
        TestKeyStore(),
        clock: () => now,
      );
      try {
        final backup = await restored.backups.inspect(path, key);
        expect(backup.formatVersion, 18);
        await restored.backups.restore(backup);
        final history = await restored.informationAttachmentVersions(
          versions.first.reference.attachmentId,
        );
        expect(
          history.map((v) => v.sourceNote),
          versions.map((v) => v.sourceNote),
        );
        expect(
          await restored.readInformationAttachmentChunk(
            versions.first.reference,
            0,
            versions.first.byteLength,
          ),
          utf8.encode('PRIVATE-ORIGINAL-A'),
        );
      } finally {
        await restored.close();
      }
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        final text = latin1.decode(encryptedArtifactBytes(file));
        expect(text, isNot(contains('PRIVATE-ORIGINAL-A')));
        expect(
          text,
          isNot(contains(base64Encode(utf8.encode('PRIVATE-ORIGINAL-A')))),
        );
      }
    },
  );
}
