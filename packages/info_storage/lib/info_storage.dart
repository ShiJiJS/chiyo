import 'dart:io';
import 'dart:math';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:info_core/info_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
export 'platform_keys.dart';

class StorageFailure implements Exception {
  const StorageFailure(this.code);
  final String code;
  @override
  String toString() => 'StorageFailure($code)';
}

abstract interface class DatabaseKeyStore {
  Future<List<int>?> read();

  /// Must refuse to replace an existing key.
  Future<void> create(List<int> key);
}

/// A desktop-only capability. The CLI depends on info_core, never this package.
class EncryptedInformationRepository implements InformationRepository {
  EncryptedInformationRepository._(this._db, this._lock, this.cipherVersion);
  final _InformationDatabase _db;
  final RandomAccessFile _lock;
  final String cipherVersion;
  final _items = <String, InformationItem>{};
  final _settings = <String, int>{};
  bool _closed = false;
  static final _openDirectories = <String>{};
  late final String _directory;

  static Future<EncryptedInformationRepository> open(
    String directory,
    DatabaseKeyStore keys,
  ) async {
    final folder = Directory(directory);
    await folder.create(recursive: true);
    final canonical = await folder.resolveSymbolicLinks();
    if (!_openDirectories.add(canonical))
      throw const StorageFailure('library_in_use');
    RandomAccessFile? lock;
    sqlite.Database? native;
    _InformationDatabase? db;
    try {
      lock = await File('$canonical/library.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      final file = File('$canonical/library.db');
      final exists = await file.exists();
      var key = await keys.read();
      if (key == null) {
        if (exists) throw const StorageFailure('key_unavailable');
        key = List.generate(32, (_) => Random.secure().nextInt(256));
        await keys.create(key);
        final saved = await keys.read();
        if (saved == null ||
            saved.length != key.length ||
            List.generate(
              key.length,
              (i) => key![i] == saved[i],
            ).contains(false)) {
          throw const StorageFailure('key_unavailable');
        }
      }
      if (key.length != 32 || key.any((v) => v < 0 || v > 255))
        throw const StorageFailure('invalid_key');
      // Probe before creating or opening the user's file: plaintext fallback is forbidden.
      final probe = sqlite.sqlite3.openInMemory();
      String version;
      try {
        final rows = probe.select('PRAGMA cipher_version');
        if (rows.isEmpty || !(rows.first.values.first is String))
          throw const StorageFailure('cipher_unavailable');
        version = rows.first.values.first as String;
        if (!version.startsWith('4.'))
          throw const StorageFailure('cipher_unavailable');
      } finally {
        probe.dispose();
      }
      native = sqlite.sqlite3.open(file.path);
      final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      native.execute('PRAGMA key = "x\'$hex\'"');
      native.execute('PRAGMA temp_store = MEMORY');
      // Reading the schema checks the key before any migrations or updates.
      native.select('SELECT count(*) FROM sqlite_master');
      native.execute('PRAGMA foreign_keys = ON');
      db = _InformationDatabase(NativeDatabase.opened(native));
      native = null; // Drift owns the handle now.
      final repository = EncryptedInformationRepository._(db, lock, version)
        .._directory = canonical;
      await repository._load();
      return repository;
    } catch (error) {
      if (db != null) await db.close();
      native?.dispose();
      await lock?.close();
      _openDirectories.remove(canonical);
      if (error is StorageFailure) rethrow;
      throw const StorageFailure('library_unavailable');
    }
  }

  Future<void> _load() async {
    for (final row in await _db.customSelect('SELECT * FROM settings').get()) {
      _settings[row.read<String>('name')] = row.read<int>('value');
    }
    final items = await _db
        .customSelect('SELECT * FROM information_items ORDER BY rowid')
        .get();
    final fields = await _db
        .customSelect('SELECT * FROM information_fields ORDER BY rowid')
        .get();
    for (final item in items) {
      final id = item.read<String>('id');
      _items[id] = InformationItem(
        id,
        item.read<String>('name'),
        item.read<String>('description'),
        item.read<int>('version'),
        fields
            .where((f) => f.read<String>('item_id') == id)
            .map(
              (f) => InformationField(
                f.read<String>('id'),
                f.read<String>('name'),
                f.read<String>('description'),
                f.read<String>('value'),
                f.read<int>('version'),
              ),
            )
            .toList(),
      );
    }
  }

  @override
  List<InformationItem> get items {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_items.values);
  }

  @override
  int? readSetting(String key) {
    if (_closed) throw const StorageFailure('library_closed');
    return _settings[key];
  }

  @override
  Future<void> writeSetting(String key, int value) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.customStatement(
        'INSERT INTO settings(name,value) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value',
        [key, value],
      );
      _settings[key] = value;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  @override
  Future<void> save(InformationItem item) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        await _db.customStatement(
          'INSERT INTO information_items(id,name,description,version) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,description=excluded.description,version=excluded.version',
          [item.id, item.name, item.description, item.version],
        );
        for (final field in item.fields) {
          await _db.customStatement(
            'INSERT INTO information_fields(id,item_id,name,description,value,version) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value,version=excluded.version',
            [
              field.id,
              item.id,
              field.name,
              field.description,
              field.value,
              field.version,
            ],
          );
        }
      });
      _items[item.id] = item;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _items.clear();
    try {
      await _db.close();
    } finally {
      await _lock.close();
      _openDirectories.remove(_directory);
    }
  }
}

class _InformationDatabase extends GeneratedDatabase {
  _InformationDatabase(super.executor);
  @override
  int get schemaVersion => 2;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement(
        'CREATE TABLE settings(name TEXT PRIMARY KEY,value INTEGER NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE information_items(id TEXT PRIMARY KEY,name TEXT NOT NULL,description TEXT NOT NULL,version INTEGER NOT NULL DEFAULT 1)',
      );
      await customStatement(
        'CREATE TABLE information_fields(id TEXT PRIMARY KEY,item_id TEXT NOT NULL REFERENCES information_items(id),name TEXT NOT NULL,description TEXT NOT NULL,value TEXT NOT NULL,version INTEGER NOT NULL DEFAULT 1)',
      );
    },
    onUpgrade: (_, from, to) async {
      if (from != 1 || to != 2)
        throw const StorageFailure('unsupported_schema');
      await transaction(() async {
        await customStatement(
          'CREATE TABLE settings(name TEXT PRIMARY KEY,value INTEGER NOT NULL)',
        );
        await customStatement(
          'ALTER TABLE information_items ADD COLUMN version INTEGER NOT NULL DEFAULT 1',
        );
        await customStatement(
          'ALTER TABLE information_fields ADD COLUMN version INTEGER NOT NULL DEFAULT 1',
        );
      });
    },
    beforeOpen: (details) async {
      if (details.versionNow > schemaVersion)
        throw const StorageFailure('unsupported_schema');
    },
  );
}
