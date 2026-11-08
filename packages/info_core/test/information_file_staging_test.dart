import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

Matcher fails(String code) =>
    throwsA(isA<AccessFailure>().having((e) => e.status, 'status', code));

class _PausedRepository extends MemoryInformationRepository {
  final entered = Completer<void>();
  final continueWrite = Completer<void>();
  @override
  Future<InformationFileStage> stageInformationBytes({
    required String draftId,
    required String stageId,
    required String originalName,
    required String mediaType,
    required Uint8List bytes,
  }) async {
    entered.complete();
    await continueWrite.future;
    return super.stageInformationBytes(
      draftId: draftId,
      stageId: stageId,
      originalName: originalName,
      mediaType: mediaType,
      bytes: bytes,
    );
  }
}

class _PausedSettingsRepository extends MemoryInformationRepository {
  final entered = Completer<void>();
  final continueWrite = Completer<void>();
  @override
  Future<void> writeSetting(String key, int value) async {
    entered.complete();
    await continueWrite.future;
    await super.writeSetting(key, value);
  }
}

void main() {
  late Directory root;
  late File source;
  late MemoryInformationRepository repository;
  late InformationService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-file-intake-');
    source = File('${root.path}/简历 draft.pdf');
    await source.writeAsBytes([0, 255, 1, 2, ...utf8.encode('fictional file')]);
    repository = MemoryInformationRepository();
    service = InformationService(repository: repository);
  });
  tearDown(() async {
    await service.close();
    await root.delete(recursive: true);
  });

  test(
    'owner byte intake freezes uploads and retains the native draft lifetime',
    () async {
      await service.close();
      final paused = _PausedRepository();
      service = InformationService(repository: paused);
      final draft = await service.owner.beginInformationFileDraft();
      final original = Uint8List.fromList([0, 255, 1, 2, 3]);
      final supplied = Uint8List.fromList(original);
      final writing = service.owner.stageInformationBytes(
        draft,
        originalName: 'synthetic upload.bin',
        bytes: supplied,
      );
      supplied.fillRange(0, supplied.length, 8);
      await paused.entered.future;
      expect(service.owner.information, isEmpty);
      paused.continueWrite.complete();
      final saved = await writing;
      expect(saved.sha256, sha256.convert(original).toString());
      expect(saved.byteLength, original.length);
      expect(jsonEncode(saved.toPrivateJson()), isNot(contains(root.path)));
      await service.owner.releaseInformationFileDraft(draft);
      expect((await paused.informationFileStagingUsage()).files, 0);
      await expectLater(
        service.owner.stageInformationBytes(
          draft,
          originalName: 'late.bin',
          bytes: original,
        ),
        fails('stage_unavailable'),
      );
    },
  );

  test(
    'byte intake rejects oversized metadata and another owner before storing content',
    () async {
      final draft = await service.owner.beginInformationFileDraft();
      final other = InformationService(repository: repository);
      addTearDown(other.close);
      await expectLater(
        other.owner.stageInformationBytes(
          draft,
          originalName: 'foreign.bin',
          bytes: Uint8List(1),
        ),
        fails('stage_unavailable'),
      );
      for (final name in ['../source.txt', 'bad\nname', '..']) {
        await expectLater(
          service.owner.stageInformationBytes(
            draft,
            originalName: name,
            bytes: Uint8List(1),
          ),
          fails('invalid_information_file'),
        );
      }
      await expectLater(
        service.owner.stageInformationBytes(
          draft,
          originalName: 'large.bin',
          bytes: Uint8List(informationFileByteLimit + 1),
        ),
        fails('attachment_too_large'),
      );
      expect((await repository.informationFileStagingUsage()).files, 0);
      final empty = await service.owner.stageInformationBytes(
        draft,
        originalName: 'empty.bin',
        bytes: Uint8List(0),
      );
      expect(empty.byteLength, 0);
      expect((await repository.informationFileStagingUsage()).files, 1);
    },
  );

  test(
    'stage owns private metadata without creating public or formal content',
    () async {
      final draft = await service.owner.beginInformationFileDraft();
      final stage = await service.owner.stageInformationFile(
        draft,
        source.path,
        mediaType: 'application/pdf',
      );
      expect(stage.originalName, '简历 draft.pdf');
      expect(stage.byteLength, await source.length());
      expect(
        stage.sha256,
        sha256.convert(await source.readAsBytes()).toString(),
      );
      expect(
        InformationFileStage.fromPrivateJson(
          stage.toPrivateJson(),
        ).sameAs(stage),
        isTrue,
      );
      expect(jsonEncode(stage.toPrivateJson()), isNot(contains(root.path)));
      expect(repository.items, isEmpty);
      expect(service.owner.information, isEmpty);
      expect((await repository.informationFileStagingUsage()).files, 1);
      expect(await source.readAsBytes(), [
        0,
        255,
        1,
        2,
        ...utf8.encode('fictional file'),
      ]);
    },
  );

  test(
    'another draft or owner cannot consume or release an existing stage',
    () async {
      final a = await service.owner.beginInformationFileDraft();
      final b = await service.owner.beginInformationFileDraft();
      final stage = await service.owner.stageInformationFile(a, source.path);
      await expectLater(
        service.owner.releaseInformationStage(b, stage),
        fails('stage_unavailable'),
      );
      final other = InformationService(repository: repository);
      addTearDown(other.close);
      await expectLater(
        other.owner.stageInformationFile(a, source.path),
        fails('stage_unavailable'),
      );
      await service.owner.releaseInformationFileDraft(b);
      expect((await repository.informationFileStagingUsage()).files, 1);
      await service.owner.releaseInformationStage(a, stage);
      await service.owner.releaseInformationStage(a, stage);
      expect((await repository.informationFileStagingUsage()).bytes, 0);
    },
  );

  test(
    'missing directory or oversized replacement preserves the previous stage',
    () async {
      final draft = await service.owner.beginInformationFileDraft();
      final previous = await service.owner.stageInformationFile(
        draft,
        source.path,
      );
      for (final path in ['${root.path}/missing.pdf', root.path]) {
        await expectLater(
          service.owner.stageInformationFile(draft, path),
          fails('file_read_failed'),
        );
      }
      final big = await File(
        '${root.path}/too-big.bin',
      ).open(mode: FileMode.write);
      await big.truncate(informationFileByteLimit + 1);
      await big.close();
      await expectLater(
        service.owner.stageInformationFile(draft, '${root.path}/too-big.bin'),
        fails('attachment_too_large'),
      );
      final usage = await repository.informationFileStagingUsage();
      expect(usage.files, 1);
      expect(usage.bytes, previous.byteLength);
      expect(await source.exists(), isTrue);
    },
  );

  test(
    'cancel is idempotent and empty files are distinct from no selected file',
    () async {
      final empty = File('${root.path}/empty.txt');
      await empty.writeAsBytes([]);
      final draft = await service.owner.beginInformationFileDraft();
      final stage = await service.owner.stageInformationFile(draft, empty.path);
      expect(stage.byteLength, 0);
      expect((await repository.informationFileStagingUsage()).files, 1);
      await service.owner.releaseInformationFileDraft(draft);
      await service.owner.releaseInformationFileDraft(draft);
      await expectLater(
        service.owner.stageInformationFile(draft, source.path),
        fails('stage_unavailable'),
      );
      expect((await repository.informationFileStagingUsage()).files, 0);
      expect(await empty.exists(), isTrue);
    },
  );

  test(
    'successful library replacement invalidates old form but still allows cancellation',
    () async {
      final draft = await service.owner.beginInformationFileDraft();
      await service.owner.stageInformationFile(draft, source.path);
      // The trusted storage callback is synthetic here; actual SQLCipher restore
      // is separately checked to delete staged rows inside its transaction.
      await service.owner.restoreLibrary(() async {});
      await expectLater(
        service.owner.stageInformationFile(draft, source.path),
        fails('stage_unavailable'),
      );
      await service.owner.beginInformationFileDraft();
      await service.owner.releaseInformationFileDraft(draft);
      expect((await repository.informationFileStagingUsage()).files, 0);
    },
  );

  test('metadata validation fails before creating a staged row', () async {
    final draft = await service.owner.beginInformationFileDraft();
    await expectLater(
      service.owner.stageInformationFile(
        draft,
        source.path,
        mediaType: 'text/plain\n',
      ),
      fails('invalid_information_file'),
    );
    final bytes = Uint8List.fromList([1, 2, 3]);
    for (final name in [
      '../resume.pdf',
      'C:\\private\\resume.pdf',
      '..',
      'bad\nname',
    ]) {
      expect(
        () => InformationFileStage.forBytes(
          id: 's',
          draftId: 'd',
          originalName: name,
          mediaType: 'application/pdf',
          bytes: bytes,
        ),
        fails('invalid_information_file'),
      );
    }
    expect((await repository.informationFileStagingUsage()).files, 0);
  });

  test(
    'memory retries are immutable and metadata-only stages have a row bound',
    () async {
      final bytes = Uint8List.fromList([1]);
      Future<InformationFileStage> stage(String id, Uint8List data) =>
          repository.stageInformationBytes(
            draftId: 'draft',
            stageId: id,
            originalName: 'file.bin',
            mediaType: 'application/octet-stream',
            bytes: data,
          );
      final first = await stage('same', bytes);
      expect((await stage('same', bytes)).sameAs(first), isTrue);
      await expectLater(
        stage('same', Uint8List.fromList([2])),
        fails('operation_conflict'),
      );
      for (var n = 1; n < informationFileStageLimit; n++) {
        await stage('s$n', Uint8List(0));
      }
      await expectLater(
        stage('over', Uint8List(0)),
        fails('attachment_capacity_exceeded'),
      );
      expect(
        (await repository.informationFileStagingUsage()).files,
        informationFileStageLimit,
      );
      await repository.releaseInformationDraft('wrong-draft');
      expect(
        (await repository.informationFileStagingUsage()).files,
        informationFileStageLimit,
      );
      await repository.releaseInformationDraft('draft');
    },
  );

  test(
    'shutdown during an awaited encrypted write returns no usable stage and drains it',
    () async {
      final paused = _PausedRepository();
      await service.close();
      service = InformationService(repository: paused);
      final draft = await service.owner.beginInformationFileDraft();
      final writing = service.owner.stageInformationFile(draft, source.path);
      final expected = expectLater(writing, fails('service_unavailable'));
      await paused.entered.future;
      final closing = service.close();
      paused.continueWrite.complete();
      await expected;
      await closing;
      expect((await paused.informationFileStagingUsage()).files, 0);
      await expectLater(
        service.owner.beginInformationFileDraft(),
        fails('service_unavailable'),
      );
    },
  );

  test(
    'close without file drafts does not wait for unrelated owner writes',
    () async {
      final paused = _PausedSettingsRepository();
      await service.close();
      service = InformationService(repository: paused);
      final writing = service.owner.setRequestLifetime(
        const Duration(minutes: 5),
      );
      await paused.entered.future;
      final closing = service.close();
      final didClose = await closing
          .then((_) => true)
          .timeout(const Duration(milliseconds: 250), onTimeout: () => false);
      paused.continueWrite.complete();
      await writing;
      await closing;
      expect(didClose, isTrue);
    },
  );
}
