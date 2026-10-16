import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

Map<String, dynamic> _payload(String path, String key) {
  final db = sqlite3.open(path);
  try {
    final hex = base64Url
        .decode(key.substring('aim-recovery-v1:'.length))
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return jsonDecode(
          db.select('SELECT payload FROM backup_snapshot').single['payload']
              as String,
        )
        as Map<String, dynamic>;
  } finally {
    db.close();
  }
}

Future<void> _rewrite(
  String source,
  String target,
  String key,
  void Function(Map<String, dynamic>) change,
) async {
  await File(source).copy(target);
  final payload = _payload(target, key);
  change(payload);
  final db = sqlite3.open(target);
  try {
    final hex = base64Url
        .decode(key.substring('aim-recovery-v1:'.length))
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    db.execute('UPDATE backup_snapshot SET payload=?', [jsonEncode(payload)]);
  } finally {
    db.close();
  }
}

void main() {
  test(
    'original current-data format upgrades without inventing history or credentials',
    () async {
      final root = await Directory.systemTemp.createTemp('backup-v1-');
      addTearDown(() => root.delete(recursive: true));
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        _Keys(),
      );
      final service = InformationService(repository: source);
      final item = await service.owner.createInformation('Legacy item', '', [
        const FieldInput('Value', '', 'legacy value'),
      ]);
      await service.owner.correctValue(
        FieldRef(item.id, item.fields.single.id),
        'current value',
      );
      final key = await source.backups.enable();
      final path = '${root.path}/v2.aimbackup';
      await source.backups.exportTo(path);
      await _rewrite(path, '${root.path}/v1.aimbackup', key, (p) {
        p['version'] = 1;
        for (final t in [
          'information_revisions',
          'recycle_entries',
          'recycle_facts',
          'revision_purge_facts',
          'grant_history',
          'access_records',
        ]) {
          (p['tables'] as Map).remove(t);
        }
      });
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
      );
      final preview = await target.backups.restoreFrom(
        '${root.path}/v1.aimbackup',
        key,
      );
      expect(preview.formatVersion, 1);
      expect(preview.revisionCount, 0);
      expect(preview.recycleCount, 0);
      expect(preview.grantHistoryCount, 0);
      expect(target.items.single.id, item.id);
      expect(target.items.single.version, 2);
      expect(target.items.single.fields.single.value, 'current value');
      expect(target.revisionPurgeFacts, isEmpty);
      await target.close();
      await service.close();
      await source.close();
    },
  );

  test(
    'authenticated hostile history payloads fail before changing recipient preferences',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'backup-hostile-history-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        _Keys(),
      );
      final service = InformationService(repository: source);
      final item = await service.owner.createInformation('Source', '', [
        const FieldInput('Value', '', 'before'),
      ]);
      final ref = FieldRef(item.id, item.fields.single.id);
      await service.owner.correctValue(ref, 'after');
      final deleted = await service.owner.createInformation('Deleted', '', [
        const FieldInput('Value', '', 'recoverable'),
      ]);
      await service.owner.deleteInformation(deleted.id, 1);
      final session = service.agent.openSession('chat');
      final request = service.agent.request(session, 'read', [ref]);
      service.owner.approve(request.id, [ref]);
      await service.agent.read(
        service.agent.claim(session, request.id).token,
        ref,
      );
      final key = await source.backups.enable();
      final path = '${root.path}/good.aimbackup';
      await source.backups.exportTo(path);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
      );
      final owner = InformationService(repository: target).owner;
      await owner.setRequestLifetime(const Duration(minutes: 17));
      Map<String, dynamic> nested(
        Map<String, dynamic> p,
        String table,
        void Function(Map<String, dynamic>) mutate,
      ) {
        final row = (p['tables'][table] as List).first as Map<String, dynamic>;
        final j = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        mutate(j);
        row['payload'] = jsonEncode(j);
        return row;
      }

      final changes = <void Function(Map<String, dynamic>)>[
        (p) {
          (p['tables']['information_revisions'] as List).add(
            (p['tables']['information_revisions'] as List).first,
          );
        },
        (p) {
          nested(p, 'information_revisions', (j) {
            j['id'] = 'mismatched-item';
          });
        },
        (p) {
          nested(p, 'information_revisions', (j) {
            j['fields'] = List.filled(201, (j['fields'] as List).single);
          });
        },
        (p) {
          nested(p, 'information_revisions', (j) {
            j['fields'][0]['kind'] = 'future-kind';
          });
        },
        (p) {
          nested(p, 'information_revisions', (j) {
            j['sessionSecret'] = 'injected';
          });
        },
        (p) {
          nested(p, 'recycle_entries', (j) {
            j['state'] = 'restored';
          });
        },
        (p) {
          nested(p, 'recycle_entries', (j) {
            j['expiresAt'] = '999999999999999999';
          });
        },
        (p) {
          nested(p, 'recycle_entries', (j) {
            j['snapshot']['fields'][0]['id'] = item.fields.single.id;
          });
        },
        (p) {
          nested(p, 'grant_history', (j) {
            j['events'][0]['kind'] = 'revoked';
          });
        },
        (p) {
          nested(p, 'grant_history', (j) {
            j['approvedAt'] = DateTime.utc(2025).toIso8601String();
          });
        },
        (p) {
          nested(p, 'access_records', (j) {
            j['operation'] = 'write';
          });
        },
        (p) {
          nested(p, 'access_records', (j) {
            j['token'] = 'injected';
          });
        },
        (p) {
          p['tables']['access_records'][0]['recorded_at'] = 0;
        },
        (p) {
          p['tables']['new_credentials'] = [];
        },
      ];
      for (var index = 0; index < changes.length; index++) {
        final bad = '${root.path}/bad-$index.aimbackup';
        await _rewrite(path, bad, key, changes[index]);
        await expectLater(
          target.backups.restoreFrom(bad, key),
          throwsA(isA<StorageFailure>()),
          reason: 'case $index',
        );
        expect(owner.information, isEmpty, reason: 'case $index');
        expect(target.recycleEntries, isEmpty);
        expect(target.informationRevisions, isEmpty);
        expect(target.grantHistory, isEmpty);
        expect(owner.requestLifetime, const Duration(minutes: 17));
      }
      await target.close();
      await service.close();
      await source.close();
    },
  );

  test(
    'retention applies at export and delayed restore without renewing content lifetimes',
    () async {
      final root = await Directory.systemTemp.createTemp('backup-retention-');
      addTearDown(() => root.delete(recursive: true));
      final exportAt = DateTime.utc(2026, 10, 16, 12);
      var now = exportAt.subtract(const Duration(days: 31));
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        _Keys(),
        clock: () => now,
      );
      final service = InformationService(repository: source, clock: () => now);
      final older = await service.owner.createInformation('Older', '', [
        const FieldInput('Value', '', 'EXPIRED-REVISION-CONTENT'),
      ]);
      await service.owner.correctValue(
        FieldRef(older.id, older.fields.single.id),
        'current old item',
      );
      final expiredRecycle = await service.owner.createInformation(
        'Expired deletion',
        '',
        [const FieldInput('Value', '', 'EXPIRED-RECYCLE-CONTENT')],
      );
      await service.owner.deleteInformation(expiredRecycle.id, 1);
      now = exportAt.subtract(const Duration(days: 30));
      final boundary = await service.owner.createInformation('Boundary', '', [
        const FieldInput('Value', '', 'EXACT-THIRTY-DAY-OLD'),
      ]);
      await service.owner.correctValue(
        FieldRef(boundary.id, boundary.fields.single.id),
        'current boundary',
      );
      now = exportAt.subtract(const Duration(days: 29));
      final recent = await service.owner.createInformation('Recent', '', [
        const FieldInput('Value', '', 'RECENT-REVISION-CONTENT'),
      ]);
      await service.owner.correctValue(
        FieldRef(recent.id, recent.fields.single.id),
        'current recent',
      );
      final recentRecycle = await service.owner.createInformation(
        'Recent deletion',
        '',
        [const FieldInput('Value', '', 'RECENT-RECYCLE-CONTENT')],
      );
      await service.owner.deleteInformation(recentRecycle.id, 1);
      now = exportAt;
      await service.owner.retryAuditStorage();
      final oldApproval = exportAt.subtract(const Duration(days: 91));
      await source.saveGrantHistory(
        GrantHistory(
          id: 'old-grant',
          requestId: 'old-request',
          sessionId: 'public-history-id',
          chatLabel: 'old',
          approvedAt: oldApproval,
          expiresAt: oldApproval.add(const Duration(hours: 8)),
          fields: [
            RecordedField(older.id, older.fields.single.id, 'Older', 'Value'),
          ],
          events: [
            GrantEvent(GrantEventKind.approved, oldApproval),
            GrantEvent(
              GrantEventKind.revoked,
              oldApproval.add(const Duration(hours: 1)),
            ),
          ],
        ),
      );
      await source.saveAccessRecord(
        AccessRecord(
          id: 'later-denial',
          at: exportAt.subtract(const Duration(days: 1)),
          outcome: AccessOutcome.unauthorized,
          grantId: 'old-grant',
          itemId: older.id,
          fieldId: older.fields.single.id,
        ),
      );
      await source.saveAccessRecord(
        AccessRecord(
          id: 'expired-audit',
          at: oldApproval,
          outcome: AccessOutcome.unauthorized,
        ),
      );
      final key = await source.backups.enable();
      final path = '${root.path}/retention.aimbackup';
      await source.backups.exportTo(path);
      final before = File(path).readAsBytesSync();
      final encoded = jsonEncode(_payload(path, key));
      for (final excluded in [
        'EXPIRED-REVISION-CONTENT',
        'EXPIRED-RECYCLE-CONTENT',
        'EXACT-THIRTY-DAY-OLD',
      ]) {
        expect(encoded, isNot(contains(excluded)));
      }
      expect(encoded, contains('RECENT-REVISION-CONTENT'));
      expect(encoded, contains('RECENT-RECYCLE-CONTENT'));
      expect(encoded, isNot(contains('expired-audit')));
      final recipient = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        _Keys(),
        clock: () => now,
      );
      var preview = await recipient.backups.inspect(path, key);
      expect(
        preview.revisionCount,
        2,
      ); // correction plus the recent whole-item deletion
      expect(preview.recycleCount, 1);
      expect(preview.grantHistoryCount, 0);
      expect(preview.accessRecordCount, 1);
      now = exportAt.add(const Duration(days: 2));
      preview = await recipient.backups.restore(preview);
      expect(preview.revisionCount, 0);
      expect(preview.recycleCount, 0);
      expect(recipient.revisionPurgeFacts.length, 5);
      expect(recipient.recycleEntries.every((e) => e.snapshot == null), isTrue);
      expect(recipient.accessRecords.single.grantId, 'old-grant');
      expect(recipient.items.length, 3);
      expect(File(path).readAsBytesSync(), before);
      await recipient.close();
      await service.close();
      await source.close();
    },
  );

  test(
    'complete backup preserves retained versions, recycle and past audit without live capabilities',
    () async {
      final root = await Directory.systemTemp.createTemp('complete-backup-');
      addTearDown(() => root.delete(recursive: true));
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        _Keys(),
      );
      final service = InformationService(repository: source);
      final parent = await service.owner.createDirectory('Parent');
      final child = await service.owner.createDirectory(
        'Child',
        parentId: parent.id,
      );
      final tag = await service.owner.createTag('tag');
      await service.owner.createTemplate('Template', 'description', [
        const TemplateFieldInput('Note', '', kind: FieldKind.textNote),
      ]);
      final item = await service.owner
          .createInformation('Kept', 'description', [
            const FieldInput('Address', '', 'old.invalid'),
            const FieldInput(
              'Note',
              '',
              'fictional note',
              kind: FieldKind.textNote,
            ),
          ]);
      await service.owner.organizeInformation(
        item.id,
        directoryId: child.id,
        tagIds: [tag.id],
      );
      final ref = FieldRef(item.id, item.fields.first.id);
      await service.owner.correctValue(ref, 'new.invalid');
      final session = service.agent.openSession('Source chat');
      final request = service.agent.request(session, 'fictional read', [ref]);
      service.owner.approve(request.id, [ref]);
      final token = service.agent.claim(session, request.id).token;
      expect(await service.agent.read(token, ref), 'new.invalid');
      await expectLater(
        service.agent.read('unknown-token', ref),
        throwsA(isA<AccessFailure>()),
      );
      final deleted = await service.owner.createInformation('Deleted', '', [
        const FieldInput('Value', '', 'recoverable fictional content'),
      ]);
      final entry = await service.owner.deleteInformation(
        deleted.id,
        deleted.version,
      );
      await service.agent.submitImport(session, [
        ImportItemInput('Pending secret', '', [
          const FieldInput('Value', '', 'EXCLUDED-PENDING-123'),
        ]),
      ]);
      service.agent.request(session, 'pending request', [ref]);
      await service.owner.retryAuditStorage();
      final key = await source.backups.enable();
      final path = '${root.path}/complete.aimbackup';
      await source.backups.exportTo(path);
      final payload = _payload(path, key);
      expect(payload['version'], 2);
      final tables = payload['tables'] as Map<String, dynamic>;
      expect(tables.keys.toSet(), {
        'information_directories',
        'information_tags',
        'field_templates',
        'information_items',
        'information_fields',
        'information_item_tags',
        'settings',
        'information_revisions',
        'recycle_entries',
        'recycle_facts',
        'revision_purge_facts',
        'grant_history',
        'access_records',
      });
      final encoded = jsonEncode(payload);
      for (final excluded in [session, token, key, 'EXCLUDED-PENDING-123']) {
        expect(encoded, isNot(contains(excluded)));
      }
      final recipientKeys = _Keys();
      var recipient = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        recipientKeys,
      );
      final summary = await recipient.backups.restoreFrom(path, key);
      expect(summary.revisionCount, 3);
      expect(summary.recycleCount, 1);
      expect(summary.grantHistoryCount, 1);
      expect(summary.accessRecordCount, 2);
      var restored = InformationService(repository: recipient);
      expect(restored.owner.information.single.id, item.id);
      expect(restored.owner.information.single.version, 3);
      expect(restored.owner.information.single.directoryId, child.id);
      expect(restored.owner.information.single.tagIds, [tag.id]);
      final audit = await restored.owner.history();
      expect(audit.grants.single.active, isFalse);
      expect(audit.grants.single.restoredAt, isNotNull);
      expect(audit.grants.single.events.single.kind, GrantEventKind.approved);
      await expectLater(
        restored.owner.revokeFromHistory(audit.grants.single.id),
        throwsA(isA<AccessFailure>()),
      );
      expect(restored.owner.requests, isEmpty);
      expect(restored.owner.importProposals, isEmpty);
      await expectLater(
        restored.agent.read(token, ref),
        throwsA(isA<AccessFailure>()),
      );
      final recovered = await restored.owner.restoreRecycled(entry.id);
      expect(recovered.id, deleted.id);
      expect(recovered.version, 3);
      await restored.close();
      await recipient.close();
      recipient = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        recipientKeys,
      );
      restored = InformationService(repository: recipient);
      expect(recipient.informationRevisions.length, 3);
      expect(recipient.recycleFacts.length, 2);
      expect((await restored.owner.history()).grants.single.active, isFalse);
      await restored.close();
      await recipient.close();
      await service.close();
      await source.close();
    },
  );
}
