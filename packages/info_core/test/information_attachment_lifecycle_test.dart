import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class _Repository extends MemoryInformationRepository {
  String? fault;
  Future<void> Function()? after;
  @override
  Future<T> withInformationAttachment<T>(
    InformationAttachmentRef ref,
    Future<T> Function(InformationAttachmentVersion, Stream<Uint8List>) action,
  ) => super.withInformationAttachment(ref, (v, chunks) async {
    final supplied = switch (fault) {
      'short' => Stream.value(Uint8List.fromList([0])),
      'digest' => Stream.value(Uint8List.fromList([2, 1, 0])),
      'io' => Stream<Uint8List>.error(StateError('synthetic read failed')),
      _ => chunks,
    };
    final result = await action(v, supplied);
    if (after != null) {
      await after!();
    }
    if (fault == 'source-close') {
      throw StateError('synthetic transaction failed');
    }
    return result;
  });
}

Matcher fails(String value) =>
    throwsA(isA<AccessFailure>().having((e) => e.status, 'status', value));
void main() {
  late Directory root;
  late _Repository repo;
  late InformationService service;
  late DateTime now;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('attachment-owner-lifecycle-');
    repo = _Repository();
    now = DateTime.utc(2026, 10, 1);
    service = InformationService(repository: repo, clock: () => now);
  });
  tearDown(() async {
    await service.close();
    await root.delete(recursive: true);
  });
  Future<InformationItem> save(
    List<int> bytes, [
    InformationItem? before,
  ]) async {
    final source = File('${root.path}/fictional.pdf');
    await source.writeAsBytes(bytes);
    final draft = await service.owner.beginInformationFileDraft();
    final stage = await service.owner.stageInformationFile(draft, source.path);
    final result = await service.owner.commitInformationDraft(
      draft,
      'save',
      InformationDraftInput(
        name: '求职资料',
        description: '',
        itemId: before?.id,
        baseVersion: before?.version,
        fields: [
          InformationDraftField.stagedFile(
            '简历',
            '',
            stage.id,
            fieldId: before?.fields.single.id,
          ),
        ],
      ),
    );
    await service.owner.releaseInformationFileDraft(draft);
    return result;
  }

  bool noPartials() => !root.listSync().whereType<Directory>().any(
    (d) => d.uri.pathSegments.any((s) => s.startsWith('.info-file-export-')),
  );
  test(
    'replacement retires old original, keeps snapshots pinned and purges exactly at cutoff',
    () async {
      final old = await save([0, 255, 1]);
      final saved = await save([9, 8], old);
      final oldRef = old.fields.single.attachment!;
      expect(
        (await repo.informationAttachmentVersions(
          oldRef.attachmentId,
        )).first.retiredAt,
        now,
      );
      now = now.add(const Duration(days: 30));
      await repo.reconcileInformationAttachments(now);
      expect(await repo.readInformationAttachmentChunk(oldRef, 0, 3), [
        0,
        255,
        1,
      ], reason: 'unpruned snapshot still pins original');
      await service.owner.purgeInformationAttachments();
      expect(
        (await repo.informationAttachmentVersions(
          oldRef.attachmentId,
        )).first.available,
        isFalse,
      );
      now = now.subtract(const Duration(days: 2));
      await expectLater(
        service.owner.exportInformationFile(oldRef, '${root.path}/old.pdf'),
        fails('attachment_missing'),
      );
      now = now.add(const Duration(days: 365));
      await service.owner.purgeInformationAttachments();
      expect(
        await repo.readInformationAttachmentChunk(
          saved.fields.single.attachment!,
          0,
          2,
        ),
        [9, 8],
      );
      expect(
        (await repo.informationAttachmentVersions(
          oldRef.attachmentId,
        )).last.retiredAt,
        isNull,
      );
    },
  );
  test(
    'recycle restore gives new field identity, reactivates original and pins it beyond age thirty',
    () async {
      final old = await save([0, 255, 1]);
      final entry = await service.owner.deleteInformation(old.id, old.version);
      now = now.add(const Duration(days: 29));
      final restored = await service.owner.restoreRecycled(entry.id);
      expect(restored.fields.single.id, isNot(old.fields.single.id));
      expect(restored.fields.single.attachment, old.fields.single.attachment);
      now = now.add(const Duration(days: 365));
      await service.owner.purgeInformationAttachments();
      final v = (await repo.informationAttachmentVersions(
        old.fields.single.attachment!.attachmentId,
      )).single;
      expect(v.available, isTrue);
      expect(v.retiredAt, isNull);
    },
  );
  test(
    'revision restore reactivates selected original and retires the replaced one',
    () async {
      final first = await save([0, 255, 1]);
      final second = await save([8, 7], first);
      now = now.add(const Duration(days: 20));
      await service.owner.restoreRevision(
        first.id,
        first.version,
        second.version,
      );
      final versions = await repo.informationAttachmentVersions(
        first.fields.single.attachment!.attachmentId,
      );
      expect(versions.first.retiredAt, isNull);
      expect(versions.last.retiredAt, now);
      now = now.add(const Duration(days: 30));
      await service.owner.purgeInformationAttachments();
      expect(
        await repo.readInformationAttachmentChunk(
          first.fields.single.attachment!,
          0,
          3,
        ),
        [0, 255, 1],
      );
      await expectLater(
        repo.readInformationAttachmentChunk(
          second.fields.single.attachment!,
          0,
          2,
        ),
        fails('attachment_missing'),
      );
    },
  );
  test(
    'Save As exports exact current, retained and empty originals and never overwrites',
    () async {
      final first = await save([0, 255, 1]);
      await save([], first);
      final oldPath = '${root.path}/old.pdf',
          emptyPath = '${root.path}/empty.pdf';
      await service.owner.exportInformationFile(
        first.fields.single.attachment!,
        oldPath,
      );
      await service.owner.exportInformationFile(
        repo.items.single.fields.single.attachment!,
        emptyPath,
      );
      expect(await File(oldPath).readAsBytes(), [0, 255, 1]);
      expect(await File(emptyPath).length(), 0);
      await expectLater(
        service.owner.exportInformationFile(
          repo.items.single.fields.single.attachment!,
          oldPath,
        ),
        fails('output_exists'),
      );
      expect(await File(oldPath).readAsBytes(), [0, 255, 1]);
      expect(noPartials(), isTrue);
    },
    skip: !Platform.isWindows,
  );
  for (final fault in ['short', 'digest', 'io', 'source-close']) {
    test(
      'Save As $fault failure publishes no file and clears its own partial',
      () async {
        final item = await save([0, 255, 1]);
        repo.fault = fault;
        final path = '${root.path}/export.pdf';
        await expectLater(
          service.owner.exportInformationFile(
            item.fields.single.attachment!,
            path,
          ),
          fails(
            {'short', 'digest'}.contains(fault)
                ? 'attachment_integrity_failed'
                : 'file_export_failed',
          ),
        );
        expect(await File(path).exists(), isFalse);
        expect(noPartials(), isTrue);
        expect(
          await repo.readInformationAttachmentChunk(
            item.fields.single.attachment!,
            0,
            3,
          ),
          [0, 255, 1],
        );
      },
      skip: !Platform.isWindows,
    );
  }
  test(
    'Save As late destination race preserves new target and removes only our partial',
    () async {
      final item = await save([0, 255, 1]);
      final path = '${root.path}/export.pdf';
      repo.after = () async {
        await File(path).writeAsString('other owner file');
      };
      await expectLater(
        service.owner.exportInformationFile(
          item.fields.single.attachment!,
          path,
        ),
        fails('output_exists'),
      );
      expect(await File(path).readAsString(), 'other owner file');
      expect(noPartials(), isTrue);
    },
    skip: !Platform.isWindows,
  );
  test(
    'Save As shutdown before publication leaves no output or partial',
    () async {
      final item = await save([0, 255, 1]);
      final path = '${root.path}/export.pdf';
      Future<void>? closing;
      repo.after = () async {
        closing = service.close();
      };
      await expectLater(
        service.owner.exportInformationFile(
          item.fields.single.attachment!,
          path,
        ),
        fails('service_unavailable'),
      );
      await closing;
      expect(await File(path).exists(), isFalse);
      expect(noPartials(), isTrue);
    },
    skip: !Platform.isWindows,
  );
}
