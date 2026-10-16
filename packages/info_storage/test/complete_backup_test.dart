import 'backup_setup.dart';
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
    'clock rollback never makes legitimate grant history unexportable or restores live authority',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'backup-clock-rollback-',
      );
      addTearDown(() => root.delete(recursive: true));
      final approvedAt = DateTime.utc(2026, 10, 16, 12);
      var now = approvedAt;
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        _Keys(),
        clock: () => now,
      );
      addTearDown(source.close);
      final service = InformationService(repository: source, clock: () => now);
      addTearDown(service.close);
      final item = await service.owner.createInformation('Server', '', [
        const FieldInput('Host', '', 'host.invalid'),
      ]);
      final ref = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('reader');
      final request = service.agent.request(session, 'host', [ref]);
      service.owner.approve(request.id, [ref]);
      final token = service.agent.claim(session, request.id).token;
      await service.agent.read(token, ref);
      final key = await enableTestBackups(source.backups);
      await service.owner.exportLibrary(
        () => source.backups.exportTo('${root.path}/before.aimbackup'),
      );
      now = approvedAt.subtract(const Duration(hours: 1));
      await service.owner.exportLibrary(
        () => source.backups.exportTo('${root.path}/rolled-back.aimbackup'),
      );
      service.owner.revoke(request.id);
      now = approvedAt.add(const Duration(hours: 1));
      await service.owner.exportLibrary(
        () => source.backups.exportTo('${root.path}/revoked.aimbackup'),
      );
      for (final name in ['rolled-back', 'revoked']) {
        final target = await EncryptedInformationRepository.open(
          '${root.path}/target-$name',
          _Keys(),
          clock: () => now,
        );
        addTearDown(target.close);
        final restored = InformationService(
          repository: target,
          clock: () => now,
        );
        addTearDown(restored.close);
        await restored.owner.restoreLibrary(
          () => target.backups.restoreFrom('${root.path}/$name.aimbackup', key),
        );
        final history = (await restored.owner.history()).grants.single;
        expect(history.active, isFalse);
        expect(history.approvedAt, approvedAt);
        if (name == 'revoked') {
          expect(history.events.last.kind, GrantEventKind.revoked);
          expect(
            history.events.last.at,
            approvedAt.subtract(const Duration(hours: 1)),
          );
        }
        await expectLater(
          restored.agent.read(token, ref),
          throwsA(isA<AccessFailure>()),
        );
      }
    },
  );

  test(
    'format 3 preserves original information times through complete restore and rejects malformed dates atomically',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'backup-information-time-',
      );
      addTearDown(() => root.delete(recursive: true));
      final created = DateTime.utc(2026, 10, 16, 12);
      var now = created;
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        _Keys(),
        clock: () => now,
      );
      addTearDown(source.close);
      final service = InformationService(repository: source, clock: () => now);
      addTearDown(service.close);
      final item = await service.owner.createInformation('Item', '', [
        const FieldInput('Value', '', 'before'),
      ]);
      now = created.subtract(const Duration(hours: 1));
      await service.owner.correctValue(
        FieldRef(item.id, item.fields.single.id),
        'after',
      );
      final key = await enableTestBackups(source.backups);
      final path = '${root.path}/times.aimbackup';
      await service.owner.exportLibrary(() => source.backups.exportTo(path));
      expect(_payload(path, key)['version'], 4);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
        clock: () => created.add(const Duration(days: 1)),
      );
      addTearDown(target.close);
      await _rewrite(path, '${root.path}/bad-time.aimbackup', key, (p) {
        p['tables']['information_items'][0]['modified_at'] =
            '2026-02-30T00:00:00.000Z';
      });
      await expectLater(
        target.backups.restoreFrom('${root.path}/bad-time.aimbackup', key),
        throwsA(isA<StorageFailure>()),
      );
      expect(target.items, isEmpty);
      await target.backups.restoreFrom(path, key);
      expect(target.items.single.createdAt, created);
      expect(target.items.single.modifiedAt, now);
      expect(target.informationRevisions.single.item.createdAt, created);
      expect(target.informationRevisions.single.item.modifiedAt, created);
    },
  );

  for (final operation in ['replace', 'rollback']) {
    test(
      'complete backup preserves grouped recycle fields from $operation',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'backup-recycle-$operation-',
        );
        addTearDown(() => root.delete(recursive: true));
        final source = await EncryptedInformationRepository.open(
          '${root.path}/source',
          _Keys(),
        );
        addTearDown(source.close);
        final service = InformationService(repository: source);
        addTearDown(service.close);
        final initial = await service.owner.createInformation('Server', '', [
          const FieldInput('Keep', '', 'keep'),
        ]);
        final session = service.agent.openSession('editor');
        final addition = await service.agent.submitUpdate(
          session,
          UpdateInput(initial.id, 1, const [
            FieldChange.add(FieldInput('First', '', 'first value')),
            FieldChange.add(
              FieldInput(
                'Second',
                '',
                'second value',
                kind: FieldKind.textNote,
              ),
            ),
          ]),
        );
        await service.owner.confirmUpdate(addition, 1);
        final fields = service.owner.information.single.fields.skip(1).toList();
        final refs = fields.map((f) => FieldRef(initial.id, f.id)).toList();
        final request = service.agent.request(session, 'before removal', refs);
        service.owner.approve(request.id, refs);
        final oldToken = service.agent.claim(session, request.id).token;
        if (operation == 'replace') {
          final replacement = await service.agent.submitUpdate(
            session,
            UpdateInput(initial.id, 2, [
              for (final field in fields)
                FieldChange.replace(
                  field.id,
                  FieldInput('New ${field.name}', '', 'new meaning'),
                ),
            ]),
          );
          await service.owner.confirmUpdate(replacement, 1);
        } else {
          await service.owner.restoreRevision(initial.id, 1, 2);
        }
        final entry = service.owner.recycleEntries.single;
        expect(entry.snapshot!.fields, hasLength(2));
        final key = await enableTestBackups(source.backups);
        final path = '${root.path}/saved.aimbackup';
        await service.owner.exportLibrary(() => source.backups.exportTo(path));
        await service.owner.restoreRecycled(entry.id);
        for (final ref in refs) {
          await expectLater(
            service.agent.read(oldToken, ref),
            throwsA(isA<AccessFailure>()),
          );
        }
        final target = await EncryptedInformationRepository.open(
          '${root.path}/target',
          _Keys(),
        );
        addTearDown(target.close);
        final restored = InformationService(repository: target);
        addTearDown(restored.close);
        await restored.owner.restoreLibrary(
          () => target.backups.restoreFrom(path, key),
        );
        final recovered = await restored.owner.restoreRecycled(entry.id);
        for (final field in fields) {
          final provenance = restored.owner.recycleFacts
              .firstWhere(
                (f) =>
                    f.entryId == entry.id && f.kind == RecycleFactKind.restored,
              )
              .restoredFieldIds;
          final saved = recovered.fields.singleWhere(
            (f) => f.id == provenance[field.id],
          );
          expect(saved.id, isNot(field.id));
          expect(saved.value, field.value);
          expect(saved.kind, field.kind);
          expect(saved.version, greaterThan(field.version));
          await expectLater(
            restored.agent.read(oldToken, FieldRef(initial.id, field.id)),
            throwsA(isA<AccessFailure>()),
          );
        }
      },
    );
  }

  test(
    'complete backup roundtrips grouped removed fields and zero-field whole-item metadata',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'backup-grouped-recycle-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        _Keys(),
      );
      addTearDown(source.close);
      final service = InformationService(repository: source);
      addTearDown(service.close);
      final item = await service.owner.createInformation('Server', '', [
        const FieldInput('Host', '', 'host.invalid'),
        const FieldInput('User', '', 'fictional user'),
        const FieldInput('Note', '', 'keep', kind: FieldKind.textNote),
      ]);
      final refs = item.fields.map((f) => FieldRef(item.id, f.id)).toList();
      final session = service.agent.openSession('editor');
      final request = service.agent.request(session, 'old fields', refs);
      service.owner.approve(request.id, refs);
      final token = service.agent.claim(session, request.id).token;
      final proposal = await service.agent.submitUpdate(
        session,
        UpdateInput(
          item.id,
          1,
          refs.take(2).map((f) => FieldChange.remove(f.fieldId)).toList(),
        ),
      );
      await service.owner.confirmUpdate(proposal, 1);
      final grouped = service.owner.recycleEntries.single;
      expect(grouped.snapshot!.fields, hasLength(2));
      final metadata = await service.owner.createInformation(
        'Metadata only',
        'preserve',
        [const FieldInput('Temporary', '', 'private')],
      );
      await service.owner.deleteInformation(
        metadata.id,
        1,
        fieldId: metadata.fields.single.id,
      );
      final whole = await service.owner.deleteInformation(metadata.id, 2);
      expect(whole.snapshot!.fields, isEmpty);
      final key = await enableTestBackups(source.backups);
      final path = '${root.path}/grouped.aimbackup';
      await service.owner.exportLibrary(() => source.backups.exportTo(path));

      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
      );
      addTearDown(target.close);
      final restored = InformationService(repository: target);
      addTearDown(restored.close);
      await restored.owner.restoreLibrary(
        () => target.backups.restoreFrom(path, key),
      );
      final recovered = await restored.owner.restoreRecycled(grouped.id);
      expect(recovered.fields, hasLength(3));
      expect(recovered.fields.any((f) => f.id == refs.last.fieldId), isTrue);
      expect(
        recovered.fields.any((f) => refs.take(2).any((r) => r.fieldId == f.id)),
        isFalse,
      );
      expect(recovered.fields.map((f) => f.value).toSet(), {
        'host.invalid',
        'fictional user',
        'keep',
      });
      final empty = await restored.owner.restoreRecycled(whole.id);
      expect(empty.fields, isEmpty);
      expect(empty.description, 'preserve');
      for (final ref in refs.take(2)) {
        await expectLater(
          restored.agent.read(token, ref),
          throwsA(isA<AccessFailure>()),
        );
      }
      await service.owner.restoreRecycled(grouped.id);
      for (final ref in refs.take(2)) {
        await expectLater(
          service.agent.read(token, ref),
          throwsA(isA<AccessFailure>()),
        );
      }
      final freshSession = restored.agent.openSession('new read');
      final mapping = restored.owner.recycleFacts
          .firstWhere(
            (f) =>
                f.entryId == grouped.id && f.kind == RecycleFactKind.restored,
          )
          .restoredFieldIds;
      final freshRefs = refs
          .take(2)
          .map((f) => FieldRef(item.id, mapping[f.fieldId]!))
          .toList();
      final fresh = restored.agent.request(
        freshSession,
        'recovered fields',
        freshRefs,
      );
      restored.owner.approve(fresh.id, freshRefs);
      expect(
        await restored.agent.read(
          restored.agent.claim(freshSession, fresh.id).token,
          freshRefs.first,
        ),
        'host.invalid',
      );
    },
  );

  test(
    'each audit retention setting keeps its exact boundary and expires it on later restore',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'backup-audit-settings-',
      );
      addTearDown(() => root.delete(recursive: true));
      var now = DateTime.utc(2026, 10, 16, 12);
      for (final days in [30, 90, 180, 365]) {
        final source = await EncryptedInformationRepository.open(
          '${root.path}/source-$days',
          _Keys(),
          clock: () => now,
        );
        final service = InformationService(
          repository: source,
          clock: () => now,
        );
        final preview = await service.owner.previewAuditRetention(days);
        await service.owner.setAuditRetention(days, confirmation: preview);
        final cutoff = now.subtract(Duration(days: days));
        await source.saveAccessRecord(
          AccessRecord(
            id: 'exact-boundary',
            at: cutoff,
            outcome: AccessOutcome.unauthorized,
            grantId: 'already-pruned-grant',
          ),
        );
        await source.saveAccessRecord(
          AccessRecord(
            id: 'too-old',
            at: cutoff.subtract(const Duration(milliseconds: 1)),
            outcome: AccessOutcome.unauthorized,
          ),
        );
        await source.saveAccessRecord(
          AccessRecord(
            id: 'recent',
            at: now,
            outcome: AccessOutcome.unauthorized,
          ),
        );
        final key = await enableTestBackups(source.backups);
        final path = '${root.path}/audit-$days.aimbackup';
        await source.backups.exportTo(path);
        final target = await EncryptedInformationRepository.open(
          '${root.path}/target-$days',
          _Keys(),
          clock: () => now,
        );
        final snapshot = await target.backups.inspect(path, key);
        expect(snapshot.accessRecordCount, 2, reason: '$days days');
        now = now.add(const Duration(milliseconds: 1));
        final result = await target.backups.restore(snapshot);
        expect(result.accessRecordCount, 1, reason: '$days days');
        expect(target.accessRecords.single.id, 'recent');
        expect(target.readSetting('auditRetentionDays'), days);
        await target.close();
        await service.close();
        await source.close();
      }
    },
  );

  for (final legacyVersion in [1, 2]) {
    test(
      'legacy format $legacyVersion restores unknown dates without inventing history or credentials',
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
        final key = await enableTestBackups(source.backups);
        final path = '${root.path}/v3.aimbackup';
        await source.backups.exportTo(path);
        await _rewrite(path, '${root.path}/v1.aimbackup', key, (p) {
          p['version'] = legacyVersion;
          (p['tables'] as Map).remove('request_history');
          for (final row in p['tables']['information_items'] as List) {
            (row as Map).remove('created_at');
            row.remove('modified_at');
          }
          for (final row in p['tables']['information_revisions'] as List) {
            final old = jsonDecode(row['payload'] as String) as Map;
            old.remove('createdAt');
            old.remove('modifiedAt');
            row['payload'] = jsonEncode(old);
          }
          if (legacyVersion == 1)
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
        expect(preview.formatVersion, legacyVersion);
        expect(preview.revisionCount, legacyVersion == 1 ? 0 : 1);
        expect(preview.recycleCount, 0);
        expect(preview.grantHistoryCount, 0);
        expect(target.items.single.id, item.id);
        expect(target.items.single.version, 2);
        expect(target.items.single.fields.single.value, 'current value');
        expect(target.items.single.createdAt, isNull);
        expect(target.items.single.modifiedAt, isNull);
        if (legacyVersion == 2) {
          expect(target.informationRevisions.single.item.createdAt, isNull);
          expect(target.informationRevisions.single.item.modifiedAt, isNull);
        }
        expect(target.revisionPurgeFacts, isEmpty);
        await target.close();
        await service.close();
        await source.close();
      },
    );
  }

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
      final key = await enableTestBackups(source.backups);
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
          p['version'] = 999;
        },
        (p) {
          p['tables']['information_items'][0]['created_at'] = 123;
        },
        (p) {
          nested(p, 'information_revisions', (j) {
            j['modifiedAt'] = 'not-a-date';
          });
        },
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
            j['wholeItem'] = false;
            j['snapshot']['fields'] = [];
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
      final key = await enableTestBackups(source.backups);
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
      final opened = service.agent.openSessionWithEndCapability('Source chat');
      final session = opened.sessionSecret;
      final request = service.agent.request(session, 'fictional read', [ref]);
      service.owner.approve(request.id, [ref]);
      final token = service.agent.claim(session, request.id).token;
      expect(await service.agent.read(token, ref), 'new.invalid');
      await expectLater(
        service.agent.read('unknown-token', ref),
        throwsA(isA<AccessFailure>()),
      );
      final firstNoteDeletion = await service.owner.deleteInformation(
        item.id,
        3,
        fieldId: item.fields.last.id,
      );
      final firstRestored = await service.owner.restoreRecycled(
        firstNoteDeletion.id,
      );
      final noteDeletion = await service.owner.deleteInformation(
        item.id,
        5,
        fieldId: firstRestored.fields.last.id,
      );
      final revokedSession = service.agent.openSession('Revoked source chat');
      final revoked = service.agent.request(revokedSession, 'read', [ref]);
      service.owner.approve(revoked.id, [ref]);
      service.owner.revoke(revoked.id);
      final endedSession = service.agent.openSession('Ended source chat');
      final ended = service.agent.request(endedSession, 'read', [ref]);
      service.owner.approve(ended.id, [ref]);
      service.agent.endSession(endedSession);
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
      final key = await enableTestBackups(source.backups);
      final path = '${root.path}/complete.aimbackup';
      await source.backups.exportTo(path);
      final payload = _payload(path, key);
      expect(payload['version'], 4);
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
        'request_history',
      });
      final encoded = jsonEncode(payload);
      for (final excluded in [
        session,
        token,
        opened.endCapability,
        revokedSession,
        endedSession,
        key,
        'EXCLUDED-PENDING-123',
      ]) {
        expect(encoded, isNot(contains(excluded)));
      }
      final recipientKeys = _Keys();
      var recipient = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        recipientKeys,
      );
      final summary = await recipient.backups.restoreFrom(path, key);
      expect(summary.revisionCount, 6);
      expect(summary.recycleCount, 2);
      expect(summary.grantHistoryCount, 3);
      expect(summary.accessRecordCount, 2);
      var restored = InformationService(repository: recipient);
      expect(restored.owner.information.single.id, item.id);
      expect(restored.owner.information.single.version, 6);
      expect(restored.owner.information.single.directoryId, child.id);
      expect(restored.owner.information.single.tagIds, [tag.id]);
      final audit = await restored.owner.history();
      expect(
        audit.grants.every((g) => !g.active && g.restoredAt != null),
        isTrue,
      );
      expect(audit.grants.first.events.single.kind, GrantEventKind.approved);
      expect(
        audit.grants
            .where((g) => g.events.last.kind == GrantEventKind.revoked)
            .length,
        1,
      );
      expect(
        audit.grants
            .where((g) => g.events.last.kind == GrantEventKind.ended)
            .length,
        1,
      );
      await expectLater(
        restored.owner.revokeFromHistory(audit.grants.first.id),
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
      expect(recipient.informationRevisions.length, 6);
      expect(recipient.recycleFacts.length, 5);
      expect(
        (await restored.owner.history()).grants.every((g) => !g.active),
        isTrue,
      );
      final withNote = await restored.owner.restoreRecycled(noteDeletion.id);
      expect(withNote.version, 7);
      expect(withNote.fields.last.id, isNot(item.fields.last.id));
      expect(withNote.fields.last.id, isNot(firstRestored.fields.last.id));
      expect(withNote.fields.last.version, 3);
      expect(withNote.fields.last.kind, FieldKind.textNote);
      await restored.close();
      await recipient.close();
      await service.close();
      await source.close();
    },
  );
}
