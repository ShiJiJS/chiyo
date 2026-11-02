import 'dart:convert';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'fixtures/file_import_fixture.dart';

void main() {
  late MemoryInformationRepository repo;
  late InformationService service;
  late String session;
  var now = DateTime.utc(2026, 11, 3);
  setUp(() {
    now = DateTime.utc(2026, 11, 3);
    repo = MemoryInformationRepository();
    service = InformationService(repository: repo, clock: () => now);
    configureFileImports(service);
    session = service.agent.openSession('合成文件录入');
  });
  tearDown(() => service.close());
  Future<InformationImportUpload> upload(String operation, String contents) =>
      service.agent.uploadImportFile(
        session,
        operationId: operation,
        originalName: '$operation.txt',
        mediaType: 'text/plain',
        bytes: Uint8List.fromList(utf8.encode(contents)),
      );
  ImportProposal proposal(String id) =>
      repo.importProposals.singleWhere((p) => p.id == id);
  test(
    'multiple originals form one independently authorized attachment with explicit current choice; extras remain independent',
    () async {
      final first = await upload('original', 'PRIVATE-ORIGINAL'),
          second = await upload('revision', 'PRIVATE-REVISION'),
          proof = await upload('proof', 'PRIVATE-PROOF');
      final id = await service.agent.submitImport(session, [
        fileInput(
          'resume',
          [first, second],
          extra: [
            ImportAttachmentInput(
              key: 'proof',
              name: '相关证明',
              versions: [ImportAttachmentVersionInput(proof.id)],
              currentVersion: 1,
            ),
          ],
        ),
      ], operationId: 'file-intake');
      expect(repo.items, isEmpty);
      expect((await repo.informationFileStagingUsage()).files, 3);
      expect(
        jsonEncode(service.agent.importStatus(session, id)),
        isNot(contains('PRIVATE-')),
      );
      final preview = await service.owner.readImportOriginal(
        id,
        'resume',
        'primary',
        2,
      );
      expect(preview.bytes, utf8.encode('PRIVATE-REVISION'));
      await service.owner.confirmImport(
        id,
        proposal(id).version,
        proposal(id).items,
      );
      final item = repo.items.single;
      expect(item.fields.length, 2);
      expect(item.fields.every((f) => f.kind == FieldKind.file), true);
      final primary = item.fields.first;
      expect(primary.attachment!.attachmentVersion, 1);
      expect(item.layout!.fieldIds[jsonEncode(['field', 'file'])], primary.id);
      final versions = await repo.informationAttachmentVersions(
        primary.attachment!.attachmentId,
      );
      expect(versions.length, 2);
      expect(versions.last.label, '来源版本2');
      expect(
        (await service.owner.readInformationAttachment(
          primary.attachment!,
        )).bytes,
        utf8.encode('PRIVATE-ORIGINAL'),
      );
      expect(
        (await service.owner.readInformationAttachment(
          versions.last.reference,
        )).bytes,
        utf8.encode('PRIVATE-REVISION'),
      );
      expect(primary.id, isNot(item.fields.last.id));
      expect((await repo.informationFileStagingUsage()).files, 0);
      expect((await repo.importFileUpload(first.id))!.consumed, true);
      expect(proposal(id).items, isEmpty);
    },
  );
  test(
    'approval waits for related files and a complete cycle releases all originals together',
    () async {
      final a = await upload('a', 'PRIVATE-A'),
          b = await upload('b', 'PRIVATE-B');
      final id = await service.agent.submitImport(session, [
        fileInput(
          'a',
          [a],
          pending: [ImportPendingReference('information', 'b')],
        ),
        fileInput(
          'b',
          [b],
          pending: [ImportPendingReference('information', 'a')],
        ),
      ]);
      await service.owner.confirmImport(id, proposal(id).version, [
        proposal(id).items.first,
      ]);
      expect(repo.items, isEmpty);
      expect((await repo.informationAttachmentUsage()).availableVersions, 0);
      expect((await repo.informationFileStagingUsage()).files, 2);
      await service.owner.confirmImport(id, proposal(id).version, [
        proposal(id).items.last,
      ]);
      expect(repo.items.length, 2);
      expect((await repo.informationFileStagingUsage()).files, 0);
      expect(proposal(id).items, isEmpty);
    },
  );
  test(
    'uploads retry by operation, remain private to their session, and rejected proposal originals are removed',
    () async {
      final file = await upload('retry', 'PRIVATE-RETRY');
      expect((await upload('retry', 'PRIVATE-RETRY')).id, file.id);
      await expectLater(
        upload('retry', 'PRIVATE-CHANGED'),
        throwsA(isA<AccessFailure>()),
      );
      final other = service.agent.openSession('其他会话');
      expect(
        (await service.agent.importFileStatus(other, 'retry'))['status'],
        'not_found',
      );
      await expectLater(
        service.agent.submitImport(other, [
          fileInput('other', [file]),
        ]),
        throwsA(isA<AccessFailure>()),
      );
      final id = await service.agent.submitImport(session, [
        fileInput('mine', [file]),
      ]);
      await service.owner.rejectImport(id, proposal(id).version);
      expect(repo.items, isEmpty);
      expect((await repo.importFileUpload(file.id))!.consumed, true);
      await expectLater(
        repo.withImportFile(file.id, (_, _) async => true),
        throwsA(isA<AccessFailure>()),
      );
      expect(jsonEncode(proposal(id).toJson()), isNot(contains(file.id)));
    },
  );
  test(
    'pending originals survive upload expiry while unclaimed originals can be reclaimed',
    () async {
      final owned = await upload('owned', 'PRIVATE-PENDING'),
          abandoned = await upload('abandoned', 'PRIVATE-ABANDONED');
      final id = await service.agent.submitImport(session, [
        fileInput('owned', [owned]),
      ]);
      now = now.add(const Duration(hours: 2));
      await upload('new', 'PRIVATE-NEW');
      expect(await repo.importFileUpload(abandoned.id), isNull);
      expect(
        (await service.owner.readImportOriginal(
          id,
          'owned',
          'primary',
          1,
        )).bytes,
        utf8.encode('PRIVATE-PENDING'),
      );
      expect(repo.items, isEmpty);
    },
  );
}
