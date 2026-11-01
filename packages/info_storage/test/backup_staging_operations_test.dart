import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_storage/macos_backup_publication.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  late Directory root, staging;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  var opened = false;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      '${root.path}/library',
      keys,
    );
    service = InformationService(repository: repo);
    opened = true;
  }

  Future<void> close() async {
    if (!opened) return;
    await service.close();
    await repo.close();
    opened = false;
  }

  void sql(String query, [List<Object?> args = const []]) {
    final db = sqlite3.open('${root.path}/library/library.db');
    final key = keys.key!
        .map((n) => n.toRadixString(16).padLeft(2, '0'))
        .join();
    try {
      db.execute('PRAGMA key = "x\'$key\'"');
      db.execute(query, args);
    } finally {
      db.close();
    }
  }

  Matcher fails(String code) =>
      throwsA(isA<StorageFailure>().having((e) => e.code, 'code', code));
  Future<void> register(
    String id, {
    BackupOutputAction action = BackupOutputAction.saveKey,
    String? bookmark,
  }) => repo.backups.registerOutputStaging(
    operationId: id,
    commandDigest: 'a' * 64,
    expectedVersion: 2,
    action: action,
    directory: staging.path,
    stagingBookmark: bookmark,
    destination: '${root.path}/$id.output',
  );
  Future<MacBackupPublication> prepareKey(String id, {String? bookmark}) async {
    await register(id, bookmark: bookmark);
    MacBackupPublicationFiles.writeRecoveryKey(
      '${staging.path}/prepared',
      utf8.encode((await repo.backups.recoveryKey())!),
    );
    final publication = MacBackupPublicationFiles.prepare(
      '${staging.path}/prepared',
      '${root.path}/$id.output',
    );
    await repo.backups.prepareOutputOperation(
      operationId: id,
      commandDigest: 'a' * 64,
      expectedVersion: 2,
      action: BackupOutputAction.saveKey,
      publication: publication,
    );
    return publication;
  }

  setUp(() async {
    root = Directory(
      (await Directory.systemTemp.createTemp(
        'backup-staging-journal-',
      )).resolveSymbolicLinksSync(),
    );
    staging = await root.createTemp('staging-');
    keys = TestKeyStore();
    await open();
    await repo.backups.enable();
    await service.owner.exportLibrary(() => repo.backups.operationVersion());
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });

  group('Mac persistent staging', () {
    test(
      'native capability persists before bytes, publication interruption is not replayed',
      () async {
        final bookmark = base64Encode([1, 2, 3]);
        final outputBookmark = base64Encode([4, 5, 6]);
        final publication = await prepareKey('scope', bookmark: bookmark);
        expect(
          (await repo.backups.outputStagingAccess(
            'scope',
          ))!.toNativeArguments()['stagingBookmark'],
          bookmark,
        );
        await expectLater(
          repo.backups.recordOutputBookmark('scope', outputBookmark),
          fails('operation_conflict'),
        );
        var callbacks = 0;
        await expectLater(
          repo.backups.publishOutputOperation(
            'scope',
            afterPublication: () async {
              callbacks++;
              await repo.backups.recordOutputBookmark('scope', outputBookmark);
              throw const StorageFailure('backup_outcome_unknown');
            },
          ),
          fails('backup_outcome_unknown'),
        );
        expect(File(publication.destination).existsSync(), isTrue);
        expect(
          await repo.backups.outputOperationPhase('scope'),
          BackupOutputPhase.publishing,
        );
        await close();
        await open();
        expect(
          (await repo.backups.outputStagingAccess(
            'scope',
          ))!.toNativeArguments()['outputBookmark'],
          outputBookmark,
        );
        final receipt = await repo.backups.publishOutputOperation(
          'scope',
          afterPublication: () async {
            callbacks++;
          },
        );
        expect(callbacks, 1);
        expect(receipt.operationId, 'scope');
        await repo.backups.cleanupRegisteredOutputStaging('scope');
        expect(await repo.backups.outputStagingAccess('scope'), isNull);
        await expectLater(
          repo.backups.recordOutputBookmark('scope', outputBookmark),
          fails('operation_conflict'),
        );
      },
    );
    test(
      'malformed native capabilities are rejected without registration',
      () async {
        for (final value in [
          '',
          'not-base64',
          base64Encode(List.filled(65537, 1)),
        ]) {
          await expectLater(
            register('invalid', bookmark: value),
            fails('invalid_backup_operation_receipt'),
          );
        }
        expect(await repo.backups.pendingOutputStaging(), isEmpty);
        await register('legacy');
        expect(await repo.backups.outputStagingAccess('legacy'), isNull);
      },
    );
    test(
      'key publication cleanup removes only staging and survives a lost cleanup acknowledgement',
      () async {
        final publication = await prepareKey('key');
        final receipt = await repo.backups.publishOutputOperation('key');
        expect(await repo.backups.pendingOutputStaging(), ['key']);
        expect(await repo.backups.pendingOutputCleanupCount(), 1);
        sql(
          "CREATE TRIGGER fail_cleanup BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.action')='staging' AND json_extract(NEW.payload,'\$.cleanupPending')=0 BEGIN SELECT RAISE(ABORT,'injected'); END",
        );
        await expectLater(
          repo.backups.cleanupRegisteredOutputStaging('key'),
          fails('backup_cleanup_pending'),
        );
        expect(staging.existsSync(), isFalse);
        expect(File(publication.destination).existsSync(), isTrue);
        expect(await repo.backups.pendingOutputStaging(), ['key']);
        sql('DROP TRIGGER fail_cleanup');
        await close();
        await open();
        await repo.backups.cleanupRegisteredOutputStaging('key');
        await repo.backups.cleanupRegisteredOutputStaging('key');
        expect(await repo.backups.pendingOutputCleanupCount(), 0);
        expect(
          (await repo.backups.reconcileOutputOperation('key'))!.toJson(),
          receipt.toJson(),
        );
        expect(File(publication.destination).existsSync(), isTrue);
      },
    );

    test(
      'native release failure keeps cleanup pending after material removal',
      () async {
        final publication = await prepareKey('native');
        final receipt = await repo.backups.publishOutputOperation('native');
        await expectLater(
          repo.backups.cleanupRegisteredOutputStaging(
            'native',
            releaseNative: () async {
              expect(staging.existsSync(), isFalse);
              throw StateError('native release unavailable');
            },
          ),
          fails('backup_cleanup_pending'),
        );
        expect(await repo.backups.pendingOutputStaging(), ['native']);
        expect(
          (await repo.backups.reconcileOutputOperation('native'))!.toJson(),
          receipt.toJson(),
        );
        var released = false;
        await repo.backups.cleanupRegisteredOutputStaging(
          'native',
          releaseNative: () async {
            released = true;
          },
        );
        expect(released, isTrue);
        expect(await repo.backups.pendingOutputStaging(), isEmpty);
        expect(File(publication.destination).existsSync(), isTrue);
      },
    );

    test(
      'interrupted production is registered before bytes and never reproduces the same intent',
      () async {
        await register('incomplete');
        expect(staging.listSync(), isEmpty);
        MacBackupPublicationFiles.writeRecoveryKey(
          '${staging.path}/prepared',
          utf8.encode('synthetic'),
        );
        await close();
        await open();
        await expectLater(register('incomplete'), fails('operation_conflict'));
        expect(
          await repo.backups.reconcileOutputOperation('incomplete'),
          isNull,
        );
        await repo.backups.cleanupRegisteredOutputStaging('incomplete');
        expect(staging.existsSync(), isFalse);
        expect(File('${root.path}/incomplete.output').existsSync(), isFalse);
        expect(await repo.backups.pendingOutputStaging(), isEmpty);
      },
    );

    test(
      'registered encrypted child cleanup preserves unknown entries and retries safely',
      () async {
        await repo.backups.saveRecoveryKeyTo('${root.path}/key.txt');
        final version = await repo.backups.operationVersion();
        await repo.backups.registerOutputStaging(
          operationId: 'export',
          commandDigest: 'a' * 64,
          expectedVersion: version,
          action: BackupOutputAction.export,
          directory: staging.path,
          destination: '${root.path}/archive.aimbackup',
        );
        final child = await staging.createTemp('.agent-info-backup-');
        await repo.backups.registerOutputStagingChild('export', child.path);
        await File(
          '${child.path}/backup.partial',
        ).writeAsString('synthetic ciphertext placeholder');
        await File('${child.path}/owner-file').writeAsString('keep');
        await close();
        await open();
        await expectLater(
          repo.backups.cleanupRegisteredOutputStaging('export'),
          fails('backup_cleanup_pending'),
        );
        expect(File('${child.path}/backup.partial').existsSync(), isTrue);
        expect(File('${child.path}/owner-file').readAsStringSync(), 'keep');
        await File('${child.path}/owner-file').delete();
        await repo.backups.cleanupRegisteredOutputStaging('export');
        expect(staging.existsSync(), isFalse);
        expect(await repo.backups.pendingOutputStaging(), isEmpty);
      },
    );

    test(
      'unknown publication retains its anchor; restoring a library does not turn it into a cleanup success',
      () async {
        final publication = await prepareKey('unknown');
        sql(
          "UPDATE backup_operations SET payload=json_set(payload,'\$.phase','publishing') WHERE operation_id='unknown'",
        );
        await expectLater(
          repo.backups.cleanupRegisteredOutputStaging('unknown'),
          fails('backup_outcome_unknown'),
        );
        sql('UPDATE backup_operations SET invalidated=1');
        expect(await repo.backups.pendingOutputStaging(), ['unknown']);
        await expectLater(
          repo.backups.cleanupRegisteredOutputStaging('unknown'),
          fails('backup_outcome_unknown'),
        );
        expect(File(publication.source).existsSync(), isTrue);
        expect(File(publication.destination).existsSync(), isFalse);
      },
    );

    test(
      'successful old-library output can be cleaned without replay after a real empty restore',
      () async {
        final publication = await prepareKey('old');
        await repo.backups.publishOutputOperation('old');
        final archive = '${root.path}/empty.aimbackup';
        final recovery = (await repo.backups.recoveryKey())!;
        await service.owner.exportLibrary(() => repo.backups.exportTo(archive));
        await service.owner.restoreLibrary(
          () => repo.backups.restoreFrom(archive, recovery),
        );
        await expectLater(
          repo.backups.reconcileOutputOperation('old'),
          fails('library_changed'),
        );
        expect(await repo.backups.pendingOutputCleanupCount(), 1);
        await repo.backups.cleanupRegisteredOutputStaging('old');
        expect(await repo.backups.pendingOutputCleanupCount(), 0);
        expect(File(publication.destination).existsSync(), isTrue);
        final other = await EncryptedInformationRepository.open(
          '${root.path}/other',
          TestKeyStore(),
        );
        try {
          await other.backups.restoreFrom(archive, recovery);
          expect(await other.backups.pendingOutputStaging(), isEmpty);
        } finally {
          await other.close();
        }
      },
    );

    for (final withAttachment in [false, true]) {
      test(
        'real export registers durably before SQLCipher writes (attachments=$withAttachment)',
        () async {
          await repo.backups.saveRecoveryKeyTo('${root.path}/key.txt');
          await service.owner.createInformation('synthetic', '', [
            const FieldInput('value', '', 'private-synthetic'),
          ]);
          if (withAttachment) {
            final file = File('${root.path}/synthetic.txt');
            await file.writeAsBytes([1, 2, 3]);
            final draft = await service.owner.beginInformationFileDraft();
            final stage = await service.owner.stageInformationFile(
              draft,
              file.path,
            );
            await service.owner.commitInformationDraft(
              draft,
              'file-save',
              InformationDraftInput(
                name: 'attachment',
                description: '',
                fields: [
                  InformationDraftField.stagedFile('file', '', stage.id),
                ],
              ),
            );
            await service.owner.releaseInformationFileDraft(draft);
          }
          final version = await repo.backups.operationVersion();
          await repo.backups.registerOutputStaging(
            operationId: 'export',
            commandDigest: 'a' * 64,
            expectedVersion: version,
            action: BackupOutputAction.export,
            directory: staging.path,
            destination: '${root.path}/export.output',
          );
          var called = false;
          await service.owner.exportLibrary(
            () => repo.backups.exportTo(
              '${staging.path}/prepared',
              stagingParent: staging.path,
              onStagingCreated: (path) async {
                expect(Directory(path).listSync(), isEmpty);
                await repo.backups.registerOutputStagingChild('export', path);
                final independent = sqlite3.open(
                  '${root.path}/library/library.db',
                );
                final hex = keys.key!
                    .map((n) => n.toRadixString(16).padLeft(2, '0'))
                    .join();
                try {
                  independent.execute('PRAGMA key = "x\'$hex\'"');
                  final count = independent
                      .select(
                        "SELECT count(*) AS n FROM backup_operations WHERE json_extract(payload,'\$.action')='staging' AND json_type(payload,'\$.child')='object'",
                      )
                      .single['n'];
                  expect(
                    count,
                    1,
                    reason:
                        'Registration must be committed, not nested in the export read transaction.',
                  );
                } finally {
                  independent.close();
                }

                called = true;
              },
            ),
          );
          expect(called, isTrue);
          final publication = MacBackupPublicationFiles.prepare(
            '${staging.path}/prepared',
            '${root.path}/export.output',
          );
          await repo.backups.prepareOutputOperation(
            operationId: 'export',
            commandDigest: 'a' * 64,
            expectedVersion: version,
            action: BackupOutputAction.export,
            publication: publication,
          );
          final receipt = await repo.backups.publishOutputOperation('export');
          expect(receipt.counts['information'], withAttachment ? 2 : 1);
          await repo.backups.cleanupRegisteredOutputStaging('export');
          expect(staging.existsSync(), isFalse);
          expect(
            (await repo.backups.inspect(
              publication.destination,
              (await repo.backups.recoveryKey())!,
            )).informationCount,
            withAttachment ? 2 : 1,
          );
        },
      );
    }
    test(
      'journal rejection prevents material production; replaced directory is preserved',
      () async {
        sql(
          "CREATE TRIGGER fail_staging BEFORE INSERT ON backup_operations WHEN json_extract(NEW.payload,'\$.action')='staging' BEGIN SELECT RAISE(ABORT,'injected'); END",
        );
        await expectLater(register('rejected'), fails('backup_staging_failed'));
        expect(staging.listSync(), isEmpty);
        expect(await repo.backups.pendingOutputStaging(), isEmpty);
        sql('DROP TRIGGER fail_staging');
        await register('changed');
        final moved = await staging.rename('${root.path}/moved');
        await staging.create();
        await expectLater(
          repo.backups.cleanupRegisteredOutputStaging('changed'),
          fails('backup_cleanup_pending'),
        );
        expect(staging.existsSync(), isTrue);
        expect(moved.existsSync(), isTrue);
      },
    );
  }, skip: !Platform.isMacOS);
}
