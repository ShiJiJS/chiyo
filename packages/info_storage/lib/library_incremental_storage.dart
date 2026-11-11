part of 'info_storage.dart';

final class LibraryIncrementalEntry {
  LibraryIncrementalEntry._(this.cursor, this.batch);
  final int cursor;
  final LibrarySyncBatch batch;
}

/// Trusted owner-only durable delta projection. The caller holds Owner's
/// snapshot/write barrier, including while project() catches up local edits.
/// Unchanged polls only inspect cursors; they do not snapshot or rewrite data.
final class LibraryIncremental {
  LibraryIncremental(this.replication);
  final LibraryReplication replication;
  EncryptedInformationRepository get _repo => replication.repository;
  _InformationDatabase get _db => _repo._db;

  Future<void> start({LibraryReplicaContents? initialContents}) async {
    final identity = await replication.identity();
    await LibraryChangeJournal(replication).start();
    await _db.transaction(() async {
      await _db.customStatement(
        'CREATE TABLE IF NOT EXISTS library_sync_projection('
        'singleton INTEGER PRIMARY KEY CHECK(singleton=1),'
        'library_id TEXT NOT NULL,replica_id TEXT NOT NULL,'
        'raw_cursor INTEGER NOT NULL,local_sequence INTEGER NOT NULL)',
      );
      await _db.customStatement(
        'CREATE TABLE IF NOT EXISTS library_sync_units('
        'kind TEXT NOT NULL,id TEXT NOT NULL,version TEXT NOT NULL,'
        'content TEXT,PRIMARY KEY(kind,id))',
      );
      await _db.customStatement(
        'CREATE TABLE IF NOT EXISTS library_sync_feed('
        'cursor INTEGER PRIMARY KEY AUTOINCREMENT,source_id TEXT NOT NULL,'
        'operation_id TEXT NOT NULL,sequence INTEGER NOT NULL,digest TEXT NOT NULL,'
        "payload TEXT NOT NULL,outcome TEXT NOT NULL CHECK(outcome IN ('applied','conflict')),"
        'local_candidate TEXT,UNIQUE(source_id,operation_id),UNIQUE(source_id,sequence))',
      );
      await _db.customStatement(
        'CREATE TABLE IF NOT EXISTS library_sync_progress('
        'peer_id TEXT PRIMARY KEY,cursor INTEGER NOT NULL CHECK(cursor>=0))',
      );
      await _db.customStatement(
        'CREATE TABLE IF NOT EXISTS library_sync_blobs('
        'digest TEXT PRIMARY KEY,byte_length INTEGER NOT NULL,body BLOB NOT NULL '
        'CHECK(length(body)=byte_length))',
      );
      await _repo._requireAdmissionFormat(_libraryIncrementalFormat);
      final previous = await _db
          .customSelect(
            'SELECT library_id,replica_id FROM library_sync_projection',
          )
          .get();
      if (previous.isNotEmpty) {
        if (previous.single.read<String>('library_id') != identity.libraryId ||
            previous.single.read<String>('replica_id') != identity.replicaId) {
          throw const StorageFailure('sync_base_changed');
        }
        return;
      }
      final contents = initialContents ?? await replication.snapshotContents();
      if (contents.libraryId != identity.libraryId)
        throw const StorageFailure('sync_base_changed');
      contents.validate(_repo._clock().toUtc());
      for (final entry in contents.units.entries) {
        final version = crypto.sha256
            .convert(
              utf8.encode(
                _syncJson({
                  'libraryId': identity.libraryId,
                  'key': entry.key.toJson(),
                  'content': entry.value,
                }),
              ),
            )
            .toString();
        await _saveUnit(entry.key, version, entry.value);
      }
      final cursor = await _rawCursor();
      await _db.customStatement(
        'INSERT INTO library_sync_projection VALUES(1,?,?,?,0)',
        [identity.libraryId, identity.replicaId, cursor],
      );
      // Keep an original only when it is about to disappear from ordinary
      // immutable storage. This is encrypted disk staging, not an RAM prefetch.
      for (final operation in ['UPDATE OF body', 'DELETE']) {
        final suffix = operation.startsWith('UPDATE') ? 'purge' : 'delete';
        final condition = operation.startsWith('UPDATE')
            ? 'AND NEW.body IS NULL '
            : '';
        await _db.customStatement(
          'CREATE TRIGGER IF NOT EXISTS sync_retain_attachment_$suffix BEFORE $operation ON information_attachment_versions '
          'WHEN OLD.body IS NOT NULL $condition AND EXISTS(SELECT 1 FROM library_sync_projection WHERE singleton=1) '
          "BEGIN INSERT OR IGNORE INTO library_sync_blobs(digest,byte_length,body) VALUES(json_extract(OLD.metadata,'\$.sha256'),OLD.byte_length,OLD.body); END",
        );
      }
    });
  }

  Future<int> _rawCursor() async =>
      (await _db
              .customSelect(
                'SELECT coalesce(max(sequence),0) AS n FROM library_sync_changes',
              )
              .getSingle())
          .read<int>('n');

  Future<QueryRow> _state() async {
    if (_repo._closed) throw const StorageFailure('library_closed');
    final identity = await replication.identity();
    final rows = await _db
        .customSelect('SELECT * FROM library_sync_projection WHERE singleton=1')
        .get();
    if (rows.length != 1 ||
        rows.single.read<String>('library_id') != identity.libraryId ||
        rows.single.read<String>('replica_id') != identity.replicaId)
      throw const StorageFailure('sync_base_changed');
    return rows.single;
  }

  Future<Map<LibrarySyncKey, (String, Map<String, Object?>?)>>
  _units() async => {
    for (final row
        in await _db
            .customSelect(
              'SELECT kind,id,version,content FROM library_sync_units ORDER BY kind,id',
            )
            .get())
      LibrarySyncKey(
        LibrarySyncKind.values.byName(row.read<String>('kind')),
        row.read<String>('id'),
      ): (
        row.read<String>('version'),
        row.readNullable<String>('content') == null
            ? null
            : decodeProtocolObject(
                row.read<String>('content'),
                maxBytes: LibrarySyncBatch.maxBytes,
              ),
      ),
  };

  Future<void> _saveUnit(
    LibrarySyncKey key,
    String version,
    Map<String, Object?>? content,
  ) => _db.customStatement(
    'INSERT INTO library_sync_units(kind,id,version,content) VALUES(?,?,?,?) '
    'ON CONFLICT(kind,id) DO UPDATE SET version=excluded.version,content=excluded.content',
    [
      key.kind.name,
      key.id,
      version,
      content == null ? null : _syncJson(content),
    ],
  );

  /// Persist pending local changes before exporting or comparing a peer batch.
  Future<void> project() async {
    final state = await _state();
    final cursor = state.read<int>('raw_cursor');
    if (await _rawCursor() == cursor) return;
    await _db.transaction(() async {
      final start = await _state();
      final groups = await LibraryChangeJournal(
        replication,
      ).after(start.read<int>('raw_cursor'), limit: 256);
      if (groups.isEmpty) return;
      var units = await _units();
      var contents =
          LibraryReplicaContents._(start.read<String>('library_id'), {
            for (final entry in units.entries)
              if (entry.value.$2 != null) entry.key: entry.value.$2!,
          });
      var sequence = start.read<int>('local_sequence');
      final pending = <LibrarySqlChangeGroup>[];
      for (final group in groups) {
        pending.add(group);
        LibraryReplicaContents next;
        try {
          next = contents.replaying(pending, _repo._clock().toUtc());
        } on StorageFailure catch (error) {
          // Ordered audit writes can temporarily reference a not-yet-persisted
          // fact. Keep that source group intact until its matching write exists.
          if (error.code != 'invalid_backup' || group == groups.last) rethrow;
          continue;
        }
        final keys = {...contents.units.keys, ...next.units.keys};
        final edits = [
          for (final key in keys)
            if (_syncJson(contents.units[key]) != _syncJson(next.units[key]))
              LibrarySyncEdit(
                key: key,
                baseVersion: units[key]?.$1,
                content: next.units[key],
              ),
        ];
        if (edits.isNotEmpty) {
          final operation = pending.length == 1
              ? group.operationId
              : crypto.sha256
                    .convert(
                      utf8.encode(
                        jsonEncode(pending.map((g) => g.operationId).toList()),
                      ),
                    )
                    .toString();
          final batch = LibrarySyncBatch(
            libraryId: start.read<String>('library_id'),
            sourceReplicaId: start.read<String>('replica_id'),
            operationId: operation,
            sequence: ++sequence,
            edits: edits,
          );
          for (final change in batch.changes) {
            await _saveUnit(change.key, change.version, change.content);
            units[change.key] = (change.version, change.content);
          }
          await _db.customStatement(
            "INSERT INTO library_sync_feed(source_id,operation_id,sequence,digest,payload,outcome) VALUES(?,?,?,?,?,'applied')",
            [
              batch.sourceReplicaId,
              batch.operationId,
              batch.sequence,
              batch.digest,
              jsonEncode(batch.toJson()),
            ],
          );
        }
        await _db.customStatement(
          'UPDATE library_sync_projection SET raw_cursor=?,local_sequence=? WHERE singleton=1',
          [group.sequence, sequence],
        );
        contents = next;
        pending.clear();
      }
    });
  }

  Future<List<LibraryIncrementalEntry>> after(
    int cursor, {
    int limit = 32,
    int byteBudget = 8 * 1024 * 1024,
  }) async {
    if (cursor < 0 ||
        limit < 1 ||
        limit > 256 ||
        byteBudget < 262144 ||
        byteBudget > LibrarySyncBatch.maxBytes) {
      throw ArgumentError('Invalid synchronization cursor');
    }
    await project();
    final metadata = await _db
        .customSelect(
          "SELECT cursor,length(CAST(payload AS BLOB)) AS bytes FROM library_sync_feed WHERE cursor>? AND outcome='applied' ORDER BY cursor LIMIT ?",
          variables: [Variable(cursor), Variable(limit)],
        )
        .get();
    final result = <LibraryIncrementalEntry>[];
    var bytes = 0;
    for (final record in metadata) {
      final length = record.read<int>('bytes');
      if (length > LibrarySyncBatch.maxBytes) {
        throw const StorageFailure('sync_batch_capacity');
      }
      // A legal large transaction is returned alone, not split into partially
      // visible records. Ordinary pages obey the smaller requested budget.
      if (result.isNotEmpty && bytes + length > byteBudget) break;
      final row = await _db
          .customSelect(
            'SELECT payload FROM library_sync_feed WHERE cursor=?',
            variables: [Variable(record.read<int>('cursor'))],
          )
          .getSingle();
      result.add(
        LibraryIncrementalEntry._(
          record.read<int>('cursor'),
          LibrarySyncBatch.decode(row.read<String>('payload')),
        ),
      );
      bytes += length;
    }
    return result;
  }
}
