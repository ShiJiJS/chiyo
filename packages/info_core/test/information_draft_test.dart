import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

Matcher fails(String code) =>
    throwsA(isA<AccessFailure>().having((e) => e.status, 'status', code));
void main() {
  late Directory root;
  late MemoryInformationRepository repo;
  late InformationService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('formal-owner-draft-');
    repo = MemoryInformationRepository();
    service = InformationService(repository: repo);
  });
  tearDown(() async {
    await service.close();
    await root.delete(recursive: true);
  });
  Future<InformationFileStage> stage(
    InformationFileDraft draft,
    List<int> bytes,
  ) async {
    final file = File('${root.path}/fictional.pdf');
    await file.writeAsBytes(bytes);
    return service.owner.stageInformationFile(
      draft,
      file.path,
      mediaType: 'application/pdf',
    );
  }

  InformationDraftInput input(
    List<InformationDraftField> fields, [
    InformationItem? before,
  ]) => InformationDraftInput(
    name: '求职资料',
    description: '',
    fields: fields,
    itemId: before?.id,
    baseVersion: before?.version,
  );
  Future<InformationItem> create() async {
    final d = await service.owner.beginInformationFileDraft();
    final s = await stage(d, [0, 255, 7]);
    final item = await service.owner.commitInformationDraft(
      d,
      'create',
      input([
        const InformationDraftField.text('姓名', '', '虚构姓名'),
        InformationDraftField.stagedFile('简历', '', s.id),
      ]),
    );
    await service.owner.releaseInformationFileDraft(d);
    return item;
  }

  test(
    'owner usage accounts for retained originals and uncommitted stages in the same byte budget',
    () async {
      final first = await create();
      final draft = await service.owner.beginInformationFileDraft();
      final replacement = await stage(draft, [9, 8]);
      var usage = await service.owner.informationAttachmentUsage();
      expect(usage.versionRecords, 1);
      expect(usage.availableVersions, 1);
      expect(usage.stagedFiles, 1);
      expect(usage.storedBytes, 3);
      expect(usage.originalAndStagedBytes, 5);
      final saved = await service.owner.commitInformationDraft(
        draft,
        'replace-for-usage',
        input([
          InformationDraftField.stagedFile(
            '简历',
            '',
            replacement.id,
            fieldId: first.fields.last.id,
          ),
        ], first),
      );
      usage = await service.owner.informationAttachmentUsage();
      expect(usage.availableVersions, 2);
      expect(usage.versionRecords, 2);
      expect(usage.stagedFiles, 0);
      expect(usage.storedBytes, 5);
      final cancelled = await service.owner.beginInformationFileDraft();
      await stage(cancelled, [1, 2, 3, 4]);
      expect(
        (await service.owner.informationAttachmentUsage())
            .originalAndStagedBytes,
        9,
      );
      await service.owner.releaseInformationFileDraft(cancelled);
      await service.owner.releaseInformationFileDraft(draft);
      await service.owner.deleteInformation(saved.id, saved.version);
      usage = await service.owner.informationAttachmentUsage();
      expect(
        usage.storedBytes,
        5,
        reason: 'recycle and revision originals remain retained after deletion',
      );
      expect(usage.stagedBytes, 0);
    },
  );

  test(
    'mixed save consumes stages once, retries after form close and rejects operation reuse',
    () async {
      final d = await service.owner.beginInformationFileDraft();
      final s = await stage(d, [0, 255, 1]);
      final form = input([InformationDraftField.stagedFile('简历', '', s.id)]);
      final first = await service.owner.commitInformationDraft(d, 'op', form);
      await service.owner.releaseInformationFileDraft(d);
      expect(
        (await service.owner.commitInformationDraft(d, 'op', form)).id,
        first.id,
      );
      expect(repo.items.length, 1);
      expect(repo.informationRevisions, isEmpty);
      expect((await repo.informationFileStagingUsage()).files, 0);
      final ref = first.fields.single.attachment!;
      expect(await repo.readInformationAttachmentChunk(ref, 0, 3), [0, 255, 1]);
      await expectLater(
        service.owner.commitInformationDraft(
          d,
          'op',
          input([const InformationDraftField.text('名字', '', '不同内容')]),
        ),
        fails('operation_conflict'),
      );
      expect(service.agent.catalog().toString(), isNot(contains(s.sha256)));
      expect(
        service.agent.catalog().toString(),
        isNot(contains('fictional.pdf')),
      );
    },
  );
  test(
    'text-only edit and retained file metadata preserve exact attachment and identity',
    () async {
      final old = await create();
      final d = await service.owner.beginInformationFileDraft();
      final saved = await service.owner.commitInformationDraft(
        d,
        'edit',
        input([
          InformationDraftField.text(
            '姓名',
            '',
            '新姓名',
            fieldId: old.fields.first.id,
          ),
          InformationDraftField.retainedFile(
            '简历',
            '公开说明',
            old.fields.last.attachment,
            fieldId: old.fields.last.id,
          ),
        ], old),
      );
      expect(saved.fields.last.id, old.fields.last.id);
      expect(saved.fields.last.version, 2);
      expect(saved.fields.last.attachment, old.fields.last.attachment);
      expect(
        repo.informationRevisions.single.item.fields.last.attachment,
        old.fields.last.attachment,
      );
      expect(
        (await service.owner.informationAttachmentVersions(
          old.fields.last.attachment!.attachmentId,
        )).length,
        1,
      );
    },
  );
  test(
    'same-purpose replacement keeps field identity and creates immutable original version',
    () async {
      final old = await create();
      final d = await service.owner.beginInformationFileDraft();
      final s = await stage(d, [9, 8]);
      final saved = await service.owner.commitInformationDraft(
        d,
        'replace',
        input([
          InformationDraftField.stagedFile(
            '简历',
            '',
            s.id,
            fieldId: old.fields.last.id,
          ),
        ], old),
      );
      final a = old.fields.last.attachment!,
          b = saved.fields.single.attachment!;
      expect(saved.fields.single.id, old.fields.last.id);
      expect(saved.fields.single.version, 2);
      expect(a.attachmentId, isNot(b.attachmentId));
      final family = await repo.informationAttachmentVersions(b.attachmentId);
      expect(family.map((v) => v.reference), containsAll([a, b]));
      expect(family.map((v) => v.seriesId).toSet(), {a.attachmentId});
      expect(b.attachmentVersion, 2);
      expect(await repo.readInformationAttachmentChunk(a, 0, 3), [0, 255, 7]);
      expect(await repo.readInformationAttachmentChunk(b, 0, 2), [9, 8]);
    },
  );
  test(
    'meaning or kind changes use new identity and create recoverable deletion facts',
    () async {
      final old = await create();
      final d = await service.owner.beginInformationFileDraft();
      final saved = await service.owner.commitInformationDraft(
        d,
        'change',
        input([
          InformationDraftField.text(
            '简历说明',
            '',
            '文本',
            fieldId: old.fields.last.id,
          ),
        ], old),
      );
      expect(saved.fields.single.id, isNot(old.fields.last.id));
      expect(saved.fields.single.kind, FieldKind.structured);
      expect(
        repo.recycleEntries.single.snapshot!.fields.map((f) => f.id),
        contains(old.fields.last.id),
      );
    },
  );
  test(
    'stale forms, foreign stages and borrowed references cannot alter saved content',
    () async {
      final old = await create();
      final d = await service.owner.beginInformationFileDraft();
      final other = await service.owner.beginInformationFileDraft();
      final s = await stage(other, [5]);
      await expectLater(
        service.owner.commitInformationDraft(
          d,
          'foreign',
          input([
            InformationDraftField.stagedFile(
              '简历',
              '',
              s.id,
              fieldId: old.fields.last.id,
            ),
          ], old),
        ),
        fails('stage_unavailable'),
      );
      await expectLater(
        service.owner.commitInformationDraft(
          d,
          'borrow',
          input([
            InformationDraftField.retainedFile(
              '简历',
              '',
              InformationAttachmentRef('absent', 1),
              fieldId: old.fields.last.id,
            ),
          ], old),
        ),
        fails('stage_unavailable'),
      );
      await service.owner.correctValue(
        FieldRef(old.id, old.fields.first.id),
        '修正姓名',
      );
      await expectLater(
        service.owner.commitInformationDraft(
          d,
          'stale',
          input([
            InformationDraftField.retainedFile(
              '简历',
              '',
              old.fields.last.attachment,
              fieldId: old.fields.last.id,
            ),
          ], old),
        ),
        fails('version_conflict'),
      );
      expect((await repo.informationFileStagingUsage()).files, 1);
      expect(repo.items.single.fields.first.value, '修正姓名');
    },
  );
  test(
    'restore invalidates both completed receipts and uncommitted form handles',
    () async {
      final d = await service.owner.beginInformationFileDraft();
      final s = await stage(d, []);
      final form = input([InformationDraftField.stagedFile('空文件', '', s.id)]);
      await service.owner.commitInformationDraft(d, 'op', form);
      await service.owner.restoreLibrary(() async {});
      await expectLater(
        service.owner.commitInformationDraft(d, 'op', form),
        fails('stage_unavailable'),
      );
    },
  );
}
