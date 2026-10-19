import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';
import 'backup_setup.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async {
    key = List.of(value);
  }
}

class _Files implements InformationDeliveryFiles {
  final native = WindowsInformationDeliveryFiles();
  int writes = 0, cleans = 0;
  InformationDeliveryLease? last;
  Future<void> Function(InformationDeliveryLease)? onReserve,
      onVerify,
      beforeWrite;
  @override
  Future<InformationDeliveryLease> reserve(String name) async {
    final value = await native.reserve(name);
    last = value;
    await onReserve?.call(value);
    return value;
  }

  @override
  Future<void> write(InformationDeliveryLease lease, Uint8List bytes) async {
    await beforeWrite?.call(lease);
    await native.write(lease, bytes);
    writes++;
  }

  @override
  Future<void> verify(
    InformationDeliveryLease lease,
    int size,
    String hash,
  ) async {
    await native.verify(lease, size, hash);
    await onVerify?.call(lease);
  }

  @override
  Future<void> cleanup(InformationDeliveryLease lease) async {
    await native.cleanup(lease);
    cleans++;
  }
}

Matcher fileFails(String code) =>
    throwsA(isA<InformationFileFailure>().having((e) => e.code, 'code', code));
Map<String, dynamic> result(Map<String, Object?> reply) =>
    Map<String, dynamic>.from(reply['delivery'] as Map);
void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  late _Files files;
  late DateTime now;
  late InformationItem item;
  late String session, request;
  final data = Uint8List.fromList([
    0,
    255,
    ...utf8.encode('SYNTHETIC-DELIVERY-SQLCIPHER-39412'),
  ]);
  sqlite.Database inspect() {
    final db = sqlite.sqlite3.open('${root.path}/vault/library.db');
    final hex = keys.key!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  void mutate(
    String path,
    String key,
    void Function(Map<String, dynamic>) change,
  ) {
    final db = sqlite.sqlite3.open(path);
    final hex = base64Url
        .decode(key.substring('aim-recovery-v1:'.length))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    try {
      db.execute('PRAGMA key = "x\'$hex\'"');
      final doc =
          jsonDecode(
                db
                        .select('SELECT payload FROM backup_snapshot')
                        .single['payload']
                    as String,
              )
              as Map<String, dynamic>;
      change(doc);
      db.execute('UPDATE backup_snapshot SET payload=?', [jsonEncode(doc)]);
    } finally {
      db.close();
    }
  }

  InformationFileFetchInput input(String op) =>
      InformationFileFetchInput.fromJson({
        'protocolVersion': 2,
        'command': 'file-fetch',
        'requestId': request,
        'itemId': item.id,
        'fieldId': item.fields.single.id,
        'operationId': op,
      });
  Future<void> approve() async {
    session = service.agent.openSession('合成文件聊天');
    request = service.agent.request(session, '读取合成简历', [
      FieldRef(item.id, item.fields.single.id),
    ]).id;
    service.owner.approve(request, [FieldRef(item.id, item.fields.single.id)]);
    await service.owner.retryAuditStorage();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('file-delivery-sqlcipher-');
    keys = _Keys();
    files = _Files();
    now = DateTime.utc(2026, 10, 19);
    repo = await EncryptedInformationRepository.open(
      '${root.path}/vault',
      keys,
      clock: () => now,
    );
    service = InformationService(
      repository: repo,
      clock: () => now,
      informationDeliveryFiles: files,
    );
    final source = File('${root.path}/fictional.pdf');
    await source.writeAsBytes(data);
    final draft = await service.owner.beginInformationFileDraft();
    final stage = await service.owner.stageInformationFile(
      draft,
      source.path,
      mediaType: 'application/pdf',
    );
    item = await service.owner.commitInformationDraft(
      draft,
      'save',
      InformationDraftInput(
        name: '合成资料',
        description: '',
        fields: [InformationDraftField.stagedFile('简历', '', stage.id)],
      ),
    );
    await service.owner.releaseInformationFileDraft(draft);
  });
  tearDown(() async {
    files.onReserve = null;
    files.onVerify = null;
    files.beforeWrite = null;
    final db = inspect();
    try {
      for (final name in [
        'reject_registration',
        'reject_ready',
        'reject_restore',
      ]) {
        db.execute('DROP TRIGGER IF EXISTS $name');
      }
    } finally {
      db.close();
    }
    await service.close();
    await repo.close();
    await service.close();
    await root.delete(recursive: true);
  });
  test(
    'real encrypted registry precedes native body writes and fixed copies persist without plaintext vault data',
    () async {
      await approve();
      files.beforeWrite = (lease) async {
        final db = inspect();
        try {
          final row = db
              .select('SELECT payload FROM information_deliveries')
              .single;
          final saved = InformationFileDelivery.fromPrivateJson(
            jsonDecode(row['payload'] as String) as Map<String, dynamic>,
          );
          expect(saved.state, 'preparing');
          expect(saved.lease!.filePath, lease.filePath);
          expect(await File(lease.filePath).length(), 0);
        } finally {
          db.close();
        }
      };
      final first = result(
        await service.agent.fetchInformationFile(session, input('one')),
      );
      files.beforeWrite = null;
      expect(await File(first['path'] as String).readAsBytes(), data);
      expect(
        result(
          await service.agent.fetchInformationFile(session, input('one')),
        )['path'],
        first['path'],
      );
      expect(files.writes, 1);
      final row = repo.informationFileDeliveries.single;
      expect(row.state, 'ready');
      expect(row.runtime, isTrue);
      expect(jsonEncode(row.toPrivateJson()), isNot(contains(session)));
      for (final file in Directory(
        '${root.path}/vault',
      ).listSync().whereType<File>()) {
        if (!file.path.endsWith('library.db') &&
            !file.path.endsWith('-wal') &&
            !file.path.endsWith('-journal') &&
            !file.path.endsWith('-shm')) {
          continue;
        }
        final disk = latin1.decode(await file.readAsBytes());
        expect(disk, isNot(contains('SYNTHETIC-DELIVERY-SQLCIPHER-39412')));
        expect(disk, isNot(contains(row.lease!.path)));
      }
    },
  );
  for (final boundary in ['registration', 'ready']) {
    test(
      '$boundary transaction failure publishes no path, retains ordered audit facts and never replays',
      () async {
        await approve();
        Future<void> fail(InformationDeliveryLease lease) async {
          final db = inspect();
          try {
            db.execute(
              boundary == 'registration'
                  ? '''CREATE TRIGGER reject_registration BEFORE UPDATE ON information_deliveries WHEN NEW.payload LIKE '%"lease":{%' BEGIN SELECT RAISE(FAIL,'synthetic registry failure'); END'''
                  : '''CREATE TRIGGER reject_ready BEFORE UPDATE ON information_deliveries WHEN NEW.payload LIKE '%"state":"ready"%' BEGIN SELECT RAISE(FAIL,'synthetic ready failure'); END''',
            );
          } finally {
            db.close();
          }
        }

        if (boundary == 'registration') {
          files.onReserve = fail;
        } else {
          files.onVerify = fail;
        }
        await expectLater(
          service.agent.fetchInformationFile(session, input('one')),
          fileFails('audit_failed'),
        );
        expect(files.writes, boundary == 'registration' ? 0 : 1);
        expect(await File(files.last!.filePath).exists(), isFalse);
        expect(repo.informationFileDeliveries.single.state, 'preparing');
        expect(service.owner.informationFileDeliveries.single.state, 'failed');
        final db = inspect();
        try {
          db.execute('DROP TRIGGER reject_$boundary');
        } finally {
          db.close();
        }
        files.onReserve = null;
        files.onVerify = null;
        await service.owner.retryAuditStorage();
        expect(repo.informationFileDeliveries.single.state, 'failed');
        expect(repo.informationFileDeliveries.single.lease, isNull);
        final receipt = result(
          await service.agent.fetchInformationFile(session, input('one')),
        );
        expect(receipt.containsKey('path'), isFalse);
        expect(receipt['state'], 'failed');
      },
    );
  }
  test(
    'encrypted updates reject changing immutable identities, replacing leases or resurrecting terminal records',
    () async {
      await approve();
      await service.agent.fetchInformationFile(session, input('one'));
      final saved = repo.informationFileDeliveries.single;
      for (final change in <Map<String, Object?>>[
        {'operationId': 'changed'},
        {'fieldVersion': saved.fieldVersion + 1},
        {'state': 'preparing'},
        {
          'lease': InformationDeliveryLease(
            saved.lease!.path,
            saved.lease!.directoryIdentity,
            saved.lease!.name,
            'other-file',
          ).toPrivateJson(),
        },
      ]) {
        await expectLater(
          repo.saveInformationFileDelivery(saved.changed(change)),
          throwsA(
            isA<StorageFailure>().having(
              (e) => e.code,
              'code',
              'delivery_conflict',
            ),
          ),
        );
      }
      await expectLater(
        repo.pruneInformationFileDeliveryHistory({saved.id}),
        throwsA(isA<StorageFailure>()),
      );
      await service.agent.releaseInformationFile(session, saved.id);
      await expectLater(
        repo.saveInformationFileDelivery(saved),
        throwsA(isA<StorageFailure>()),
      );
      expect(repo.informationFileDeliveries.single.state, 'released');
    },
  );
  test(
    'occupied native cleanup remains in encrypted registry through reopen and retries without writing again',
    () async {
      await approve();
      final delivered = result(
        await service.agent.fetchInformationFile(session, input('one')),
      );
      final reading = await File(delivered['path'] as String).open();
      try {
        expect(
          result(
            await service.agent.releaseInformationFile(
              session,
              delivered['deliveryId'] as String,
            ),
          )['state'],
          'cleanup_pending',
        );
        await service.close();
        await repo.close();
      } finally {
        await reading.close();
      }
      repo = await EncryptedInformationRepository.open(
        '${root.path}/vault',
        keys,
        clock: () => now,
      );
      files = _Files();
      service = InformationService(
        repository: repo,
        clock: () => now,
        informationDeliveryFiles: files,
      );
      expect(repo.informationFileDeliveries.single.state, 'cleanup_pending');
      await service.owner.reconcileInformationFileDeliveries();
      expect(repo.informationFileDeliveries.single.state, 'released');
      expect(repo.informationFileDeliveries.single.lease, isNull);
      expect(files.writes, 0);
      expect(await File(delivered['path'] as String).exists(), isFalse);
    },
  );
  test(
    'persisted orphan preparing fixture is classified unknown and cleaned after encrypted reopen without replay',
    () async {
      await service.close();
      final v = (await repo.informationAttachmentVersions(
        item.fields.single.attachment!.attachmentId,
      )).single;
      var orphan = InformationFileDelivery.preparing(
        id: 'orphan',
        sessionBinding: 'past-binding',
        operationId: 'past-op',
        requestId: 'past-request',
        grantId: 'past-grant',
        field: RecordedField(
          item.id,
          item.fields.single.id,
          item.name,
          item.fields.single.name,
        ),
        fieldVersion: 1,
        version: v,
        createdAt: now,
        expiresAt: now.add(const Duration(hours: 8)),
      );
      await repo.saveInformationFileDelivery(orphan);
      final lease = await files.reserve('attachment.pdf');
      orphan = orphan.changed({'lease': lease.toPrivateJson()});
      await repo.saveInformationFileDelivery(orphan);
      await files.write(lease, data);
      await repo.close();
      repo = await EncryptedInformationRepository.open(
        '${root.path}/vault',
        keys,
        clock: () => now,
      );
      files = _Files();
      service = InformationService(
        repository: repo,
        clock: () => now,
        informationDeliveryFiles: files,
      );
      await service.owner.reconcileInformationFileDeliveries();
      expect(repo.informationFileDeliveries.single.state, 'unknown');
      expect(repo.informationFileDeliveries.single.reason, 'restarted');
      expect(files.writes, 0);
      expect(await File(lease.filePath).exists(), isFalse);
    },
  );
  test(
    'format9 archives facts and original bytes without leases or associations and restores no execution capability',
    () async {
      await approve();
      final delivered = result(
        await service.agent.fetchInformationFile(session, input('one')),
      );
      final sourceRecord = repo.informationFileDeliveries.single;
      final key = await enableTestBackups(repo.backups),
          path = '${root.path}/archive.aimbackup';
      await service.owner.exportLibrary(() => repo.backups.exportTo(path));
      final reader = await AttachmentBackupContainer.openValidated(path, key);
      try {
        expect(reader.formatVersion, 9);
        final fact =
            jsonDecode(
                  reader.tables['information_deliveries']!.single['payload']
                      as String,
                )
                as Map;
        expect(fact.containsKey('lease'), isFalse);
        expect(fact.containsKey('runtime'), isFalse);
        expect(fact.containsKey('sessionBinding'), isFalse);
        expect(
          jsonEncode(reader.tables),
          isNot(contains(sourceRecord.lease!.path)),
        );
        expect(jsonEncode(reader.tables), isNot(contains(session)));
      } finally {
        reader.close();
      }
      final target = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        _Keys(),
        clock: () => now,
      );
      final targetFiles = _Files();
      final restoredService = InformationService(
        repository: target,
        clock: () => now,
        informationDeliveryFiles: targetFiles,
      );
      addTearDown(() async {
        await restoredService.close();
        await target.close();
      });
      final preview = await target.backups.inspect(path, key);
      expect(preview.formatVersion, 9);
      expect(preview.fileDeliveryCount, 1);
      await restoredService.owner.restoreLibrary(
        () => target.backups.restore(preview),
      );
      await restoredService.owner.reconcileInformationFileDeliveries();
      final fact = target.informationFileDeliveries.single;
      expect(fact.runtime, isFalse);
      expect(fact.lease, isNull);
      expect(fact.sessionBinding, isNull);
      expect(fact.restoredAt, now);
      expect(targetFiles.cleans, 0);
      expect(await File(delivered['path'] as String).exists(), isTrue);
      expect(
        await target.readInformationAttachmentChunk(
          item.fields.single.attachment!,
          0,
          data.length,
        ),
        data,
      );
      await expectLater(
        restoredService.agent.informationFileStatus(session, sourceRecord.id),
        fileFails('not_authorized'),
      );
    },
  );
  test(
    'authenticated format9 rejects private capabilities, duplicate nested keys and mismatched original/history references',
    () async {
      await approve();
      await service.agent.fetchInformationFile(session, input('one'));
      final other = await service.owner.createInformation('其他资料', '', [
        const FieldInput('其他字段', '', '文本'),
      ]);
      final key = await enableTestBackups(repo.backups),
          valid = '${root.path}/valid.aimbackup';
      await repo.backups.exportTo(valid);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        _Keys(),
        clock: () => now,
      );
      final targetService = InformationService(
        repository: target,
        clock: () => now,
      );
      addTearDown(() async {
        await targetService.close();
        await target.close();
      });
      await targetService.owner.setRequestLifetime(const Duration(minutes: 15));
      for (final scenario in [
        'lease',
        'binding',
        'runtime',
        'missing-original',
        'digest',
        'duplicate',
        'bad-state',
        'field-owner',
      ]) {
        final path = '${root.path}/$scenario.aimbackup';
        await File(valid).copy(path);
        mutate(path, key, (doc) {
          final row =
              (doc['tables']['information_deliveries'] as List).single as Map;
          final fact =
              jsonDecode(row['payload'] as String) as Map<String, dynamic>;
          switch (scenario) {
            case 'lease':
              fact['lease'] = null;
            case 'binding':
              fact['sessionBinding'] = 'forbidden';
            case 'runtime':
              fact['runtime'] = true;
            case 'missing-original':
              fact['attachment']['attachmentVersion'] = 999;
            case 'digest':
              fact['sha256'] = '0' * 64;
            case 'bad-state':
              fact['state'] = 'released';
            case 'field-owner':
              fact['field']['fieldId'] = other.fields.single.id;
            case 'duplicate':
              row['payload'] =
                  '{"id":"shadow",${(row['payload'] as String).substring(1)}';
              return;
          }
          row['payload'] = jsonEncode(fact);
        });
        await expectLater(
          target.backups.restoreFrom(path, key),
          throwsA(isA<StorageFailure>()),
          reason: scenario,
        );
        expect(await target.backups.recipientEmpty(), isTrue);
        expect(target.items, isEmpty);
        expect(
          targetService.owner.requestLifetime,
          const Duration(minutes: 15),
        );
      }
    },
  );
  test(
    'late format9 archive insert failure rolls back original BLOBs and all tables before retry',
    () async {
      await approve();
      await service.agent.fetchInformationFile(session, input('one'));
      final key = await enableTestBackups(repo.backups),
          path = '${root.path}/valid.aimbackup';
      await repo.backups.exportTo(path);
      final targetKeys = _Keys();
      final target = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        targetKeys,
        clock: () => now,
      );
      final targetService = InformationService(
        repository: target,
        clock: () => now,
      );
      addTearDown(() async {
        await targetService.close();
        await target.close();
      });
      await targetService.owner.setRequestLifetime(const Duration(minutes: 15));
      sqlite.Database recipient() {
        final db = sqlite.sqlite3.open('${root.path}/recipient/library.db');
        final hex = targetKeys.key!
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        db.execute('PRAGMA key = "x\'$hex\'"');
        return db;
      }

      var db = recipient();
      db.execute(
        "CREATE TRIGGER reject_restore BEFORE INSERT ON information_deliveries BEGIN SELECT RAISE(FAIL,'synthetic final archive insert failed'); END",
      );
      db.close();
      final preview = await target.backups.inspect(path, key);
      await expectLater(
        target.backups.restore(preview),
        throwsA(isA<StorageFailure>()),
      );
      expect(target.items, isEmpty);
      expect(target.informationFileDeliveries, isEmpty);
      expect(targetService.owner.requestLifetime, const Duration(minutes: 15));
      db = recipient();
      try {
        expect(
          db.select('SELECT * FROM information_attachment_versions'),
          isEmpty,
        );
        expect(db.select('SELECT * FROM grant_history'), isEmpty);
        db.execute('DROP TRIGGER reject_restore');
      } finally {
        db.close();
      }
      await targetService.owner.restoreLibrary(
        () => target.backups.restore(preview),
      );
      expect(target.items.length, 1);
      expect(target.informationFileDeliveries.single.runtime, isFalse);
    },
  );
  test(
    'history pruning retains active-session idempotency and drops only safe ended receipts',
    () async {
      await approve();
      final delivered = result(
        await service.agent.fetchInformationFile(session, input('one')),
      );
      await service.agent.releaseInformationFile(
        session,
        delivered['deliveryId'] as String,
      );
      now = now.add(const Duration(days: 91));
      await service.owner.reconcileInformationFileDeliveries();
      expect(repo.informationFileDeliveries.length, 1);
      service.agent.endSession(session);
      await service.owner.reconcileInformationFileDeliveries();
      expect(repo.informationFileDeliveries, isEmpty);
    },
  );
  test(
    'schema20 upgrade preserves file originals and refuses a conflicting new registry table atomically',
    () async {
      await service.close();
      await repo.close();
      var db = inspect();
      db.execute('DROP TABLE information_deliveries');
      db.execute('UPDATE library_format SET version=20');
      db.execute('PRAGMA user_version=10');
      db.close();
      repo = await EncryptedInformationRepository.open(
        '${root.path}/vault',
        keys,
        clock: () => now,
      );
      service = InformationService(
        repository: repo,
        clock: () => now,
        informationDeliveryFiles: files,
      );
      expect(
        await repo.readInformationAttachmentChunk(
          item.fields.single.attachment!,
          0,
          data.length,
        ),
        data,
      );
      await service.close();
      await repo.close();
      db = inspect();
      expect(db.select('PRAGMA user_version').single.values.single, 21);
      db.execute('UPDATE library_format SET version=20');
      db.execute('PRAGMA user_version=10');
      db.close();
      await expectLater(
        EncryptedInformationRepository.open('${root.path}/vault', keys),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'unsupported_schema',
          ),
        ),
      );
      db = inspect();
      try {
        expect(db.select('PRAGMA user_version').single.values.single, 10);
        expect(
          db.select('SELECT version FROM library_format').single['version'],
          20,
        );
      } finally {
        db.close();
      }
    },
  );
}
