import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import '../../info_core/test/fixtures/file_import_fixture.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'a pending revision survives reopen, receipt failure rolls back everything, and retry preserves history and source labels',
    () async {
      final root = await Directory.systemTemp.createTemp('file-update-sql-');
      final keys = TestKeyStore();
      late EncryptedInformationRepository repo;
      late InformationService service;
      Future<void> open() async {
        repo = await EncryptedInformationRepository.open(root.path, keys);
        service = InformationService(repository: repo);
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
      var session = service.agent.openSession('合成修改');
      Future<InformationImportUpload> upload(String op) =>
          service.agent.uploadImportFile(
            session,
            operationId: op,
            originalName: '$op.txt',
            mediaType: 'text/plain',
            bytes: Uint8List.fromList(utf8.encode('PRIVATE-$op')),
          );
      final initial = await service.agent.submitImport(session, [
        fileInput('resume', [await upload('current'), await upload('history')]),
      ]);
      final p = repo.importProposals.single;
      await service.owner.confirmImport(initial, p.version, p.items);
      final item = repo.items.single, old = repo.items.single.fields.single;
      final revision = await upload('revision');
      final input = UpdateInput(
        item.id,
        item.version,
        [],
        name: '核对后的材料',
        attachments: [
          ImportAttachmentInput(
            key: 'primary',
            name: '原文',
            fieldId: old.id,
            currentVersion: 1,
            versions: [
              ImportAttachmentVersionInput(
                revision.id,
                label: '投递确认稿',
                sourceNote: '来源说明明确为确认稿。',
              ),
            ],
          ),
        ],
      );
      final id = await service.agent.submitUpdate(
        session,
        input,
        operationId: 'file-update-once',
      );
      final expected = jsonEncode(repo.updateProposals.single.input.toJson());
      await close();
      await open();
      expect(jsonEncode(repo.updateProposals.single.input.toJson()), expected);
      expect(repo.items.single.version, 1);
      int sql(String statement) {
        final db = sqlite3.open('${root.path}/library.db');
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

      expect(sql('PRAGMA user_version'), 48);
      final decisionVersion = repo.updateProposals.single.version;
      Future<OwnerProposalReceipt> approve() {
        final update = repo.updateProposals.single;
        return service.owner.performProposalDecision(
          OwnerProposalCommand(
            operationId: 'update-decision',
            proposalId: id,
            kind: ProposalKind.modification,
            confirm: true,
            version: decisionVersion,
            reviewToken: 'b' * 64,
            commandDigest: 'c' * 64,
          ),
          validate: () {},
          decide: () async {
            await service.owner.confirmUpdate(id, update.version);
          },
        );
      }

      sql(
        "CREATE TRIGGER fail_update_original_receipt BEFORE INSERT ON owner_proposal_operations WHEN NEW.operation_id='update-decision' BEGIN SELECT RAISE(ABORT,'synthetic'); END",
      );
      await expectLater(approve(), throwsA(isA<StorageFailure>()));
      expect(repo.items.single.version, 1);
      expect(repo.items.single.fields.single.attachment, old.attachment);
      expect(
        (await repo.informationAttachmentVersions(
          old.attachment!.attachmentId,
        )).length,
        2,
      );
      expect((await repo.importFileUpload(revision.id))!.consumed, false);
      await close();
      await open();
      sql('DROP TRIGGER fail_update_original_receipt');
      await approve();
      await approve();
      expect(repo.items.single.version, 2);
      expect(repo.items.single.fields.length, 1);
      expect(repo.items.single.fields.first.attachment!.attachmentVersion, 3);
      expect(repo.updateProposals.single.input.attachments, isEmpty);
      expect((await repo.importFileUpload(revision.id))!.consumed, true);
      expect((await repo.informationFileStagingUsage()).files, 0);
      await close();
      await open();
      final current = repo.items.single;
      expect(
        (await service.owner.readInformationAttachment(
          current.fields.first.attachment!,
        )).bytes,
        utf8.encode('PRIVATE-revision'),
      );
      final history = await repo.informationAttachmentVersions(
        old.attachment!.attachmentId,
      );
      expect(history.length, 3);
      expect(history.last.label, '投递确认稿');
      expect(
        (await service.owner.readInformationAttachment(old.attachment!)).bytes,
        utf8.encode('PRIVATE-current'),
      );
      expect(
        (await service.owner.readInformationAttachment(
          history[1].reference,
        )).bytes,
        utf8.encode('PRIVATE-history'),
      );
      final raw = await File('${root.path}/library.db').readAsBytes();
      expect(
        utf8.decode(raw, allowMalformed: true),
        isNot(contains('PRIVATE-revision')),
      );
      expect(
        utf8.decode(raw, allowMalformed: true),
        isNot(contains(base64Encode(utf8.encode('PRIVATE-revision')))),
      );
    },
  );
}
