part of 'info_storage.dart';

typedef AttachmentBackupChunkReader =
    Future<Uint8List> Function(int offset, int length);

/// Trusted source of one fixed ordinary-file version. The caller owns a stable
/// source snapshot. This reader is never an Agent-controlled path or command.
final class AttachmentBackupSource {
  const AttachmentBackupSource(this.version, {this.read});
  final InformationAttachmentVersion version;
  final AttachmentBackupChunkReader? read;
}

/// Backup format8 in SQLCipher4. Domain row/reference validation and the
/// recipient's atomic installation belong to InformationBackups, not this codec.
/// InformationBackups connects this codec to formal rows and atomic restores.
final class AttachmentBackupContainer {
  static const _snapshotSchema =
      'CREATE TABLE backup_snapshot(singleton INTEGER PRIMARY KEY CHECK(singleton=1),payload TEXT NOT NULL)';
  static const _chunkSchema =
      'CREATE TABLE attachment_chunks(attachment_id TEXT NOT NULL,attachment_version INTEGER NOT NULL,chunk_index INTEGER NOT NULL,body BLOB NOT NULL,PRIMARY KEY(attachment_id,attachment_version,chunk_index)) WITHOUT ROWID';
  static const chunkBytes = 1024 * 1024;
  static const maxFileBytes = 256 * 1024 * 1024;
  static const maxPayloadBytes = 64 * 1024 * 1024;
  static const maxRetainedBytes = 100 * 1024 * 1024;
  static const maxVersions = 10000;

  static Future<void> write({
    required String path,
    required String recoveryKey,
    required DateTime createdAt,
    required Map<String, List<Map<String, Object?>>> tables,
    required List<AttachmentBackupSource> attachments,
    int formatVersion = 8,
    String? stagingParent,
    // Already created and registered by InformationBackups before it starts
    // the source read transaction. Other callers keep the original allocation.
    String? registeredStagingDirectory,
  }) async {
    InformationBackups._decodeKey(recoveryKey);
    sqlite.Database? db;
    Directory? staging;
    try {
      InformationBackups._requireCipher();
      final sources = List<AttachmentBackupSource>.unmodifiable(attachments);
      if (!createdAt.isUtc) {
        throw const StorageFailure('invalid_backup');
      }
      if (sources.length > maxVersions)
        throw const StorageFailure('backup_too_large');
      final payload = jsonEncode({
        'format': InformationBackups._format,
        'version': formatVersion,
        'createdAt': createdAt.toIso8601String(),
        'tables': tables,
        'attachments': [for (final s in sources) s.version.toPrivateJson()],
      });
      if (utf8.encode(payload).length > maxPayloadBytes) {
        throw const StorageFailure('backup_too_large');
      }
      // Validate before invoking any source. No truncated/partial backup is an
      // acceptable response to a capacity or duplicate-reference error.
      final manifest = _AttachmentBackupManifest.parse(payload);
      final output = File(path);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const StorageFailure('output_exists');
      }
      if (registeredStagingDirectory != null) {
        staging = Directory(registeredStagingDirectory);
        if ((await staging.list(followLinks: false).toList()).isNotEmpty) {
          throw const StorageFailure('backup_staging_failed');
        }
      } else {
        staging = await Directory(
          stagingParent ?? output.parent.path,
        ).createTemp('.agent-info-backup8-');
      }
      final temporary = File('${staging.path}/backup.partial');
      db = sqlite.sqlite3.open(temporary.path);
      InformationBackups._key(db, recoveryKey);
      db.execute('PRAGMA journal_mode=DELETE');
      db.execute(_snapshotSchema);
      db.execute(_chunkSchema);
      db.execute('BEGIN');
      db.execute('INSERT INTO backup_snapshot(singleton,payload) VALUES(1,?)', [
        payload,
      ]);
      for (var i = 0; i < manifest.versions.length; i++) {
        final version = manifest.versions[i];
        if (!version.available) continue;
        final reader = sources[i].read;
        if (version.byteLength != 0 && reader == null) {
          throw const StorageFailure('attachment_missing');
        }
        final hash = _AttachmentBackupHash();
        var offset = 0, index = 0;
        while (offset < version.byteLength) {
          final length = min(chunkBytes, version.byteLength - offset);
          final returned = await reader!(offset, length);
          if (returned.length != length) {
            throw const StorageFailure('attachment_integrity_failed');
          }
          final bytes = Uint8List.fromList(returned);
          hash.add(bytes);
          db.execute(
            'INSERT INTO attachment_chunks(attachment_id,attachment_version,chunk_index,body) VALUES(?,?,?,?)',
            [
              version.reference.attachmentId,
              version.reference.attachmentVersion,
              index++,
              bytes,
            ],
          );
          offset += length;
        }
        if (hash.finish() != version.sha256) {
          throw const StorageFailure('attachment_integrity_failed');
        }
      }
      db.execute('COMMIT');
      db.close();
      db = null;
      final checked = await openValidated(temporary.path, recoveryKey);
      checked.close();
      try {
        publishNewBackup(temporary.absolute.path, output.absolute.path);
      } on Object {
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const StorageFailure('output_exists');
        }
        throw const StorageFailure('backup_publish_failed');
      }
    } on Object catch (error) {
      if (error is StorageFailure) rethrow;
      throw const StorageFailure('backup_export_failed');
    } finally {
      db?.close();
      if (staging != null) {
        for (final name in [
          'backup.partial',
          'backup.partial-journal',
          'backup.partial-wal',
          'backup.partial-shm',
        ]) {
          try {
            final file = File('${staging.path}/$name');
            if (await file.exists()) await file.delete();
          } on Object {
            /* Preserve encrypted leftovers if the OS refuses cleanup. */
          }
        }
        try {
          await staging.delete();
        } on Object {
          /* No recursive path cleanup. */
        }
      }
    }
  }

  /// Authenticate/validate all bytes before publishing a handle. The read
  /// transaction remains open for restoration, avoiding inspect/reopen races.
  static Future<AttachmentBackupReader> openValidated(
    String path,
    String recoveryKey,
  ) async {
    InformationBackups._decodeKey(recoveryKey);
    sqlite.Database? db;
    try {
      InformationBackups._requireCipher();
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const StorageFailure('invalid_backup');
      }
      final length = await File(path).length();
      if (length < 4096 || length > maxFileBytes || length % 4096 != 0) {
        throw const StorageFailure('invalid_backup');
      }
      db = sqlite.sqlite3.open(path, mode: sqlite.OpenMode.readOnly);
      InformationBackups._key(db, recoveryKey);
      if (db.select('PRAGMA journal_mode').single.values.single != 'delete') {
        throw const StorageFailure('unsupported_backup');
      }
      db.execute('BEGIN');
      if (db.select('PRAGMA cipher_integrity_check').isNotEmpty) {
        throw const StorageFailure('invalid_backup');
      }
      final objects = db.select(
        "SELECT type,name,length(sql) AS size FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
      );
      if (objects.length != 2 ||
          objects.any((r) => r['type'] != 'table') ||
          objects.map((r) => r['name']).toSet().difference({
            'backup_snapshot',
            'attachment_chunks',
          }).isNotEmpty ||
          objects.any((r) => r['size'] is! int || (r['size'] as int) > 2048)) {
        throw const StorageFailure('unsupported_backup');
      }
      for (final row in db.select(
        "SELECT name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
      )) {
        final expected = row['name'] == 'backup_snapshot'
            ? _snapshotSchema
            : _chunkSchema;
        if (row['sql'] != expected)
          throw const StorageFailure('unsupported_backup');
      }
      final integrity = db.select('PRAGMA integrity_check');
      if (integrity.length != 1 || integrity.single.values.single != 'ok') {
        throw const StorageFailure('invalid_backup');
      }
      final rows = db.select(
        'SELECT singleton,typeof(payload) AS type,length(CAST(payload AS BLOB)) AS size FROM backup_snapshot',
      );
      if (rows.length != 1 ||
          rows.single['singleton'] != 1 ||
          rows.single['type'] != 'text' ||
          rows.single['size'] is! int ||
          (rows.single['size'] as int) > maxPayloadBytes) {
        throw const StorageFailure('invalid_backup');
      }
      final raw = db
          .select('SELECT payload FROM backup_snapshot')
          .single['payload'];
      if (raw is! String) throw const StorageFailure('invalid_backup');
      final manifest = _AttachmentBackupManifest.parse(raw);
      final count = db
          .select('SELECT count(*) AS n FROM attachment_chunks')
          .single['n'];
      final expected = manifest.versions.fold<int>(
        0,
        (sum, v) =>
            sum +
            (v.available ? (v.byteLength + chunkBytes - 1) ~/ chunkBytes : 0),
      );
      if (count != expected) throw const StorageFailure('invalid_backup');
      final reader = AttachmentBackupReader._(db, manifest);
      for (final v in manifest.versions) {
        await reader._verify(v);
      }
      db = null; // ownership passes only after every file was authenticated.
      return reader;
    } on Object catch (error) {
      if (error is StorageFailure) rethrow;
      throw const StorageFailure('invalid_backup');
    } finally {
      db?.close();
    }
  }
}

final class AttachmentBackupReader {
  AttachmentBackupReader._(this._db, this._manifest);
  final sqlite.Database _db;
  final _AttachmentBackupManifest _manifest;
  bool _closed = false;
  DateTime get createdAt => _manifest.createdAt;
  int get formatVersion => _manifest.formatVersion;
  Map<String, List<Map<String, Object?>>> get tables => _manifest.tables;
  List<InformationAttachmentVersion> get versions => _manifest.versions;

  void _checkOpen() {
    if (_closed) throw const StorageFailure('backup_closed');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.close();
  }

  List<Map<String, Object?>> _chunkMetadata(InformationAttachmentVersion v) {
    _checkOpen();
    final rows = _db.select(
      'SELECT chunk_index,typeof(body) AS type,length(body) AS size FROM attachment_chunks WHERE attachment_id=? AND attachment_version=? ORDER BY chunk_index LIMIT 11',
      [v.reference.attachmentId, v.reference.attachmentVersion],
    );
    final expected = v.available
        ? (v.byteLength + AttachmentBackupContainer.chunkBytes - 1) ~/
              AttachmentBackupContainer.chunkBytes
        : 0;
    if (rows.length != expected) throw const StorageFailure('invalid_backup');
    for (var i = 0; i < rows.length; i++) {
      final size = min(
        AttachmentBackupContainer.chunkBytes,
        v.byteLength - i * AttachmentBackupContainer.chunkBytes,
      );
      if (rows[i]['chunk_index'] is! int ||
          rows[i]['chunk_index'] != i ||
          rows[i]['type'] != 'blob' ||
          rows[i]['size'] != size) {
        throw const StorageFailure('invalid_backup');
      }
    }
    return rows;
  }

  Uint8List _chunk(InformationAttachmentVersion v, int index, int expected) {
    _checkOpen();
    final row = _db.select(
      'SELECT body FROM attachment_chunks WHERE attachment_id=? AND attachment_version=? AND chunk_index=?',
      [v.reference.attachmentId, v.reference.attachmentVersion, index],
    );
    if (row.length != 1 || row.single['body'] is! Uint8List) {
      throw const StorageFailure('invalid_backup');
    }
    final bytes = row.single['body'] as Uint8List;
    if (bytes.length != expected) throw const StorageFailure('invalid_backup');
    return Uint8List.fromList(bytes);
  }

  Future<void> _verify(InformationAttachmentVersion v) async {
    final rows = _chunkMetadata(v);
    if (!v.available) return;
    final hash = _AttachmentBackupHash();
    for (var i = 0; i < rows.length; i++) {
      hash.add(_chunk(v, i, rows[i]['size'] as int));
      await Future<void>.delayed(Duration.zero);
    }
    if (hash.finish() != v.sha256)
      throw const StorageFailure('attachment_integrity_failed');
  }

  /// The caller must finish its recipient transaction only after the stream
  /// ends: closing or a late IO/hash failure must roll back its installation.
  Stream<Uint8List> readAttachment(InformationAttachmentRef reference) async* {
    _checkOpen();
    final version = versions.where((v) => v.reference == reference).firstOrNull;
    if (version == null || !version.available) {
      throw const StorageFailure('attachment_missing');
    }
    try {
      final rows = _chunkMetadata(version);
      final hash = _AttachmentBackupHash();
      for (var i = 0; i < rows.length; i++) {
        final bytes = _chunk(version, i, rows[i]['size'] as int);
        hash.add(bytes);
        yield bytes;
      }
      _checkOpen();
      if (hash.finish() != version.sha256)
        throw const StorageFailure('attachment_integrity_failed');
    } on Object catch (error) {
      if (error is StorageFailure) rethrow;
      throw const StorageFailure('invalid_backup');
    }
  }
}

final class _AttachmentBackupManifest {
  _AttachmentBackupManifest(
    this.tables,
    this.versions,
    this.createdAt,
    this.formatVersion,
  );
  final Map<String, List<Map<String, Object?>>> tables;
  final List<InformationAttachmentVersion> versions;
  final DateTime createdAt;
  final int formatVersion;
  static _AttachmentBackupManifest parse(String payload) {
    final json = decodeProtocolObject(
      payload,
      maxBytes: AttachmentBackupContainer.maxPayloadBytes,
    );
    if (json['format'] != InformationBackups._format ||
        json['version'] is! int ||
        !{8, 9, 10, 11, 12, 13, 14, 15}.contains(json['version'])) {
      throw const StorageFailure('unsupported_backup');
    }
    if (json.length != 5 ||
        json['tables'] is! Map<String, dynamic> ||
        json['attachments'] is! List ||
        (json['attachments'] as List).length >
            AttachmentBackupContainer.maxVersions) {
      throw const StorageFailure('invalid_backup');
    }
    final createdAt = _backupDate(json['createdAt']);
    final versions = <InformationAttachmentVersion>[];
    final identities = <InformationAttachmentRef>{};
    var bytes = 0;
    for (final row in json['attachments'] as List) {
      if (row is! Map<String, dynamic>)
        throw const StorageFailure('invalid_backup');
      final v = InformationAttachmentVersion.fromPrivateJson(row);
      if (!identities.add(v.reference))
        throw const StorageFailure('invalid_backup');
      if (v.available) bytes += v.byteLength;
      if (bytes > AttachmentBackupContainer.maxRetainedBytes) {
        throw const StorageFailure('backup_too_large');
      }
      versions.add(v);
    }
    final tables = <String, List<Map<String, Object?>>>{};
    for (final row in (json['tables'] as Map<String, dynamic>).entries) {
      if (!RegExp(r'^[a-z][a-z0-9_]{0,80}$').hasMatch(row.key) ||
          row.value is! List) {
        throw const StorageFailure('invalid_backup');
      }
      final values = <Map<String, Object?>>[];
      for (final value in row.value as List) {
        if (value is! Map<String, dynamic>)
          throw const StorageFailure('invalid_backup');
        values.add(_freezeBackupJson(value) as Map<String, Object?>);
      }
      tables[row.key] = List.unmodifiable(values);
    }
    return _AttachmentBackupManifest(
      Map.unmodifiable(tables),
      List.unmodifiable(versions),
      createdAt,
      json['version'] as int,
    );
  }
}

Object? _freezeBackupJson(Object? value) => switch (value) {
  Map<String, dynamic> m => Map<String, Object?>.unmodifiable(
    m.map((k, v) => MapEntry(k, _freezeBackupJson(v))),
  ),
  List l => List<Object?>.unmodifiable(l.map(_freezeBackupJson)),
  _ => value,
};

final class _AttachmentDigestSink implements Sink<crypto.Digest> {
  crypto.Digest? result;
  @override
  void add(crypto.Digest value) => result = value;
  @override
  void close() {}
}

final class _AttachmentBackupHash {
  final _result = _AttachmentDigestSink();
  late final _input = crypto.sha256.startChunkedConversion(_result);
  void add(Uint8List bytes) => _input.add(bytes);
  String finish() {
    _input.close();
    return _result.result!.toString();
  }
}
