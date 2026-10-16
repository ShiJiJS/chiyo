part of 'info_storage.dart';

/// A fully authenticated and validated current-data snapshot, held in memory.
/// It carries no usable grant, pending request or source database key.
class BackupContents {
  BackupContents._(this._tables, this.createdAt);
  final Map<String, List<Map<String, Object?>>> _tables;
  final DateTime createdAt;
  int get informationCount => _tables['information_items']!.length;
  int get directoryCount => _tables['information_directories']!.length;
  int get tagCount => _tables['information_tags']!.length;
  int get templateCount => _tables['field_templates']!.length;
}

/// Owner-only manual backup capability. It is never part of the agent server.
/// Format 1 is a SQLCipher 4 encrypted envelope containing a logical snapshot.
class InformationBackups {
  InformationBackups._(this._repository);
  final EncryptedInformationRepository _repository;
  static const _keyPrefix = 'aim-recovery-v1:';
  static const _format = 'agent-info-manage-current-data';
  static const maxFileBytes = 128 * 1024 * 1024;
  static const maxPayloadBytes = 64 * 1024 * 1024;
  static const _columns = <String, List<String>>{
    'information_directories': ['id', 'name', 'parent_id', 'version'],
    'information_tags': ['id', 'name', 'version'],
    'field_templates': ['id', 'name', 'description', 'version', 'fields_json'],
    'information_items': [
      'id',
      'name',
      'description',
      'version',
      'directory_id',
    ],
    'information_fields': [
      'id',
      'item_id',
      'name',
      'description',
      'value',
      'version',
      'kind',
    ],
    'information_item_tags': ['item_id', 'tag_id'],
    'settings': ['name', 'value'],
  };

  void _checkOpen() {
    if (_repository._closed) throw const StorageFailure('library_closed');
  }

  /// The key is stored only inside the local encrypted database, separately
  /// from its operating-system-managed database key, and is never backed up.
  Future<String?> recoveryKey() async {
    _checkOpen();
    try {
      final rows = await _repository._db
          .customSelect(
            'SELECT recovery_key FROM backup_configuration WHERE singleton=1',
          )
          .get();
      if (rows.isEmpty) return null;
      final key = rows.single.read<String>('recovery_key');
      _decodeKey(key);
      return key;
    } catch (_) {
      throw const StorageFailure('backup_key_unavailable');
    }
  }

  Future<String> enable() async {
    _checkOpen();
    try {
      return await _repository._db.transaction(() async {
        final previous = await recoveryKey();
        if (previous != null) return previous;
        final random = Random.secure();
        final key =
            '$_keyPrefix${base64Url.encode(List.generate(32, (_) => random.nextInt(256)))}';
        await _repository._db.customStatement(
          'INSERT INTO backup_configuration(singleton,recovery_key) VALUES(1,?)',
          [key],
        );
        return key;
      });
    } catch (_) {
      throw const StorageFailure('backup_key_unavailable');
    }
  }

  /// An explicit owner export of the recovery secret. The file is plaintext by
  /// design so it can be kept independently, and is never bundled with backups.
  Future<void> saveRecoveryKeyTo(String path) async {
    final key = await recoveryKey();
    if (key == null) throw const StorageFailure('backup_not_enabled');
    final file = File(path);
    var created = false;
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const StorageFailure('output_exists');
      }
      await file.create(exclusive: true);
      created = true;
      await file.writeAsString('$key\n', flush: true);
    } catch (error) {
      if (created) {
        try {
          await file.delete();
        } catch (_) {
          /* No sensitive diagnostics. */
        }
      }
      if (error is StorageFailure) rethrow;
      throw const StorageFailure('recovery_key_save_failed');
    }
  }

  static List<int> _decodeKey(String value) {
    try {
      if (!value.startsWith(_keyPrefix) ||
          value.length != _keyPrefix.length + 44) {
        throw const FormatException();
      }
      final encoded = value.substring(_keyPrefix.length);
      final bytes = base64Url.decode(encoded);
      if (bytes.length != 32 || base64Url.encode(bytes) != encoded) {
        throw const FormatException();
      }
      return bytes;
    } catch (_) {
      throw const StorageFailure('invalid_recovery_key');
    }
  }

  static void _key(sqlite.Database db, String recoveryKey) {
    final hex = _decodeKey(
      recoveryKey,
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final cipher = db.select('PRAGMA cipher_version');
    if (cipher.isEmpty ||
        !(cipher.first.values.first as String).startsWith('4.')) {
      throw const StorageFailure('cipher_unavailable');
    }
    db.execute('PRAGMA key = "x\'$hex\'"');
    db.execute('PRAGMA cipher_compatibility = 4');
    db.execute('PRAGMA temp_store = MEMORY');
    db.execute('PRAGMA trusted_schema = OFF');
  }

  Future<BackupContents> _snapshot() async {
    _checkOpen();
    return _repository._db.transaction(() async {
      final tables = <String, Object?>{};
      for (final table in _columns.entries) {
        final rows = await _repository._db
            .customSelect(
              'SELECT ${table.value.join(',')} FROM ${table.key} ORDER BY rowid',
            )
            .get();
        tables[table.key] = rows.map((row) => row.data).toList();
      }
      return _validate({
        'format': _format,
        'version': 1,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'tables': tables,
      });
    });
  }

  /// An existing output is always refused, even when the file dialog confirmed
  /// overwrite. A failed/interrupted export leaves existing backups untouched.
  Future<void> exportTo(String path) async {
    _checkOpen();
    sqlite.Database? db;
    File? owned;
    try {
      final key = await recoveryKey();
      if (key == null) throw const StorageFailure('backup_not_enabled');
      final snapshot = await _snapshot();
      final payload = jsonEncode({
        'format': _format,
        'version': 1,
        'createdAt': snapshot.createdAt.toIso8601String(),
        'tables': snapshot._tables,
      });
      if (utf8.encode(payload).length > maxPayloadBytes)
        throw const StorageFailure('backup_too_large');
      final output = File(path);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const StorageFailure('output_exists');
      }
      await output.create(exclusive: true);
      owned = output;
      db = sqlite.sqlite3.open(output.path);
      _key(db, key);
      db.execute(
        'CREATE TABLE backup_snapshot(singleton INTEGER PRIMARY KEY CHECK(singleton=1),payload TEXT NOT NULL)',
      );
      db.execute('INSERT INTO backup_snapshot(singleton,payload) VALUES(1,?)', [
        payload,
      ]);
      db.close();
      db = null;
      await inspect(path, key);
      owned = null;
    } catch (error) {
      db?.close();
      if (owned != null) {
        try {
          await owned.delete();
        } catch (_) {
          /* Preserve failure without logging paths or secrets. */
        }
      }
      if (error is StorageFailure) rethrow;
      throw const StorageFailure('backup_export_failed');
    }
  }

  Future<BackupContents> inspect(String path, String recoveryKey) async {
    _decodeKey(recoveryKey);
    sqlite.Database? db;
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const StorageFailure('invalid_backup');
      }
      final length = await File(path).length();
      if (length < 4096 || length > maxFileBytes || length % 4096 != 0) {
        throw const StorageFailure('invalid_backup');
      }
      db = sqlite.sqlite3.open(path, mode: sqlite.OpenMode.readOnly);
      _key(db, recoveryKey);
      db.execute('BEGIN');
      // SQLCipher authenticates every page before any schema or payload parsing.
      if (db.select('PRAGMA cipher_integrity_check').isNotEmpty)
        throw const StorageFailure('invalid_backup');
      final objects = db.select(
        "SELECT type,name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
      );
      if (objects.length != 1 ||
          objects.single['type'] != 'table' ||
          objects.single['name'] != 'backup_snapshot') {
        throw const StorageFailure('unsupported_backup');
      }
      final integrity = db.select('PRAGMA integrity_check');
      if (integrity.length != 1 || integrity.single.values.single != 'ok')
        throw const StorageFailure('invalid_backup');
      final rows = db.select(
        'SELECT singleton,length(CAST(payload AS BLOB)) AS size FROM backup_snapshot',
      );
      if (rows.length != 1 ||
          rows.single['singleton'] != 1 ||
          rows.single['size'] is! int ||
          (rows.single['size'] as int) > maxPayloadBytes) {
        throw const StorageFailure('invalid_backup');
      }
      final payload = db
          .select('SELECT payload FROM backup_snapshot')
          .single['payload'];
      if (payload is! String) throw const StorageFailure('invalid_backup');
      return _validate(jsonDecode(payload));
    } catch (error) {
      if (error is StorageFailure) rethrow;
      throw const StorageFailure('invalid_backup');
    } finally {
      db?.close();
    }
  }

  Future<BackupContents> restoreFrom(String path, String recoveryKey) async =>
      restore(await inspect(path, recoveryKey));

  /// Restore only into an empty recipient library. Its existing, freshly created
  /// OS-protected database key is retained; the source device key is unnecessary.
  Future<BackupContents> restore(BackupContents contents) async {
    _checkOpen();
    try {
      await _repository._db.transaction(() async {
        for (final table in _columns.keys.where((name) => name != 'settings')) {
          final rows = await _repository._db
              .customSelect('SELECT count(*) AS n FROM $table')
              .getSingle();
          if (rows.read<int>('n') != 0)
            throw const StorageFailure('recipient_not_empty');
        }
        await _repository._db.customStatement('DELETE FROM settings');
        // Directory parents may appear after a moved child in source row order.
        await _repository._db.customStatement('PRAGMA defer_foreign_keys = ON');
        for (final table in _columns.entries) {
          final placeholders = List.filled(table.value.length, '?').join(',');
          for (final row in contents._tables[table.key]!) {
            await _repository._db.customStatement(
              'INSERT INTO ${table.key}(${table.value.join(',')}) VALUES($placeholders)',
              table.value.map((column) => row[column]).toList(),
            );
          }
        }
      });
      _repository._settings.clear();
      await _repository._load();
      return contents;
    } catch (error) {
      if (error is StorageFailure) rethrow;
      throw const StorageFailure('backup_restore_failed');
    }
  }

  static BackupContents _validate(Object? decoded) {
    Never invalid() => throw const StorageFailure('invalid_backup');
    if (decoded is! Map<String, dynamic>) invalid();
    if (decoded['format'] != _format ||
        decoded['version'] is! int ||
        decoded['version'] != 1)
      throw const StorageFailure('unsupported_backup');
    if (decoded.length != 4 ||
        decoded['tables'] is! Map<String, dynamic> ||
        decoded['createdAt'] is! String ||
        (decoded['createdAt'] as String).length > 64)
      invalid();
    final createdAt = DateTime.tryParse(decoded['createdAt'] as String);
    if (createdAt == null) invalid();
    final data = decoded['tables'] as Map<String, dynamic>;
    if (data.length != _columns.length ||
        data.keys.any((key) => !_columns.containsKey(key)))
      invalid();
    final tables = <String, List<Map<String, Object?>>>{};
    for (final table in _columns.entries) {
      final rows = data[table.key];
      final maximum = switch (table.key) {
        'information_fields' || 'information_item_tags' => 200000,
        'field_templates' || 'settings' => 1000,
        _ => 10000,
      };
      if (rows is! List || rows.length > maximum) invalid();
      tables[table.key] = rows
          .map((value) {
            if (value is! Map<String, dynamic> ||
                value.length != table.value.length ||
                value.keys.any((key) => !table.value.contains(key)))
              invalid();
            return Map<String, Object?>.unmodifiable(value);
          })
          .toList(growable: false);
    }
    String text(
      Map<String, Object?> row,
      String key,
      int max, {
      bool required = false,
    }) {
      final value = row[key];
      if (value is! String ||
          value.length > max ||
          (required && value.trim().isEmpty))
        invalid();
      return value;
    }

    String id(Map<String, Object?> row, [String key = 'id']) =>
        text(row, key, 200, required: true);
    void version(Map<String, Object?> row) {
      final v = row['version'];
      if (v is! int || v < 1 || v > 2147483647) invalid();
    }

    Set<String> identities(String table) {
      final result = <String>{};
      for (final row in tables[table]!) {
        if (!result.add(id(row))) invalid();
        text(row, 'name', 200, required: true);
        version(row);
      }
      return result;
    }

    final directories = identities('information_directories');
    final tags = identities('information_tags');
    final items = identities('information_items');
    identities('information_fields');
    identities('field_templates');
    final parents = <String, String?>{};
    for (final row in tables['information_directories']!) {
      final parent = row['parent_id'];
      if (parent != null &&
          (parent is! String || !directories.contains(parent)))
        invalid();
      parents[id(row)] = parent as String?;
    }
    final checked = <String>{};
    for (final directory in parents.keys) {
      final seen = <String>{};
      String? current = directory;
      while (current != null && !checked.contains(current)) {
        if (!seen.add(current)) invalid();
        current = parents[current];
      }
      checked.addAll(seen);
    }
    final fieldCounts = <String, int>{};
    for (final field in tables['information_fields']!) {
      final item = id(field, 'item_id');
      fieldCounts[item] = (fieldCounts[item] ?? 0) + 1;
    }
    for (final row in tables['information_items']!) {
      text(row, 'description', 2000);
      final directory = row['directory_id'];
      if (directory != null &&
          (directory is! String || !directories.contains(directory)))
        invalid();
      final count = fieldCounts[row['id']] ?? 0;
      if (count < 1 || count > 200) invalid();
    }
    for (final row in tables['information_fields']!) {
      if (!items.contains(id(row, 'item_id'))) invalid();
      text(row, 'description', 2000);
      text(row, 'value', 1000000);
      if (!FieldKind.values.any((kind) => kind.name == row['kind'])) invalid();
    }
    final associations = <String>{};
    final tagCounts = <String, int>{};
    for (final row in tables['information_item_tags']!) {
      if (!items.contains(id(row, 'item_id')) ||
          !tags.contains(id(row, 'tag_id')) ||
          !associations.add(jsonEncode([row['item_id'], row['tag_id']])))
        invalid();
      final item = id(row, 'item_id');
      tagCounts[item] = (tagCounts[item] ?? 0) + 1;
      if (tagCounts[item]! > 100) invalid();
    }
    for (final row in tables['field_templates']!) {
      text(row, 'description', 2000);
      final fields = jsonDecode(text(row, 'fields_json', 1000000));
      if (fields is! List || fields.isEmpty || fields.length > 200) invalid();
      final seen = <String>{};
      for (final field in fields) {
        if (field is! Map<String, dynamic> ||
            field.length != 4 ||
            !seen.add(id(field)))
          invalid();
        text(field, 'name', 200, required: true);
        text(field, 'description', 2000);
        if (!FieldKind.values.any((kind) => kind.name == field['kind']))
          invalid();
      }
    }
    final settings = <String>{};
    for (final row in tables['settings']!) {
      final name = text(row, 'name', 200, required: true);
      if (!settings.add(name) || row['value'] is! int) invalid();
      final value = row['value'] as int;
      if (value < 0 || value > 9007199254740991) invalid();
      if (name == 'requestLifetimeMs' && (value < 60000 || value > 604800000))
        invalid();
    }
    return BackupContents._(Map.unmodifiable(tables), createdAt);
  }
}
