import 'dart:convert';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'fixtures/file_import_fixture.dart';

void main() {
  late MemoryInformationRepository repo;
  late InformationService service;
  late String session;
  late InformationItem item;
  var now = DateTime.utc(2026, 11, 3);
  Future<InformationImportUpload> upload(String op) =>
      service.agent.uploadImportFile(
        session,
        operationId: op,
        originalName: '$op.txt',
        mediaType: 'text/plain',
        bytes: Uint8List.fromList(utf8.encode('PRIVATE-$op')),
      );
  UpdateProposal proposal(String id) =>
      repo.updateProposals.singleWhere((p) => p.id == id);
  setUp(() async {
    now = DateTime.utc(2026, 11, 3);
    repo = MemoryInformationRepository();
    service = InformationService(repository: repo, clock: () => now);
    configureFileImports(service);
    session = service.agent.openSession('合成文件修改');
    final initial = await service.agent.submitImport(session, [
      fileInput('resume', [await upload('current'), await upload('history')]),
    ]);
    final p = repo.importProposals.single;
    await service.owner.confirmImport(initial, p.version, p.items);
    item = repo.items.single;
  });
  tearDown(() => service.close());
  ImportAttachmentInput change(
    InformationImportUpload file, {
    int? current = 1,
  }) => ImportAttachmentInput(
    key: 'revision',
    name: '简历原文',
    fieldId: item.fields.single.id,
    versions: [
      ImportAttachmentVersionInput(
        file.id,
        label: '来源修订',
        sourceNote: '源文件给出的修订说明。',
      ),
    ],
    currentVersion: current,
  );

  test(
    'new unbound copies are rejected without changing existing files',
    () async {
      final file = await upload('unbound-copy');
      await expectLater(
        service.agent.submitUpdate(
          session,
          UpdateInput(
            item.id,
            item.version,
            [],
            attachments: [
              ImportAttachmentInput(
                key: 'copy',
                name: '多余来源',
                versions: [ImportAttachmentVersionInput(file.id)],
                currentVersion: 1,
              ),
            ],
          ),
        ),
        throwsA(isA<InformationTemplateInputFailure>()),
      );
      expect(repo.items.single, same(item));
      expect(repo.updateProposals, isEmpty);
      expect((await repo.importFileUpload(file.id))!.consumed, false);
    },
  );

  test(
    'explicit attachment revisions append after latest stored version and operations retry once',
    () async {
      final file = await upload('revision');
      final input = UpdateInput(
        item.id,
        item.version,
        [],
        attachments: [change(file)],
      );
      final id = await service.agent.submitUpdate(
        session,
        input,
        operationId: 'revise-once',
      );
      expect(
        await service.agent.submitUpdate(
          session,
          input,
          operationId: 'revise-once',
        ),
        id,
      );
      expect(repo.items.single, same(item));
      expect(
        (await repo.informationAttachmentVersions(
          item.fields.single.attachment!.attachmentId,
        )).length,
        2,
      );
      final preview = service.owner.previewUpdate(id);
      expect(preview.after.fields.first.id, item.fields.single.id);
      expect(preview.after.fields.first.attachment!.attachmentVersion, 3);
      expect(preview.after.fields.length, 1);
      expect(
        jsonEncode(
          service.agent.updateStatusByOperation(session, 'revise-once'),
        ),
        isNot(contains('PRIVATE-')),
      );
      await service.owner.confirmUpdate(id, proposal(id).version);
      final after = repo.items.single;
      expect(after.version, item.version + 1);
      expect(after.fields.first.attachment!.attachmentVersion, 3);
      expect(
        (await service.owner.readInformationAttachment(
          after.fields.first.attachment!,
        )).bytes,
        utf8.encode('PRIVATE-revision'),
      );
      expect(
        (await service.owner.readInformationAttachment(
          item.fields.single.attachment!,
        )).bytes,
        utf8.encode('PRIVATE-current'),
      );
      expect((await repo.informationFileStagingUsage()).files, 0);
      expect(
        await service.agent.submitUpdate(
          session,
          input,
          operationId: 'revise-once',
        ),
        id,
      );
      final other = service.agent.openSession('其他会话');
      expect(
        service.agent.updateStatusByOperation(other, 'revise-once')['status'],
        'not_found',
      );
    },
  );

  test(
    'explicitly historical originals keep the current choice; rejected revisions discard unapproved bodies',
    () async {
      final id = await service.agent.submitUpdate(
        session,
        UpdateInput(
          item.id,
          item.version,
          [],
          attachments: [change(await upload('older'), current: null)],
        ),
      );
      await service.owner.confirmUpdate(id, proposal(id).version);
      expect(
        repo.items.single.fields.single.attachment,
        item.fields.single.attachment,
      );
      expect(
        (await repo.informationAttachmentVersions(
          item.fields.single.attachment!.attachmentId,
        )).length,
        3,
      );
      item = repo.items.single;
      final rejected = await upload('reject');
      final reject = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, item.version, [], attachments: [change(rejected)]),
      );
      await service.owner.rejectUpdate(reject, proposal(reject).version);
      expect((await repo.importFileUpload(rejected.id))!.consumed, true);
      expect(
        repo.items.single.fields.single.attachment,
        item.fields.single.attachment,
      );
      expect(
        jsonEncode(proposal(reject).toJson()),
        isNot(contains(rejected.id)),
      );
    },
  );

  test(
    'full template updates explicitly retain existing originals, without silently omitting or clearing them',
    () async {
      UpdateInput edit(Object? value) => UpdateInput(
        item.id,
        item.version,
        [],
        name: '确认后的材料',
        templateId: 'file',
        templateVersion: '1',
        templateDigest: 'a' * 64,
        values: value == null ? {} : {'file': value},
      );
      for (final v in [null, '', 'invented']) {
        await expectLater(
          service.agent.submitUpdate(session, edit(v)),
          throwsA(isA<InformationTemplateInputFailure>()),
        );
      }
      final id = await service.agent.submitUpdate(
        session,
        edit({'retain': true}),
      );
      expect(
        service.owner.previewUpdate(id).after.fields.single.attachment,
        item.fields.single.attachment,
      );
      await service.owner.confirmUpdate(id, proposal(id).version);
      expect(repo.items.single.name, '确认后的材料');
      expect(repo.items.single.fields.single.id, item.fields.single.id);
      expect(
        repo.items.single.fields.single.attachment,
        item.fields.single.attachment,
      );
    },
  );

  test(
    'approved file revisions wait for referenced information and survive abandoned-upload cleanup',
    () async {
      final reference = await service.agent.submitImport(session, [
        fileInput('proof', [await upload('related')]),
      ]);
      final id = await service.agent.submitUpdate(
        session,
        UpdateInput(
          item.id,
          item.version,
          [],
          templateId: 'file',
          templateVersion: '1',
          templateDigest: 'a' * 64,
          values: {
            'file': {'retain': true},
          },
          pendingRelations: {
            'related': [
              ImportPendingReference(
                'information',
                'proof',
                proposalId: reference,
              ),
            ],
          },
          attachments: [change(await upload('waiting'))],
        ),
      );
      expect(
        await service.owner.confirmUpdate(id, proposal(id).version),
        isNull,
      );
      expect(
        service.agent.updateStatus(session, id)['status'],
        'approved_awaiting_admission',
      );
      expect(repo.items.single, same(item));
      now = now.add(const Duration(hours: 1));
      await upload('cleanup-trigger');
      final p = repo.importProposals.singleWhere((p) => p.id == reference);
      await service.owner.confirmImport(reference, p.version, p.items);
      expect(service.agent.updateStatus(session, id)['status'], 'confirmed');
      final saved = repo.items.singleWhere((i) => i.id == item.id);
      expect(
        (await service.owner.readInformationAttachment(
          saved.fields.single.attachment!,
        )).bytes,
        utf8.encode('PRIVATE-waiting'),
      );
      expect(saved.layout!.relations['related']!.single.id, isNotEmpty);
    },
  );
  test(
    'a later Owner edit makes the pending file revision conflict without replacing current data',
    () async {
      final file = await upload('stale');
      final id = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, item.version, [], attachments: [change(file)]),
      );
      await service.owner.editInformation(
        item.id,
        item.version,
        name: '主人后来修改的名称',
        description: item.description,
      );
      await expectLater(
        service.owner.confirmUpdate(id, proposal(id).version),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.agent.updateStatus(session, id)['status'], 'conflicted');
      expect(repo.items.single.name, '主人后来修改的名称');
      expect(
        repo.items.single.fields.single.attachment,
        item.fields.single.attachment,
      );
      expect((await repo.importFileUpload(file.id))!.consumed, true);
    },
  );
  test(
    'full staging capacity is explicit and does not delete retained originals to accept new files',
    () async {
      final bytes = Uint8List(informationFileByteLimit);
      for (var n = 0; n < 9; n++) {
        await service.agent.uploadImportFile(
          session,
          operationId: 'quota-$n',
          originalName: 'quota-$n.bin',
          mediaType: 'application/octet-stream',
          bytes: bytes,
        );
      }
      await expectLater(
        service.agent.uploadImportFile(
          session,
          operationId: 'over-quota',
          originalName: 'overflow.bin',
          mediaType: 'application/octet-stream',
          bytes: bytes,
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'attachment_capacity_exceeded',
          ),
        ),
      );
      expect(repo.items.single, same(item));
      expect(
        (await repo.informationAttachmentVersions(
          item.fields.single.attachment!.attachmentId,
        )).length,
        2,
      );
      expect(
        (await service.owner.readInformationAttachment(
          item.fields.single.attachment!,
        )).bytes,
        utf8.encode('PRIVATE-current'),
      );
    },
  );
}
