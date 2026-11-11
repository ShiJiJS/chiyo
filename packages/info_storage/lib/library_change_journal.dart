part of 'info_storage.dart';

/// A private SQL change group from one committed business transaction. This is
/// not the synchronization wire format: runtime rows still need the portable
/// content projection before export. In particular, never send this raw object
/// to an Agent or expose it through a generic event/log endpoint.
final class LibrarySqlChangeGroup {
  LibrarySqlChangeGroup._(this.sequence, this.operationId, this.changes);
  final int sequence;
  final String operationId;
  final List<Map<String, dynamic>> changes;
  @override
  String toString() =>
      'LibrarySqlChangeGroup($sequence, $operationId, rows: ${changes.length})';
}

/// Durable capture for an initialized replica. SQL triggers collect changed
/// row keys, while the outer Drift transaction emits exactly one stable group.
/// Nested operations in a proposal cannot become separately visible events.
/// This metadata remains in SQLCipher; attachment bodies stay in their existing
/// immutable version rows and are fetched separately only when needed.
final class LibraryChangeJournal {
  LibraryChangeJournal(this.replication);
  final LibraryReplication replication;
  EncryptedInformationRepository get _repo => replication.repository;
  _InformationDatabase get _db => _repo._db;

  Future<void> start() async {
    final identity = await replication.identity();
    await _db.transaction(() async {
      await _db.customStatement(
        'CREATE TABLE IF NOT EXISTS library_sync_change_state('
        'singleton INTEGER PRIMARY KEY CHECK(singleton=1),'
        'library_id TEXT NOT NULL,replica_id TEXT NOT NULL)',
      );
      await _db.customStatement(
        'CREATE TABLE IF NOT EXISTS library_sync_dirty('
        'table_name TEXT NOT NULL,row_key TEXT NOT NULL,'
        'before_json TEXT,after_json TEXT,PRIMARY KEY(table_name,row_key))',
      );
      await _db.customStatement(
        'CREATE TABLE IF NOT EXISTS library_sync_changes('
        'sequence INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT NOT NULL UNIQUE,'
        'changes TEXT NOT NULL)',
      );
      await _repo._requireAdmissionFormat(_libraryChangeJournalFormat);
      final state = await _db
          .customSelect(
            'SELECT library_id,replica_id FROM library_sync_change_state',
          )
          .get();
      if (state.isEmpty) {
        await _db.customStatement(
          'INSERT INTO library_sync_change_state VALUES(1,?,?)',
          [identity.libraryId, identity.replicaId],
        );
      } else if (state.single.read<String>('library_id') !=
              identity.libraryId ||
          state.single.read<String>('replica_id') != identity.replicaId) {
        throw const StorageFailure('sync_base_changed');
      }
      for (final entry in _tables.entries) {
        await _capture(entry.key, entry.value);
      }
    });
    _db.syncJournalEnabled = true;
  }

  // All names/columns below are repository-owned constants, never peer input.
  static final _tables = <String, List<String>>{
    for (final entry in InformationBackups._v21Columns.entries)
      if (entry.key != 'settings')
        InformationBackups._physicalTables[entry.key] ?? entry.key: entry.value,
    'information_attachment_versions': [
      'attachment_id',
      'version',
      'metadata',
      'byte_length',
    ],
  };
  static const _keys = <String, List<String>>{
    'information_fields': ['id'],
    'information_item_tags': ['item_id', 'tag_id'],
    'information_revisions': ['item_id', 'version'],
    'recycle_facts': ['payload'],
    'revision_purge_facts': ['item_id', 'version'],
    'credential_materials': ['credential_id', 'version'],
    'information_file_fields': ['field_id'],
    'information_attachment_versions': ['attachment_id', 'version'],
  };

  Future<void> _capture(String table, List<String> columns) async {
    final keys = _keys[table] ?? const ['id'];
    String key(String side) =>
        'json_array(${keys.map((c) => '$side."$c"').join(',')})';
    String body(String side) =>
        'json_object(${[for (final column in columns) "'$column',$side.\"$column\"", if (table == 'information_attachment_versions') "'body_present',($side.body IS NOT NULL)"].join(',')})';
    String put(String rowKey, String before, String after) =>
        "INSERT INTO library_sync_dirty(table_name,row_key,before_json,after_json) "
        "VALUES('$table',$rowKey,$before,$after) "
        'ON CONFLICT(table_name,row_key) DO UPDATE SET after_json=excluded.after_json;';
    const enabled =
        'EXISTS(SELECT 1 FROM library_sync_change_state WHERE singleton=1)';
    await _db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS sync_${table}_insert AFTER INSERT ON "$table" '
      'WHEN $enabled BEGIN ${put(key('NEW'), 'NULL', body('NEW'))} END',
    );
    await _db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS sync_${table}_delete AFTER DELETE ON "$table" '
      'WHEN $enabled BEGIN ${put(key('OLD'), body('OLD'), 'NULL')} END',
    );
    await _db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS sync_${table}_update AFTER UPDATE ON "$table" '
      'WHEN $enabled AND ${key('OLD')}=${key('NEW')} '
      'AND ${body('OLD')} IS NOT ${body('NEW')} '
      "BEGIN ${put(key('OLD'), body('OLD'), body('NEW'))} END",
    );
    // A changed primary key is a removal plus an addition in that same group.
    await _db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS sync_${table}_key AFTER UPDATE ON "$table" '
      'WHEN $enabled AND ${key('OLD')}<>${key('NEW')} '
      "BEGIN ${put(key('OLD'), body('OLD'), 'NULL')} "
      "${put(key('NEW'), 'NULL', body('NEW'))} END",
    );
  }

  Future<void> _checkScope() async {
    if (_repo._closed) throw const StorageFailure('library_closed');
    final identity = await replication.identity();
    final state = await _db
        .customSelect(
          'SELECT library_id,replica_id FROM library_sync_change_state WHERE singleton=1',
        )
        .get();
    if (state.length != 1 ||
        state.single.read<String>('library_id') != identity.libraryId ||
        state.single.read<String>('replica_id') != identity.replicaId) {
      throw const StorageFailure('sync_base_changed');
    }
  }

  Future<List<LibrarySqlChangeGroup>> after(
    int sequence, {
    int limit = 64,
  }) async {
    if (sequence < 0 || limit < 1 || limit > 256) {
      throw ArgumentError('Invalid synchronization page');
    }
    await _checkScope();
    final rows = await _db
        .customSelect(
          'SELECT sequence,operation_id,changes FROM library_sync_changes '
          'WHERE sequence>? ORDER BY sequence LIMIT ?',
          variables: [Variable(sequence), Variable(limit)],
        )
        .get();
    return List.unmodifiable([
      for (final row in rows)
        LibrarySqlChangeGroup._(
          row.read<int>('sequence'),
          row.read<String>('operation_id'),
          List.unmodifiable([
            for (final change
                in jsonDecode(row.read<String>('changes')) as List)
              Map<String, dynamic>.unmodifiable(change as Map<String, dynamic>),
          ]),
        ),
    ]);
  }
}

extension _SyncChangeFlush on _InformationDatabase {
  Future<void> _flushSyncChanges() async {
    final rows = await customSelect(
      'SELECT table_name,row_key,before_json,after_json FROM library_sync_dirty '
      'ORDER BY table_name,row_key',
    ).get();
    if (rows.isEmpty) return;
    final changes = [
      for (final row in rows)
        if (row.readNullable<String>('before_json') !=
            row.readNullable<String>('after_json'))
          {
            'table': row.read<String>('table_name'),
            'key': jsonDecode(row.read<String>('row_key')),
            'before': row.readNullable<String>('before_json') == null
                ? null
                : jsonDecode(row.read<String>('before_json')),
            'after': row.readNullable<String>('after_json') == null
                ? null
                : jsonDecode(row.read<String>('after_json')),
          },
    ];
    if (changes.isNotEmpty) {
      final random = Random.secure();
      final operation = base64Url
          .encode(List.generate(24, (_) => random.nextInt(256)))
          .replaceAll('=', '');
      await customStatement(
        'INSERT INTO library_sync_changes(operation_id,changes) VALUES(?,?)',
        [operation, jsonEncode(changes)],
      );
    }
    await customStatement('DELETE FROM library_sync_dirty');
  }
}
