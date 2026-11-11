@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_storage/macos_backup_publication.dart';
import 'package:test/test.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

void main() {
  late Directory root;
  late MacBackupStagingDirectory staging;
  late String destination, source;
  final bytes = utf8.encode('Windows 原文核对；保留原件，不覆盖用户文件。\n');
  final failure = throwsA(isA<BackupPublicationFailure>());
  setUp(() async {
    root = await Directory.systemTemp.createTemp('Windows 发布 中文 ');
    root = Directory(await root.resolveSymbolicLinks());
    destination = '${root.path}/保存 原文.txt';
    staging = MacBackupPublicationFiles.createWindowsStaging(destination);
    source = '${staging.path}/prepared';
  });
  tearDown(() async {
    // These are exclusively this test's generated files. Never traverse a
    // replaced root or use a broad temporary-directory name match.
    expect(
      await FileSystemEntity.type(root.path, followLinks: false),
      FileSystemEntityType.directory,
    );
    expect(
      (await root.resolveSymbolicLinks()).toLowerCase(),
      root.path.toLowerCase(),
    );
    await root.delete(recursive: true);
  });
  MacBackupPublication prepare() {
    MacBackupPublicationFiles.writePrivateFile(source, bytes);
    return MacBackupPublicationFiles.prepare(source, destination);
  }

  for (final withAttachment in [false, true]) {
    test('registered encrypted backup exports and restores on Windows '
        '(attachment=$withAttachment)', () async {
      final repo = await EncryptedInformationRepository.open(
        '${root.path}/library',
        _Keys(),
      );
      final service = InformationService(repository: repo);
      try {
        await service.owner.createInformation('合成资料', '', [
          const FieldInput('内容', '', 'synthetic-windows-backup'),
        ]);
        if (withAttachment) {
          final file = File('${root.path}/合成附件.txt');
          await file.writeAsBytes(bytes);
          final draft = await service.owner.beginInformationFileDraft();
          try {
            final staged = await service.owner.stageInformationFile(
              draft,
              file.path,
            );
            await service.owner.commitInformationDraft(
              draft,
              'synthetic-file',
              InformationDraftInput(
                name: '合成附件',
                description: '',
                fields: [InformationDraftField.stagedFile('文件', '', staged.id)],
              ),
            );
          } finally {
            await service.owner.releaseInformationFileDraft(draft);
          }
        }
        final recovery = await repo.backups.enable();
        await repo.backups.saveRecoveryKeyTo('${root.path}/recovery.txt');
        final version = await repo.backups.operationVersion();
        await repo.backups.registerOutputStaging(
          operationId: 'windows-export',
          commandDigest: 'a' * 64,
          expectedVersion: version,
          action: BackupOutputAction.export,
          directory: staging.path,
          destination: destination,
        );
        var registered = false;
        await service.owner.exportLibrary(
          () => repo.backups.exportTo(
            source,
            stagingParent: staging.path,
            onStagingCreated: (child) async {
              expect(Directory(child).listSync(), isEmpty);
              WindowsPrivateFiles.verify(child, directory: true);
              await repo.backups.registerOutputStagingChild(
                'windows-export',
                child,
              );
              registered = true;
            },
          ),
        );
        expect(registered, isTrue);
        WindowsPrivateFiles.verify(source);
        final publication = MacBackupPublicationFiles.prepare(
          source,
          destination,
        );
        await repo.backups.prepareOutputOperation(
          operationId: 'windows-export',
          commandDigest: 'a' * 64,
          expectedVersion: version,
          action: BackupOutputAction.export,
          publication: publication,
        );
        final receipt = await repo.backups.publishOutputOperation(
          'windows-export',
        );
        expect(receipt.counts['information'], withAttachment ? 2 : 1);
        await repo.backups.cleanupRegisteredOutputStaging('windows-export');
        expect(Directory(staging.path).existsSync(), isFalse);
        expect(await repo.backups.pendingOutputStaging(), isEmpty);
        WindowsPrivateFiles.verify(destination);
        final restored = await EncryptedInformationRepository.open(
          '${root.path}/restored',
          _Keys(),
        );
        try {
          await restored.backups.restoreFrom(destination, recovery);
          expect(restored.items.length, withAttachment ? 2 : 1);
          expect(
            restored.items
                .firstWhere((i) => i.name == '合成资料')
                .fields
                .single
                .value,
            'synthetic-windows-backup',
          );
          expect(await restored.backups.pendingOutputStaging(), isEmpty);
          if (withAttachment) {
            final item = restored.items.firstWhere((i) => i.name == '合成附件');
            final field = item.fields.single.attachment;
            expect(field, isNotNull);
            expect(
              await restored.readInformationAttachmentChunk(
                field!,
                0,
                bytes.length,
              ),
              bytes,
            );
          }
        } finally {
          await restored.close();
        }
      } finally {
        await service.close();
        await repo.close();
      }
    });
  }

  test(
    'publish retains a private original until durable result, cleanup leaves selected file',
    () {
      final original = prepare();
      final publication = MacBackupPublication.fromPrivateJson(
        jsonDecode(jsonEncode(original.toPrivateJson()))
            as Map<String, dynamic>,
      );
      expect(publication.sourceIdentity, startsWith('windows:'));
      expect(
        MacBackupPublicationFiles.observe(publication),
        BackupPublicationObservation.absent,
      );
      MacBackupPublicationFiles.publish(publication);
      expect(
        MacBackupPublicationFiles.confirmPublished(publication),
        BackupPublicationObservation.matching,
      );
      expect(File(destination).readAsBytesSync(), bytes);
      expect(File(source).readAsBytesSync(), bytes);
      expect(() => MacBackupPublicationFiles.publish(publication), failure);
      // Only the publication validator permits its explicit second link.
      expect(
        () => WindowsPrivateFiles.verify(source),
        throwsA(isA<RuntimeMaterialFailure>()),
      );
      MacBackupPublicationFiles.cleanup(publication);
      expect(File(source).existsSync(), isFalse);
      expect(File(destination).readAsBytesSync(), bytes);
      MacBackupPublicationFiles.cleanupStaging(staging);
      expect(Directory(staging.path).existsSync(), isFalse);
    },
  );
  test(
    'NTFS tunneling of a recently deleted output name does not change the retained file identity',
    () async {
      // GetSaveFileName may test writability by creating/deleting the chosen
      // name. NTFS can transfer that creation time onto a later rename/link.
      File(destination).writeAsStringSync('Native panel writability probe');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final publication = prepare();
      File(destination).deleteSync();
      MacBackupPublicationFiles.publish(publication);
      expect(
        MacBackupPublicationFiles.confirmPublished(publication),
        BackupPublicationObservation.matching,
      );
      MacBackupPublicationFiles.cleanup(publication);
      MacBackupPublicationFiles.cleanupStaging(staging);
      expect(File(destination).readAsBytesSync(), bytes);
    },
  );
  test(
    'an occupied original reports the native sharing error then cleans the same publication after release',
    () async {
      final publication = prepare();
      final reader = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${Directory.current.path}/../info_core/test/support/windows_private_reader.dart',
        source,
        '800',
      ]);
      final errors = utf8.decoder.bind(reader.stderr).join();
      try {
        expect(
          await reader.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first,
          'reader-ready',
        );
        expect(
          () => MacBackupPublicationFiles.cleanup(publication),
          throwsA(
            isA<BackupPublicationFailure>()
                .having((e) => e.code, 'code', 'identity_unavailable')
                .having((e) => e.nativeError, 'nativeError', 32),
          ),
        );
        expect(File(source).existsSync(), isTrue);
        expect(File(destination).existsSync(), isFalse);
      } finally {
        await reader.stdin.close();
        expect(
          await reader.exitCode.timeout(const Duration(seconds: 5)),
          0,
          reason: await errors,
        );
      }
      MacBackupPublicationFiles.cleanup(publication);
      MacBackupPublicationFiles.cleanupStaging(staging);
      expect(File(destination).existsSync(), isFalse);
    },
  );

  test(
    'repeated cleanup of an already absent original preserves the native missing result',
    () {
      final publication = prepare();
      MacBackupPublicationFiles.cleanup(publication);
      for (var attempt = 0; attempt < 1500; attempt++) {
        MacBackupPublicationFiles.cleanup(publication);
      }
      MacBackupPublicationFiles.cleanupStaging(staging);
    },
  );

  test(
    'existing selected name and changed prepared bytes are never published over',
    () {
      final publication = prepare();
      File(destination).writeAsStringSync('original owner file');
      expect(() => MacBackupPublicationFiles.publish(publication), failure);
      expect(File(destination).readAsStringSync(), 'original owner file');
      File(source).writeAsStringSync('different prepared content');
      expect(
        () => MacBackupPublicationFiles.verifyPrepared(publication),
        failure,
      );
      expect(File(destination).readAsStringSync(), 'original owner file');
    },
  );
  test(
    'replaced staging and unknown entries are retained instead of recursively removed',
    () {
      MacBackupPublicationFiles.writePrivateFile(source, bytes);
      final unknown = File('${staging.path}/unregistered');
      unknown.writeAsStringSync('keep');
      expect(
        () => MacBackupPublicationFiles.cleanupStaging(
          staging,
          generatedFiles: {'prepared'},
        ),
        failure,
      );
      expect(File(source).readAsBytesSync(), bytes);
      expect(unknown.readAsStringSync(), 'keep');
      final original = Directory(
        staging.path,
      ).renameSync('${staging.path}.original');
      WindowsPrivateFiles.directory(Directory(staging.path));
      expect(() => MacBackupPublicationFiles.cleanupStaging(staging), failure);
      expect(Directory(staging.path).existsSync(), isTrue);
      expect(File('${original.path}/prepared').readAsBytesSync(), bytes);
    },
  );
  test(
    'output below its registered stage and traversal/ADS paths fail before publication',
    () {
      expect(
        () => MacBackupPublicationFiles.validateOutputPath(
          '${staging.path}/child',
          staging,
        ),
        failure,
      );
      expect(
        () => MacBackupPublicationFiles.validateOutputPath(
          '${root.path}/../escape.txt',
          staging,
        ),
        failure,
      );
      expect(
        () => MacBackupPublicationFiles.validateOutputPath(
          '${root.path}/file:stream',
          staging,
        ),
        failure,
      );
      expect(
        () => MacBackupPublicationFiles.validateOutputPath(
          '${root.path}/NUL.txt',
          staging,
        ),
        failure,
      );
      expect(Directory(staging.path).listSync(), isEmpty);
    },
  );
  test(
    'SQLCipher reopen after lost publication reply confirms original, never recreates a deleted output',
    () async {
      var store = await DeviceFileOperations.open(
        '${root.path}/device',
        serverId: 'windows-publish-server',
      );
      try {
        await store.fileOutputs.reserve(
          operationId: 'windows-save',
          commandDigest: 'a' * 64,
          itemId: 'windows-document',
          fieldKey: 'body',
          reference: InformationAttachmentRef('windows-attachment', 1),
          root: staging,
          destination: destination,
          length: bytes.length,
          contentDigest: sha256.convert(bytes).toString(),
        );
        await store.fileOutputs.prepare('windows-save', bytes);
        await expectLater(
          store.fileOutputs.publish(
            'windows-save',
            afterPublication: () async {
              throw StateError(
                'Synthetic lost response after native publication',
              );
            },
          ),
          throwsStateError,
        );
        expect(File(destination).readAsBytesSync(), bytes);
        await store.close();
        store = await DeviceFileOperations.open(
          '${root.path}/device',
          serverId: 'windows-publish-server',
        );
        final receipt = await store.fileOutputs.reconcile('windows-save');
        expect(receipt!.completed, isTrue);
        await File(destination).delete();
        expect(
          (await store.fileOutputs.publish('windows-save')).completed,
          isTrue,
        );
        expect(File(destination).existsSync(), isFalse);
        await store.fileOutputs.cleanup(
          'windows-save',
          releaseStaging: () async =>
              MacBackupPublicationFiles.cleanupStaging(staging),
        );
        expect(Directory(staging.path).existsSync(), isFalse);
        expect(
          (await store.fileOutputs.status('windows-save'))!.cleanupPending,
          isFalse,
        );
      } finally {
        await store.close();
      }
    },
  );
  test(
    'a removed output after lost reply stays unknown and retains its original anchor without replay',
    () async {
      var store = await DeviceFileOperations.open(
        '${root.path}/device',
        serverId: 'windows-publish-server',
      );
      try {
        await store.fileOutputs.reserve(
          operationId: 'unknown-save',
          commandDigest: 'b' * 64,
          itemId: 'windows-document',
          fieldKey: 'body',
          reference: InformationAttachmentRef('windows-attachment', 1),
          root: staging,
          destination: destination,
          length: bytes.length,
          contentDigest: sha256.convert(bytes).toString(),
        );
        await store.fileOutputs.prepare('unknown-save', bytes);
        await expectLater(
          store.fileOutputs.publish(
            'unknown-save',
            afterPublication: () async {
              throw StateError('Synthetic lost publication acknowledgement');
            },
          ),
          throwsStateError,
        );
        await File(destination).delete();
        await store.close();
        store = await DeviceFileOperations.open(
          '${root.path}/device',
          serverId: 'windows-publish-server',
        );
        final unknown = throwsA(
          isA<StorageFailure>().having(
            (error) => error.code,
            'code',
            'file_outcome_unknown',
          ),
        );
        await expectLater(store.fileOutputs.reconcile('unknown-save'), unknown);
        await expectLater(store.fileOutputs.publish('unknown-save'), unknown);
        expect(File(destination).existsSync(), isFalse);
        expect(
          Directory(
            staging.path,
          ).listSync().whereType<File>().single.readAsBytesSync(),
          bytes,
        );
        expect(
          (await store.fileOutputs.status('unknown-save'))!.uncertain,
          isTrue,
        );
      } finally {
        await store.close();
      }
    },
  );
}
