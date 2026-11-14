part of 'info_storage.dart';

// Content-triggered: ordinary synchronized libraries keep format 26. Only
// retained credential delivery/batch/program facts require a newer reader.
bool _hasCredentialDeliveryRows(Iterable<Map<String, Object?>> rows) =>
    rows.any((row) {
      final request = CredentialUseRequest.fromJson(_backupJson(row));
      return request.isReveal ||
          request.isCommand && request.plan.isProgramReceiver;
    });
int _syncContentFormat(Map tables) {
  final batches = tables['credential_batches'] as List? ?? const [];
  if (batches.any(
        (r) =>
            _storedBatch(Map<String, Object?>.from(r as Map)).items
                .any((i) => i.destination.ssh != null),
      ) ||
      (tables['credential_batch_operations'] as List? ?? const []).any(
        (r) =>
            _storedBatchOperation(Map<String, Object?>.from(r as Map))
                .sshContext !=
            null,
      )) {
    return 32;
  }
  if (batches.any(
    (r) =>
        _storedBatch(Map<String, Object?>.from(r as Map)).items
            .any((i) => i.destination.native != null),
  )) {
    return 30;
  }
  if ((tables['credential_program_operations'] as List? ?? const [])
          .isNotEmpty ||
      batches.any(
        (r) =>
            _storedBatch(Map<String, Object?>.from(r as Map)).programPlan !=
            null,
      )) {
    return 29;
  }
  if (batches.isNotEmpty ||
      (tables['credential_batch_operations'] as List? ?? const []).isNotEmpty) {
    return 28;
  }
  return _hasCredentialDeliveryRows(
        (tables['credential_use_requests'] as List? ?? const []).map(
          (r) => Map<String, Object?>.from(r as Map),
        ),
      )
      ? 27
      : 26;
}

Map<String, List<String>> _syncColumns(int format) => switch (format) {
  29 || 30 || 31 || 32 => InformationBackups._v29Columns,
  28 => InformationBackups._v28Columns,
  _ => InformationBackups._v26Columns,
};

int _syncBatchContentFormat(LibrarySyncBatch batch) {
  final tables = <String, List<Map<String, Object?>>>{};
  for (final change in batch.changes) {
    for (final e in (change.content?['tables'] as Map? ?? const {}).entries) {
      tables.putIfAbsent(e.key as String, () => []).addAll([
        for (final row in e.value as List)
          Map<String, Object?>.from(row as Map),
      ]);
    }
  }
  final format = _syncContentFormat(tables);
  // A deletion still names the new complete history unit. Do not disguise it
  // as a format-26 delta just because it no longer carries parent rows.
  return batch.changes.any(
        (c) =>
            c.key.kind == LibrarySyncKind.history &&
            (c.key.id.startsWith('credential-batch:') ||
                c.key.id.startsWith('credential-batch-operation:')),
      )
      ? max(28, format)
      : format;
}

LibrarySyncKey _credentialOperationSyncKey(
  String table,
  String binding,
  String id,
) => LibrarySyncKey(
  LibrarySyncKind.history,
  'credential-batch-operation:${crypto.sha256.convert(utf8.encode(jsonEncode([table, binding, id])))}',
);

/// Owner-private portable metadata. Bodies remain in immutable attachment
/// storage. Units are complete records, not independently mergeable fields.
final class LibraryReplicaContents {
  LibraryReplicaContents._(
    this.libraryId,
    Map<LibrarySyncKey, Map<String, Object?>> values,
  ) : units = Map.unmodifiable({
        for (final entry in values.entries)
          entry.key: LibrarySyncEdit(
            key: entry.key,
            baseVersion: null,
            content: entry.value,
          ).content!,
      });
  final String libraryId;
  final Map<LibrarySyncKey, Map<String, Object?>> units;

  LibraryReplicaContents replacing(LibrarySyncBatch batch) {
    if (batch.libraryId != libraryId) {
      throw const StorageFailure('sync_base_changed');
    }
    final next = Map.of(units);
    for (final change in batch.changes) {
      if (change.content == null) {
        next.remove(change.key);
      } else {
        next[change.key] = change.content!;
      }
    }
    return LibraryReplicaContents._(libraryId, next);
  }

  /// Replay trusted, local SQL capture into portable metadata. A sequence of
  /// audit writes may need to be replayed together before cross-record checks.
  /// This method does not publish anything or mutate the running repository.
  LibraryReplicaContents replaying(
    Iterable<LibrarySqlChangeGroup> groups,
    DateTime now,
  ) {
    final document = _document(now, includeUnusedTables: true);
    final tables =
        document['tables'] as Map<String, List<Map<String, Object?>>>;
    final attachments = document['attachments'] as List<Object?>;
    for (final group in groups) {
      for (final change in group.changes) {
        final physical = change['table'] as String;
        if (physical == 'information_attachment_versions') {
          final key = change['key'] as List;
          attachments.removeWhere(
            (a) =>
                (a as Map)['attachmentId'] == key[0] &&
                a['attachmentVersion'] == key[1],
          );
          if (change['after'] case final Map after) {
            final version = InformationAttachmentVersion.fromPrivateJson(
              decodeProtocolObject(after['metadata'] as String),
            );
            if (version.available != (after['body_present'] == 1)) {
              throw const StorageFailure('invalid_sync_attachment');
            }
            attachments.add(version.toPrivateJson());
          }
          continue;
        }
        final table =
            InformationBackups._physicalTables.entries
                .where((e) => e.value == physical)
                .map((e) => e.key)
                .firstOrNull ??
            physical;
        if (table == 'settings' || !tables.containsKey(table)) {
          throw const StorageFailure('invalid_sync_capture');
        }
        final keyColumns = LibraryChangeJournal._keys[physical] ?? const ['id'];
        final before = change['before'] as Map?;
        final after = change['after'] as Map?;
        final sample = before ?? after!;
        String rowKey(Map row) => _syncJson([
          for (final column in keyColumns)
            if (column == 'payload')
              jsonDecode(row[column] as String)
            else
              row[column],
        ]);
        final key = rowKey(sample);
        tables[table]!.removeWhere((row) => rowKey(row) == key);
        if (after != null) {
          final row = Map<String, Object?>.from(after);
          if (table == 'information_deliveries') {
            row['payload'] = jsonEncode(
              _deliveryBudgetArchive(
                InformationFileDelivery.fromPrivateJson(_backupJson(row)),
                false,
              ),
            );
          }
          tables[table]!.add(row);
        }
      }
    }
    _archiveCredentialRuntime(tables, now);
    _archiveCredentialBatches(tables, now);
    _archiveCredentialPrograms(tables);
    final normalized = {
      ...document,
      'version': _syncContentFormat(tables),
      'tables': _LibrarySyncProjection.normalizeTables(tables),
    };
    final current = InformationBackups._validate(normalized);
    // Use the same inactive-history projection as initial copies. No active
    // bindings, output buffers or executable processes can enter the wire.
    final archiveTables = {
      for (final entry in current._tables.entries)
        entry.key: entry.value.toList(),
    };
    _retainBackupCredentialHistory(archiveTables, DateTime.utc(1), now);
    return LibraryReplicaContents._(
      libraryId,
      _LibrarySyncProjection.split(archiveTables, current.attachments),
    );
  }

  /// Reuses the complete portable validators, including links and file hashes.
  /// Repartitioning afterwards binds each payload to its actual record key;
  /// a peer cannot label another record's changes as a nonconflicting key.
  void validate(DateTime now) => _validated(now);
  BackupContents _validated(DateTime now) {
    final document = _document(now);
    final contents = InformationBackups._validate(document);
    final actual = _LibrarySyncProjection.split(
      contents._tables,
      contents.attachments,
    );
    if (actual.length != units.length ||
        actual.entries.any(
          (entry) =>
              !units.containsKey(entry.key) ||
              _syncJson(entry.value) != _syncJson(units[entry.key]),
        )) {
      throw const StorageFailure('invalid_sync_unit');
    }
    return contents;
  }

  Map<String, Object?> _document(
    DateTime now, {
    bool includeUnusedTables = false,
  }) {
    final tables = <String, List<Map<String, Object?>>>{
      for (final name in InformationBackups._v29Columns.keys) name: [],
    };
    final attachments = <Object?>[];
    for (final unit in units.values) {
      if (unit.length != 2 ||
          unit['tables'] is! Map ||
          unit['attachments'] is! List) {
        throw const StorageFailure('invalid_sync_unit');
      }
      final values = unit['tables'] as Map;
      for (final entry in values.entries) {
        if (entry.key == 'settings' ||
            !tables.containsKey(entry.key) ||
            entry.value is! List) {
          throw const StorageFailure('invalid_sync_unit');
        }
        for (final row in entry.value as List) {
          if (row is! Map) throw const StorageFailure('invalid_sync_unit');
          tables[entry.key]!.add(Map<String, Object?>.from(row));
        }
      }
      attachments.addAll(unit['attachments'] as List);
    }
    final format = _syncContentFormat(tables);
    return {
      'format': InformationBackups._format,
      'version': format,
      'createdAt': now.toUtc().toIso8601String(),
      'tables': includeUnusedTables
          ? tables
          : {for (final key in _syncColumns(format).keys) key: tables[key]!},
      'attachments': attachments,
    };
  }

  @override
  String toString() => 'LibraryReplicaContents(units: ${units.length})';
}

String _syncJson(Object? value) => jsonEncode(_orderedBackupJson(value));

extension LibraryReplicationContents on LibraryReplication {
  /// Caller holds Owner's snapshot barrier. Used to establish a baseline or
  /// validate a committed delta, never as a directory-click/polling read path.
  Future<LibraryReplicaContents> snapshotContents() async {
    final current = await identity();
    return repository._db.transaction(() async {
      final document = await repository.backups._rawSnapshotDocument();
      final tables = _LibrarySyncProjection.normalizeTables(
        document['tables'] as Map,
      );
      final normalized = {
        ...document,
        'version': _syncContentFormat(tables),
        'tables': tables,
        'attachments': document['attachments'] ?? <Object?>[],
      };
      final validated = InformationBackups._validate(normalized);
      final archive = repository.backups._retain(
        validated,
        repository._clock().toUtc(),
        restored: true,
        preserveHistory: true,
      );
      return LibraryReplicaContents._(
        current.libraryId,
        _LibrarySyncProjection.split(archive._tables, archive.attachments),
      );
    });
  }
}

final class _LibrarySyncProjection {
  static Map<String, List<Map<String, Object?>>> normalizeTables(Map raw) => {
    for (final table in _syncColumns(_syncContentFormat(raw)).entries)
      table.key: table.key == 'settings'
          ? []
          : [
              for (final row in raw[table.key] as List? ?? const [])
                {
                  for (final column in table.value)
                    column: column == 'payload'
                        ? _payload(table.key, row[column] as String)
                        : row[column],
                },
            ],
  };

  static String _payload(String table, String source) {
    final value = decodeProtocolObject(
      source,
      maxBytes: InformationBackups.maxPayloadBytes,
    );
    // Imported-history markers are device-local, not user edits. The receiving
    // adapter reinstates inactive markers, never usable grants or processes.
    if ({
      'request_history',
      'grant_history',
      'credential_use_requests',
      'credential_executions',
      'credential_focused_fills',
      'information_deliveries',
    }.contains(table)) {
      if (table == 'information_deliveries') {
        // The archive's exact shape requires this nullable member.
        value['restoredAt'] = null;
      } else {
        value.remove('restoredAt');
      }
    }
    return _syncJson(value);
  }

  static Map<LibrarySyncKey, Map<String, Object?>> split(
    Map<String, List<Map<String, Object?>>> tables,
    List<InformationAttachmentVersion> attachments, {
    bool preserveLocalMarkers = false,
  }) {
    final result = <LibrarySyncKey, Map<String, Object?>>{};
    Map<String, Object?> unit(LibrarySyncKey key) => result.putIfAbsent(
      key,
      () => {
        'tables': <String, List<Map<String, Object?>>>{},
        'attachments': <Object?>[],
      },
    );
    void add(LibrarySyncKey key, String table, Map<String, Object?> row) {
      final target =
          unit(key)['tables'] as Map<String, List<Map<String, Object?>>>;
      target.putIfAbsent(table, () => []).add(row);
    }

    LibrarySyncKey information(Object? id) =>
        LibrarySyncKey(LibrarySyncKind.information, id as String);
    final fieldOwners = {
      for (final field in tables['information_fields']!)
        field['id'] as String: field['item_id'] as String,
    };
    for (final table in tables.entries) {
      if (table.key == 'settings') continue;
      for (final row in table.value) {
        final key = switch (table.key) {
          'information_items' => information(row['id']),
          'information_fields' ||
          'information_item_tags' ||
          'information_revisions' ||
          'information_revision_snapshots' ||
          'revision_purge_facts' => information(row['item_id']),
          'information_file_fields' => information(
            fieldOwners[row['field_id']],
          ),
          'recycle_entries' ||
          'recycle_facts' => information(_backupJson(row)['itemId']),
          'managed_credentials' => LibrarySyncKey(
            LibrarySyncKind.credential,
            row['id'] as String,
          ),
          'credential_materials' ||
          'credential_material_snapshots' => LibrarySyncKey(
            LibrarySyncKind.credential,
            row['credential_id'] as String,
          ),
          'information_directories' => LibrarySyncKey(
            LibrarySyncKind.directory,
            row['id'] as String,
          ),
          'information_tags' => LibrarySyncKey(
            LibrarySyncKind.tag,
            row['id'] as String,
          ),
          'field_templates' => LibrarySyncKey(
            LibrarySyncKind.template,
            row['id'] as String,
          ),
          'template_packages' => LibrarySyncKey(
            LibrarySyncKind.plugin,
            row['id'] as String,
          ),
          'library_order_state' => LibrarySyncKey(
            LibrarySyncKind.order,
            row['id'] as String,
          ),
          'library_recycle_batches' => LibrarySyncKey(
            LibrarySyncKind.recycle,
            row['id'] as String,
          ),
          'ssh_host_trust' => LibrarySyncKey(
            LibrarySyncKind.sshTrust,
            'current',
          ),
          'credential_use_requests' => LibrarySyncKey(
            LibrarySyncKind.history,
            'credential:${row['id']}',
          ),
          'credential_executions' ||
          'credential_focused_fills' => LibrarySyncKey(
            LibrarySyncKind.history,
            'credential:${row['request_id']}',
          ),
          'credential_batches' => LibrarySyncKey(
            LibrarySyncKind.history,
            'credential-batch:${row['id']}',
          ),
          'credential_batch_operations' ||
          'credential_program_operations' => _credentialOperationSyncKey(
            table.key,
            row['session_binding'] as String,
            row['operation_id'] as String,
          ),
          _ => LibrarySyncKey(
            LibrarySyncKind.history,
            '${table.key}:${row['id']}',
          ),
        };
        add(key, table.key, {
          for (final column in InformationBackups._v29Columns[table.key]!)
            column: column == 'payload'
                ? preserveLocalMarkers
                      ? _syncJson(jsonDecode(row[column] as String))
                      : _payload(table.key, row[column] as String)
                : row[column],
        });
      }
    }
    for (final version in attachments) {
      final id = crypto.sha256
          .convert(utf8.encode(jsonEncode(version.reference.toJson())))
          .toString();
      (unit(LibrarySyncKey(LibrarySyncKind.attachment, id))['attachments']
              as List)
          .add(version.toPrivateJson());
    }
    for (final value in result.values) {
      for (final rows in (value['tables'] as Map).values) {
        (rows as List<Map<String, Object?>>).sort(
          (a, b) => _syncJson(a).compareTo(_syncJson(b)),
        );
      }
    }
    return result;
  }
}
