@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_storage/macos_backup_publication.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  late Directory root, stage, outputs;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  var opened = false;
  final content = utf8.encode('独立合成附件\n');
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      '${root.path}/library',
      keys,
    );
    opened = true;
  }

  Future<void> close() async {
    if (!opened) return;
    await repo.close();
    opened = false;
  }

  void sql(String query, [List<Object?> params = const []]) {
    final db = sqlite3.open('${root.path}/library/library.db');
    try {
      final key = keys.key!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$key\'"');
      db.execute(query, params);
    } finally {
      db.close();
    }
  }

  Matcher fails(String code) =>
      throwsA(isA<StorageFailure>().having((e) => e.code, 'code', code));
  Future<void> reserve([String id = 'save', List<int>? bytes]) =>
      repo.fileOutputs.reserve(
        operationId: id,
        commandDigest: 'a' * 64,
        itemId: 'item',
        fieldKey: 'file',
        reference: InformationAttachmentRef('attachment', 1),
        root: MacBackupPublicationFiles.captureStaging(stage.path),
        destination: '${outputs.path}/合成附件.txt',
        length: (bytes ?? content).length,
        contentDigest: sha256.convert(bytes ?? content).toString(),
        stagingBookmark: 'synthetic-private-bookmark',
      );
  Future<void> prepare([String id = 'save']) async {
    await reserve(id);
    await repo.fileOutputs.prepare(id, content);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('information-file-output-');
    root = Directory(root.resolveSymbolicLinksSync());
    stage = await root.createTemp('stage-');
    outputs = await root.createTemp('output-');
    keys = TestKeyStore();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });

  test(
    'durable save survives reopen, never rewrites output, cleanup keeps receipt',
    () async {
      await prepare();
      final done = await repo.fileOutputs.publish('save');
      expect(done.completed, isTrue);
      expect(done.fileName, '合成附件.txt');
      expect(await File('${outputs.path}/合成附件.txt').readAsBytes(), content);
      expect(await repo.backups.pendingOutputCleanupCount(), 0);
      expect(await repo.backups.pendingOutputOperationIds(), isEmpty);
      expect(await repo.backups.latestExportOperation(), isNull);
      expect(await repo.backups.pendingOwnerOperations(), isEmpty);
      await close();
      await open();
      expect((await repo.fileOutputs.publish('save')).completed, isTrue);
      await repo.fileOutputs.cleanup('save');
      expect(stage.existsSync(), isFalse);
      expect((await repo.fileOutputs.status('save'))!.cleanupPending, isFalse);
      await File('${outputs.path}/合成附件.txt').delete();
      expect((await repo.fileOutputs.reconcile('save'))!.completed, isTrue);
      expect(File('${outputs.path}/合成附件.txt').existsSync(), isFalse);
    },
  );
  test('empty files valid and private writes refuse overwrite', () async {
    await reserve('save', []);
    await repo.fileOutputs.prepare('save', []);
    expect((await repo.fileOutputs.publish('save')).completed, isTrue);
    expect(File('${outputs.path}/合成附件.txt').lengthSync(), 0);
    expect(
      () => MacBackupPublicationFiles.writePrivateFile(
        '${stage.path}/prepared',
        [1],
      ),
      throwsA(isA<BackupPublicationFailure>()),
    );
    expect(File('${stage.path}/prepared').lengthSync(), 0);
  });
  test('reserved or prepared after reopen cannot publish', () async {
    await reserve();
    await close();
    await open();
    expect(
      (await repo.fileOutputs.publish('save')).phase,
      InformationFileOutputPhase.notPublished,
    );
    expect(File('${outputs.path}/合成附件.txt').existsSync(), isFalse);
    await repo.fileOutputs.cleanup('save');
    stage = await root.createTemp('stage-');
    await prepare('save2');
    await close();
    await open();
    expect(
      (await repo.fileOutputs.publish('save2')).phase,
      InformationFileOutputPhase.notPublished,
    );
    expect(File('${outputs.path}/合成附件.txt').existsSync(), isFalse);
  });
  test(
    'preparation verifies bytes and abandoned partial stage cleans',
    () async {
      await reserve();
      await expectLater(
        repo.fileOutputs.prepare('save', [1]),
        fails('attachment_integrity_failed'),
      );
      expect(stage.listSync(), isEmpty);
      MacBackupPublicationFiles.writePrivateFile('${stage.path}/prepared', [1]);
      expect((await repo.fileOutputs.reconcile('save'))!.completed, isFalse);
      await repo.fileOutputs.cleanup('save');
      expect(stage.existsSync(), isFalse);
    },
  );
  test('existing selected output untouched and failure durable', () async {
    await prepare();
    await File('${outputs.path}/合成附件.txt').writeAsString('保留');
    expect(
      (await repo.fileOutputs.publish('save')).phase,
      InformationFileOutputPhase.notPublished,
    );
    await close();
    await open();
    expect((await repo.fileOutputs.publish('save')).completed, isFalse);
    await repo.fileOutputs.cleanup('save');
    expect(File('${outputs.path}/合成附件.txt').readAsStringSync(), '保留');
  });
  test('lost final SQL receipt reconciles original inode after reopen', () async {
    await prepare();
    sql(
      "CREATE TRIGGER fail_receipt BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.phase')='succeeded' BEGIN SELECT RAISE(ABORT,'synthetic'); END",
    );
    await expectLater(repo.fileOutputs.publish('save'), throwsA(anything));
    expect((await repo.fileOutputs.status('save'))!.uncertain, isTrue);
    await expectLater(
      repo.fileOutputs.cleanup('save'),
      fails('file_outcome_unknown'),
    );
    sql('DROP TRIGGER fail_receipt');
    await close();
    await open();
    expect((await repo.fileOutputs.reconcile('save'))!.completed, isTrue);
    await repo.fileOutputs.cleanup('save');
  });
  test(
    'absent or identical replacement stays unknown without republish',
    () async {
      await prepare();
      await expectLater(
        repo.fileOutputs.publish(
          'save',
          afterPublication: () async {
            throw StateError('lost');
          },
        ),
        throwsA(anything),
      );
      final file = File('${outputs.path}/合成附件.txt');
      await file.delete();
      await close();
      await open();
      await expectLater(
        repo.fileOutputs.publish('save'),
        fails('file_outcome_unknown'),
      );
      expect(file.existsSync(), isFalse);
      await file.writeAsBytes(content);
      await expectLater(
        repo.fileOutputs.reconcile('save'),
        fails('file_outcome_unknown'),
      );
      expect(File('${stage.path}/prepared').existsSync(), isTrue);
    },
  );
  test(
    'callback failure preserves publication and cleanup release retries',
    () async {
      await prepare();
      await expectLater(
        repo.fileOutputs.publish(
          'save',
          afterPublication: () async {
            throw StateError('lost capability');
          },
        ),
        throwsA(anything),
      );
      await repo.fileOutputs.recordOutputBookmark(
        'save',
        'synthetic-output-bookmark',
      );
      expect(
        (await repo.fileOutputs.access('save'))['outputBookmark'],
        'synthetic-output-bookmark',
      );
      expect((await repo.fileOutputs.reconcile('save'))!.completed, isTrue);
      var releases = 0;
      await expectLater(
        repo.fileOutputs.cleanup(
          'save',
          releaseStaging: () async {
            releases++;
            throw StateError('retry');
          },
        ),
        throwsA(anything),
      );
      expect((await repo.fileOutputs.status('save'))!.completed, isTrue);
      expect((await repo.fileOutputs.status('save'))!.cleanupPending, isTrue);
      await repo.fileOutputs.cleanup(
        'save',
        releaseStaging: () async {
          releases++;
        },
      );
      expect(releases, 2);
      await expectLater(
        repo.fileOutputs.access('save'),
        fails('file_operation_missing'),
      );
    },
  );
  test('extra files or directory replacement prevent cleanup', () async {
    await prepare();
    await repo.fileOutputs.publish('save');
    await File('${stage.path}/owner-file').writeAsString('保留');
    await expectLater(
      repo.fileOutputs.cleanup('save'),
      throwsA(isA<BackupPublicationFailure>()),
    );
    expect(File('${stage.path}/owner-file').readAsStringSync(), '保留');
    final moved = await stage.rename('${stage.path}-original');
    await stage.create();
    await expectLater(
      repo.fileOutputs.cleanup('save'),
      throwsA(isA<BackupPublicationFailure>()),
    );
    expect(moved.existsSync(), isTrue);
  });
  test(
    'invalidated journal cannot replay but terminal cleanup allowed',
    () async {
      await prepare();
      await repo.fileOutputs.publish('save');
      sql('UPDATE backup_operations SET invalidated=1');
      await expectLater(
        repo.fileOutputs.status('save'),
        fails('library_changed'),
      );
      await expectLater(
        repo.fileOutputs.publish('save'),
        fails('library_changed'),
      );
      expect(await repo.fileOutputs.pending(), isEmpty);
      await repo.fileOutputs.cleanup('save');
      expect(stage.existsSync(), isFalse);
    },
  );
  test('malformed journal and duplicate binding never absence', () async {
    await reserve();
    await expectLater(reserve(), fails('operation_conflict'));
    sql(
      "UPDATE backup_operations SET payload=json_set(payload,'\$.destination','/tmp/../wrong')",
    );
    await expectLater(
      repo.fileOutputs.status('save'),
      fails('invalid_file_output_receipt'),
    );
    await expectLater(
      repo.fileOutputs.pending(),
      fails('invalid_file_output_receipt'),
    );
  });
  test(
    'reopened reservation cannot prepare again and invalidated preparations clean without replay',
    () async {
      await reserve();
      await close();
      await open();
      await expectLater(
        repo.fileOutputs.prepare('save', content),
        fails('operation_conflict'),
      );
      expect(stage.listSync(), isEmpty);
      sql('UPDATE backup_operations SET invalidated=1');
      expect(
        (await repo.fileOutputs.pending(includeInvalidated: true)).length,
        1,
      );
      await repo.fileOutputs.cleanup('save');
      expect(stage.existsSync(), isFalse);
    },
  );
  test(
    'cleanup acknowledgement retries after native allocation parent is removed',
    () async {
      stage = await root.createTemp('allocation-');
      final allocation = stage;
      stage = await Directory('${allocation.path}/stage').create();
      await Process.run('chmod', ['700', stage.path]);
      await prepare();
      await repo.fileOutputs.publish('save');
      sql(
        "CREATE TRIGGER fail_cleanup BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.cleanupPending')=0 BEGIN SELECT RAISE(ABORT,'synthetic'); END",
      );
      await expectLater(
        repo.fileOutputs.cleanup(
          'save',
          releaseStaging: () async {
            await allocation.delete();
          },
        ),
        throwsA(anything),
      );
      expect(allocation.existsSync(), isFalse);
      sql('DROP TRIGGER fail_cleanup');
      await close();
      await open();
      await repo.fileOutputs.cleanup('save');
      expect((await repo.fileOutputs.status('save'))!.cleanupPending, isFalse);
      expect(File('${outputs.path}/合成附件.txt').readAsBytesSync(), content);
    },
  );
}
