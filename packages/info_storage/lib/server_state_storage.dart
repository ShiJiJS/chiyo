part of 'info_storage.dart';

extension _EncryptedServerState on EncryptedInformationRepository {
  Future<bool> _hasServerStateTable() async =>
      (await _db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='server_runtime_state'",
              )
              .get())
          .isNotEmpty;

  ServerStateSnapshot _serverSnapshot(QueryRow row) {
    try {
      return ServerStateSnapshot(
        generation: row.read<String>('generation'),
        revision: row.read<int>('revision'),
        payload: decodeProtocolObject(
          row.read<String>('payload'),
          maxBytes: ServerStateSnapshot.maxBytes,
        ),
      );
    } on Object {
      throw const StorageFailure('invalid_server_state');
    }
  }

  Future<ServerStateSnapshot> _openServerState() async {
    if (_closed) throw const StorageFailure('library_closed');
    return _db.transaction(() async {
      await _db.customStatement(
        'CREATE TABLE IF NOT EXISTS server_runtime_state('
        'singleton INTEGER PRIMARY KEY CHECK(singleton=1),generation TEXT NOT NULL,'
        'revision INTEGER NOT NULL CHECK(revision>=0),payload TEXT NOT NULL)',
      );
      await _requireAdmissionFormat(_serverRuntimeLibraryFormat);
      final rows = await _db
          .customSelect(
            'SELECT generation,revision,payload FROM server_runtime_state WHERE singleton=1',
          )
          .get();
      if (rows.isNotEmpty) return _serverSnapshot(rows.single);
      final random = Random.secure();
      final generation = base64Url
          .encode(List.generate(32, (_) => random.nextInt(256)))
          .replaceAll('=', '');
      await _db.customStatement(
        'INSERT INTO server_runtime_state(singleton,generation,revision,payload) VALUES(1,?,0,?)',
        [generation, '{}'],
      );
      return ServerStateSnapshot(
        generation: generation,
        revision: 0,
        payload: {},
      );
    });
  }

  Future<ServerStateSnapshot> _commitServerState(
    ServerStateSnapshot expected,
    Map<String, Object?> payload,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    final next = ServerStateSnapshot(
      generation: expected.generation,
      revision: expected.revision + 1,
      payload: payload,
    );
    return _db.transaction(() async {
      if (!await _hasServerStateTable())
        throw const AccessFailure('server_state_changed');
      final rows = await _db
          .customSelect(
            'SELECT generation,revision,payload FROM server_runtime_state WHERE singleton=1',
          )
          .get();
      if (rows.length != 1 ||
          rows.single.read<String>('generation') != expected.generation ||
          rows.single.read<int>('revision') != expected.revision) {
        throw const AccessFailure('server_state_changed');
      }
      await _db.customStatement(
        'UPDATE server_runtime_state SET revision=?,payload=? WHERE singleton=1',
        [next.revision, jsonEncode(next.payload)],
      );
      return next;
    });
  }

  Future<void> _invalidateServerState() async {
    if (await _hasServerStateTable())
      await _db.customStatement('DELETE FROM server_runtime_state');
  }
}
