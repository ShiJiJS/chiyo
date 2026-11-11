part of 'info_storage.dart';

/// Owner-only preview. Credential values and private sync payloads never leave
/// storage through this API; the chosen protected candidate is applied here.
extension LibrarySyncConflicts on LibraryIncremental {
  Map<LibrarySyncKey, Map<String, Object?>> _dependenciesFor(
    List<LibrarySyncEdit> edits,
    LibraryReplicaContents next,
  ) {
    final result = <LibrarySyncKey, Map<String, Object?>>{};
    final visited = <LibrarySyncKey>{...edits.map((e) => e.key)};
    void visit(LibrarySyncKey key) {
      if (!visited.add(key)) return;
      final value = next.units[key];
      if (value == null) return;
      result[key] = value;
      for (final row
          in _candidateTables(value)['information_directories'] ??
              const <Map<String, Object?>>[]) {
        if (row['parent_id'] case final String id)
          visit(LibrarySyncKey(LibrarySyncKind.directory, id));
      }
    }

    for (final edit in edits) {
      final tables = _candidateTables(edit.content);
      for (final row in [
        ...?tables['information_items'],
        ...?tables['information_directories'],
      ]) {
        final id = row['directory_id'] ?? row['parent_id'];
        if (id is String) visit(LibrarySyncKey(LibrarySyncKind.directory, id));
      }
      for (final row
          in tables['information_item_tags'] ??
              const <Map<String, Object?>>[]) {
        visit(LibrarySyncKey(LibrarySyncKind.tag, row['tag_id'] as String));
      }
      for (final row
          in tables['managed_credentials'] ?? const <Map<String, Object?>>[]) {
        final c = ManagedCredential.fromJson(_backupJson(row));
        if (c.directoryId != null)
          visit(LibrarySyncKey(LibrarySyncKind.directory, c.directoryId!));
        for (final id in c.tagIds) {
          visit(LibrarySyncKey(LibrarySyncKind.tag, id));
        }
      }
    }
    return result;
  }

  bool _dependencyConflict(LibraryReplicaContents next) {
    final tables =
        next._document(_repo._clock().toUtc())['tables']
            as Map<String, List<Map<String, Object?>>>;
    final directories = {
      for (final row in tables['information_directories']!)
        row['id'] as String: row['parent_id'] as String?,
    };
    final tags = tables['information_tags']!.map((r) => r['id']).toSet();
    bool missing(String? directory, Iterable<Object?> selectedTags) =>
        directory != null && !directories.containsKey(directory) ||
        selectedTags.any((id) => !tags.contains(id));
    for (final row in tables['information_items']!) {
      if (missing(
        row['directory_id'] as String?,
        tables['information_item_tags']!
            .where((r) => r['item_id'] == row['id'])
            .map((r) => r['tag_id']),
      ))
        return true;
    }
    for (final row in tables['managed_credentials']!) {
      final c = ManagedCredential.fromJson(_backupJson(row));
      if (c.deletedAt == null && missing(c.directoryId, c.tagIds)) return true;
    }
    for (final id in directories.keys) {
      final seen = <String>{};
      String? parent = id;
      while (parent != null) {
        if (!directories.containsKey(parent) || !seen.add(parent)) return true;
        parent = directories[parent];
      }
    }
    return false;
  }

  List<LibrarySyncEdit> _reviewEdits(
    LibrarySyncBatch incoming,
    Map<LibrarySyncKey, (String, Map<String, Object?>?)> units,
  ) {
    final next = LibraryReplicaContents._(incoming.libraryId, {
      for (final e in units.entries)
        if (e.value.$2 != null) e.key: e.value.$2!,
    }).replacing(incoming);
    return [
      for (final c in incoming.changes) c.edit,
      if (_dependencyConflict(next))
        for (final e in incoming.dependencies.entries)
          if (!incoming.changes.any((c) => c.key == e.key))
            LibrarySyncEdit(
              key: e.key,
              baseVersion: units[e.key]?.$1,
              content: e.value,
            ),
    ];
  }

  Future<List<int>> conflictCursors({int limit = 32}) async {
    if (limit < 1 || limit > 256) throw ArgumentError.value(limit);
    await project();
    final rows = await _db
        .customSelect(
          "SELECT cursor FROM library_sync_feed f WHERE outcome='conflict' "
          'AND NOT EXISTS(SELECT 1 FROM library_sync_resolutions r WHERE r.conflict_cursor=f.cursor) ORDER BY cursor LIMIT ?',
          variables: [Variable(limit)],
        )
        .get();
    return [for (final row in rows) row.read<int>('cursor')];
  }

  Future<List<Map<String, Object?>>> conflicts({int limit = 32}) async {
    if (limit < 1 || limit > 256) throw ArgumentError.value(limit);
    await project();
    final rows = await _db
        .customSelect(
          "SELECT cursor FROM library_sync_feed f WHERE outcome='conflict' "
          'AND NOT EXISTS(SELECT 1 FROM library_sync_resolutions r WHERE r.conflict_cursor=f.cursor) '
          'ORDER BY cursor LIMIT ?',
          variables: [Variable(1)],
        )
        .get();
    return [for (final row in rows) await conflict(row.read<int>('cursor'))];
  }

  Future<QueryRow> _conflictRow(int cursor) async {
    final rows = await _db
        .customSelect(
          "SELECT * FROM library_sync_feed f WHERE cursor=? AND outcome='conflict' "
          'AND NOT EXISTS(SELECT 1 FROM library_sync_resolutions r WHERE r.conflict_cursor=f.cursor)',
          variables: [Variable(cursor)],
        )
        .get();
    if (rows.length != 1) throw const StorageFailure('sync_conflict_changed');
    return rows.single;
  }

  String _reviewToken(
    LibrarySyncBatch incoming,
    Map<LibrarySyncKey, (String, Map<String, Object?>?)> units,
  ) => crypto.sha256
      .convert(
        utf8.encode(
          _syncJson({
            'batch': incoming.digest,
            'heads': [
              for (final c in _reviewEdits(incoming, units))
                {'key': c.key.toJson(), 'version': units[c.key]?.$1},
            ],
          }),
        ),
      )
      .toString();

  Future<Map<String, Object?>> conflict(int cursor) async {
    await project();
    final row = await _conflictRow(cursor);
    final batch = LibrarySyncBatch.decode(row.read<String>('payload'));
    final units = await _units();
    return {
      'cursor': cursor,
      'token': _reviewToken(batch, units),
      'items': [
        for (final c in _reviewEdits(batch, units))
          if (c.key.kind != LibrarySyncKind.attachment)
            {
              'key': c.key.toJson(),
              'local': _safeCandidate(c.key, units[c.key]?.$2),
              'incoming': _safeCandidate(c.key, c.content),
            },
      ],
    };
  }

  Map<String, List<Map<String, Object?>>> _candidateTables(
    Map<String, Object?>? unit,
  ) => {
    for (final e in (unit?['tables'] as Map? ?? const {}).entries)
      e.key as String: [
        for (final row in e.value as List)
          Map<String, Object?>.from(row as Map),
      ],
  };

  InformationItem? _candidateItem(Map<String, Object?>? unit) {
    final tables = _candidateTables(unit);
    final rows = tables['information_items'] ?? const [];
    return rows.isEmpty
        ? null
        : _informationFromRows(
            rows.single,
            tables['information_fields'] ?? const [],
            tables['information_item_tags'] ?? const [],
            tables['information_file_fields'] ?? const [],
          );
  }

  Map<String, Object?> _safeCandidate(
    LibrarySyncKey key,
    Map<String, Object?>? unit,
  ) {
    final item = _candidateItem(unit);
    if (item != null) return {'information': informationToJson(item)};
    final tables = _candidateTables(unit);
    final credentials = tables['managed_credentials'] ?? const [];
    if (credentials.isNotEmpty)
      return {'credential': _backupJson(credentials.single)};
    if (unit == null) return {'deleted': true};
    // Other units are displayed as typed metadata; history is never a generic
    // JSON inspector, and protected materials cannot reach this branch.
    return {
      'summary': [
        for (final table in tables.entries)
          for (final row in table.value)
            {
              'type': key.kind.name,
              if (row['name'] is String) 'name': row['name'],
              if (row['parent_id'] is String) 'parentId': row['parent_id'],
              if (row['version'] is int) 'version': row['version'],
            },
      ],
    };
  }

  /// CAS against exactly what the user reviewed. The result is a new durable
  /// batch with both parent heads, not a rewrite of an earlier receipt.
  Future<LibrarySyncReceipt> resolveConflict({
    required int cursor,
    required String token,
    required bool useIncoming,
    required String operationId,
  }) async {
    replicaOperationId(operationId);
    replicaDigest(token);
    final identity = await replication.identity();
    final prior = await receipt(identity.replicaId, operationId);
    if (prior != null) {
      final commands = await _db
          .customSelect(
            'SELECT cursor,token,use_incoming FROM library_sync_resolution_commands WHERE operation_id=?',
            variables: [Variable(operationId)],
          )
          .get();
      if (commands.length != 1 ||
          commands.single.read<int>('cursor') != cursor ||
          commands.single.read<String>('token') != token ||
          commands.single.read<int>('use_incoming') != (useIncoming ? 1 : 0))
        throw const StorageFailure('sync_operation_conflict');
      return prior;
    }
    await project();
    return _db.transaction(() async {
      final row = await _conflictRow(cursor);
      final incoming = LibrarySyncBatch.decode(row.read<String>('payload'));
      final units = await _units();
      if (_reviewToken(incoming, units) != token ||
          _ownsActiveHistory(incoming))
        throw const StorageFailure('sync_conflict_changed');
      final now = _repo._clock().toUtc();
      final edits = <LibrarySyncEdit>[];
      final parents = <LibrarySyncKey, Set<String>>{};
      for (final change in _reviewEdits(incoming, units)) {
        final local = units[change.key];
        Map<String, Object?>? chosen = useIncoming ? change.content : local?.$2;
        if (change.key.kind == LibrarySyncKind.information) {
          chosen = _resolveInformation(chosen, local?.$2, change.content, now);
        } else if (change.key.kind == LibrarySyncKind.credential) {
          chosen = _resolveCredential(chosen, local?.$2, change.content, now);
        } else if (change.key.kind == LibrarySyncKind.attachment &&
            chosen == null) {
          // The other candidate's exact file remains readable in its history.
          chosen = local?.$2 ?? change.content;
        }
        if (chosen != null) {
          final tables = _candidateTables(chosen);
          for (final entry in tables.entries) {
            for (final row in entry.value) {
              if (row['payload'] is String)
                row['payload'] = _LibrarySyncProjection._payload(
                  entry.key,
                  row['payload'] as String,
                );
            }
            entry.value.sort((a, b) => _syncJson(a).compareTo(_syncJson(b)));
          }
          chosen = {
            'tables': {
              for (final e in tables.entries)
                if (e.value.isNotEmpty) e.key: e.value,
            },
            'attachments': chosen['attachments'],
          };
        }
        edits.add(
          LibrarySyncEdit(
            key: change.key,
            baseVersion: change.key.kind == LibrarySyncKind.attachment
                ? null
                : local?.$1,
            content: chosen,
          ),
        );
        parents[change.key] = {
          if (local != null) local.$1,
          ...incoming.changes
              .where((c) => c.key == change.key)
              .map((c) => c.version),
          if (incoming.dependencyVersions[change.key] case final version?)
            version,
        };
      }
      final needed = <InformationAttachmentRef>{};
      void keep(InformationItem item) {
        needed.addAll(
          item.fields
              .map((f) => f.attachment)
              .whereType<InformationAttachmentRef>(),
        );
      }

      for (final edit in edits.where(
        (e) => e.key.kind == LibrarySyncKind.information,
      )) {
        final tables = _candidateTables(edit.content);
        final item = _candidateItem(edit.content);
        if (item != null) keep(item);
        for (final row in [
          ...?tables['information_revisions'],
          ...?tables['information_revision_snapshots'],
        ]) {
          keep(informationFromJson(_backupJson(row)));
        }
        for (final row
            in tables['recycle_entries'] ?? const <Map<String, Object?>>[]) {
          final snapshot = RecycleEntry.fromJson(_backupJson(row)).snapshot;
          if (snapshot != null) keep(snapshot);
        }
      }
      for (final ref in needed) {
        final key = LibrarySyncKey(
          LibrarySyncKind.attachment,
          crypto.sha256
              .convert(utf8.encode(jsonEncode(ref.toJson())))
              .toString(),
        );
        if (edits.any((e) => e.key == key)) continue;
        final content =
            units[key]?.$2 ??
            incoming.changes.where((c) => c.key == key).firstOrNull?.content;
        if (content == null)
          throw const StorageFailure('sync_attachment_missing');
        edits.add(
          LibrarySyncEdit(key: key, baseVersion: null, content: content),
        );
        if (units[key] != null) parents[key] = {units[key]!.$1};
      }
      parents.removeWhere((_, v) => v.isEmpty);
      final state = await _state();
      final batch = LibrarySyncBatch(
        libraryId: identity.libraryId,
        sourceReplicaId: identity.replicaId,
        operationId: operationId,
        sequence: state.read<int>('local_sequence') + 1,
        edits: edits,
        acceptedBases: parents,
      );
      await _db.customStatement(
        'INSERT INTO library_sync_resolution_commands VALUES(?,?,?,?)',
        [operationId, cursor, token, useIncoming ? 1 : 0],
      );
      final result = await receive(batch);
      if (result.conflict) throw const StorageFailure('sync_conflict_changed');
      await _db.customStatement(
        'UPDATE library_sync_projection SET local_sequence=? WHERE singleton=1',
        [batch.sequence],
      );
      return result;
    });
  }

  Map<String, Object?>? _resolveInformation(
    Map<String, Object?>? selected,
    Map<String, Object?>? a,
    Map<String, Object?>? b,
    DateTime now,
  ) {
    final tables = _candidateTables(selected);
    final snapshots = <String, Map<String, Object?>>{};
    final originals = [
      for (final unit in [a, b])
        if (_candidateItem(unit) case final item?) item,
    ];
    void remember(InformationItem item, DateTime at) {
      final id = informationSnapshotId(item);
      final row = {
        'item_id': item.id,
        'version': item.version,
        'snapshot_id': id,
        'replaced_at': at.toIso8601String(),
        'payload': jsonEncode(informationToJson(item)),
      };
      final prior = snapshots[id];
      if (prior == null ||
          (prior['replaced_at'] as String).compareTo(
                row['replaced_at'] as String,
              ) <
              0)
        snapshots[id] = row;
    }

    for (final unit in [a, b]) {
      final history = _candidateTables(unit);
      for (final row in [
        ...?history['information_revisions'],
        ...?history['information_revision_snapshots'],
      ]) {
        remember(
          informationFromJson(_backupJson(row)),
          _backupDate(row['replaced_at']),
        );
      }
    }
    for (final item in originals) {
      remember(item, now);
    }
    if (snapshots.isNotEmpty) {
      tables['information_revisions'] = [];
      tables['information_revision_snapshots'] = snapshots.values.toList();
    }
    if (selected != null &&
        (tables['information_items']?.isNotEmpty ?? false)) {
      final item = tables['information_items']!.single;
      item['version'] = originals.map((i) => i.version).fold<int>(0, max) + 1;
      item['modified_at'] = now.toIso8601String();
      for (final field
          in tables['information_fields'] ?? const <Map<String, Object?>>[]) {
        field['version'] =
            originals
                .expand((i) => i.fields)
                .where((f) => f.id == field['id'])
                .map((f) => f.version)
                .fold<int>(0, max) +
            1;
      }
    }
    if (tables.isEmpty) return selected;
    return {
      'tables': tables,
      'attachments': selected?['attachments'] ?? <Object?>[],
    };
  }

  Map<String, Object?>? _resolveCredential(
    Map<String, Object?>? selected,
    Map<String, Object?>? a,
    Map<String, Object?>? b,
    DateTime now,
  ) {
    if (selected == null) return null;
    final tables = _candidateTables(selected);
    if (tables['managed_credentials']?.isEmpty ?? true) return selected;
    final candidates = [
      for (final unit in [a, b]) _candidateTables(unit),
    ];
    final metadata = [
      for (final t in candidates)
        for (final row
            in t['managed_credentials'] ?? const <Map<String, Object?>>[])
          ManagedCredential.fromJson(_backupJson(row)),
    ];
    final chosen = ManagedCredential.fromJson(
      _backupJson(tables['managed_credentials']!.single),
    );
    final archives = <String, Map<String, Object?>>{};
    final materials = <int, List<CredentialMaterial>>{};
    for (final t in candidates) {
      for (final row
          in t['credential_material_snapshots'] ??
              const <Map<String, Object?>>[]) {
        archives[row['snapshot_id'] as String] = row;
      }
      final cRows = t['managed_credentials'] ?? const [];
      if (cRows.isEmpty) continue;
      final c = ManagedCredential.fromJson(_backupJson(cRows.single));
      for (final row
          in t['credential_materials'] ?? const <Map<String, Object?>>[]) {
        final m = CredentialMaterial.fromStorageJson(_backupJson(row));
        materials.putIfAbsent(m.version, () => []).add(m);
        final payload = {
          'credential': c.toJson(),
          'material': m.retire(now).toStorageJson(),
        };
        final id = _credentialArchiveId(payload);
        archives[id] = {
          'credential_id': c.id,
          'version': m.version,
          'snapshot_id': id,
          'payload': jsonEncode(payload),
        };
      }
    }
    final nextVersion = metadata.map((c) => c.version).fold<int>(0, max) + 1;
    final current =
        (tables['credential_materials'] ?? const <Map<String, Object?>>[])
            .where((r) => r['version'] == chosen.version)
            .firstOrNull;
    final changed = {
      ...chosen.toJson(),
      'version': nextVersion,
      'revision': metadata.map((c) => c.revision).fold<int>(0, max) + 1,
      'useGeneration':
          metadata.map((c) => c.useGeneration).fold<int>(0, max) + 1,
      'modifiedAt': now.toIso8601String(),
    };
    tables['managed_credentials'] = [
      {'id': chosen.id, 'payload': jsonEncode(changed)},
    ];
    tables['credential_material_snapshots'] = archives.values.toList();
    tables['credential_materials'] = [
      for (final entry in materials.entries)
        if (entry.value
                .map((m) => _syncJson(m.toStorageJson()..remove('retiredAt')))
                .toSet()
                .length ==
            1)
          {
            'credential_id': chosen.id,
            'version': entry.key,
            'payload': jsonEncode(
              entry.value.first.retire(now).toStorageJson(),
            ),
          },
      if (current != null && chosen.purgedAt == null)
        {
          'credential_id': chosen.id,
          'version': nextVersion,
          'payload': jsonEncode({
            ..._backupJson(current),
            'version': nextVersion,
            'createdAt': now.toIso8601String(),
            'retiredAt': chosen.deletedAt?.toIso8601String(),
          }),
        },
    ];
    return {'tables': tables, 'attachments': <Object?>[]};
  }

  Future<void> _rememberParents(LibrarySyncBatch batch) async {
    for (final change in batch.changes) {
      for (final parent in {
        if (change.baseVersion != null) change.baseVersion!,
        ...?batch.acceptedBases[change.key],
      }) {
        await _db.customStatement(
          'INSERT OR IGNORE INTO library_sync_parent_versions VALUES(?,?,?,?)',
          [change.key.kind.name, change.key.id, change.version, parent],
        );
      }
    }
  }

  /// Mark only candidates whose two heads are explicitly covered. Later edits
  /// remain conflicts. Immutable original receipts keep their original outcome.
  Future<void> _settleConflicts(LibrarySyncBatch resolution) async {
    if (resolution.acceptedBases.isEmpty) return;
    final rows = await _db
        .customSelect(
          "SELECT cursor,payload,local_candidate FROM library_sync_feed f WHERE outcome='conflict' "
          'AND NOT EXISTS(SELECT 1 FROM library_sync_resolutions r WHERE r.conflict_cursor=f.cursor)',
        )
        .get();
    for (final row in rows) {
      final candidate = LibrarySyncBatch.decode(row.read<String>('payload'));
      final local = {
        for (final raw
            in jsonDecode(row.read<String>('local_candidate')) as List)
          LibrarySyncKey.fromJson(Map<String, dynamic>.from(raw['key'] as Map)):
              raw['version'] as String?,
      };
      Future<bool> covered(LibrarySyncChange c) async {
        final parents = resolution.acceptedBases[c.key];
        if (parents == null) return false;
        Future<bool> contains(String version) async {
          if (parents.contains(version)) return true;
          final rows = await _db
              .customSelect(
                'WITH RECURSIVE ancestors(version) AS ('
                'SELECT parent FROM library_sync_parent_versions WHERE kind=? AND id=? AND version IN (${parents.map((_) => '?').join(',')}) '
                'UNION SELECT p.parent FROM library_sync_parent_versions p JOIN ancestors a ON p.version=a.version WHERE p.kind=? AND p.id=?) '
                'SELECT 1 FROM ancestors WHERE version=? LIMIT 1',
                variables: [
                  Variable(c.key.kind.name),
                  Variable(c.key.id),
                  for (final p in parents) Variable(p),
                  Variable(c.key.kind.name),
                  Variable(c.key.id),
                  Variable(version),
                ],
              )
              .get();
          return rows.isNotEmpty;
        }

        if (!await contains(c.version)) return false;
        final v = local[c.key];
        return v == null || await contains(v);
      }

      var allCovered = true;
      for (final change in candidate.changes) {
        if (!await covered(change)) {
          allCovered = false;
          break;
        }
      }
      if (allCovered) {
        await _db.customStatement(
          'INSERT INTO library_sync_resolutions VALUES(?,?,?)',
          [
            row.read<int>('cursor'),
            resolution.sourceReplicaId,
            resolution.operationId,
          ],
        );
      }
    }
  }
}
