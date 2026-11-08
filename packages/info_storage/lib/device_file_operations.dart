part of 'info_storage.dart';

/// Private persistence used by the existing output/open coordinators. A local
/// desktop library supplies its own journal; an online client supplies only a
/// device journal. Neither adapter changes publication or cleanup rules.
abstract interface class _FileOperationContext {
  GeneratedDatabase get _db;
  bool get _closed;
  InformationFileOutputs get fileOutputs;
  InformationFileOpens get fileOpens;
  Future<void> checkOtherOperation(String id);
}

final class _RepositoryFileOperationContext implements _FileOperationContext {
  _RepositoryFileOperationContext(this.repository);
  final EncryptedInformationRepository repository;
  @override
  GeneratedDatabase get _db => repository._db;
  @override
  bool get _closed => repository._closed;
  @override
  InformationFileOutputs get fileOutputs => repository.fileOutputs;
  @override
  InformationFileOpens get fileOpens => repository.fileOpens;
  @override
  Future<void> checkOtherOperation(String id) async {
    for (final table in [
      'information_record_operations',
      'information_lifecycle_operations',
    ]) {
      if ((await _db
              .customSelect(
                'SELECT 1 FROM $table WHERE operation_id=?',
                variables: [Variable(id)],
              )
              .get())
          .isNotEmpty) {
        throw const StorageFailure('operation_conflict');
      }
    }
  }
}

/// Device-only encrypted operation receipts and cleanup capabilities. This
/// schema contains no information records, file originals, credentials, grants
/// or portable backups. Its key is independent of the server and its Token.
final class DeviceFileOperations implements _FileOperationContext {
  DeviceFileOperations._(this._db, this._lock, this._directory);
  @override
  final _DeviceFileDatabase _db;
  final RandomAccessFile _lock;
  final String _directory;
  static final _open = <String>{};
  @override
  bool _closed = false;
  @override
  late final fileOutputs = InformationFileOutputs._(this);
  @override
  late final fileOpens = InformationFileOpens._(this);
  @override
  Future<void> checkOtherOperation(String id) async {
    // Formal record operations live exclusively on the remote host. The App
    // checks those separately; this store only coordinates local output/open.
  }

  static Future<DeviceFileOperations> open(
    String directory, {
    required String serverId,
    DatabaseKeyStore? keys,
  }) async {
    if ((!Platform.isMacOS && !Platform.isLinux) ||
        serverId.isEmpty ||
        serverId.length > 128) {
      throw const StorageFailure('device_journal_unavailable');
    }
    final folder = Directory(directory).absolute;
    final type = await FileSystemEntity.type(folder.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const StorageFailure('device_journal_unavailable');
    }
    await folder.create(recursive: true);
    await _privateMode(folder.path, '700');
    final canonical = await folder.resolveSymbolicLinks();
    if (!_open.add(canonical))
      throw const StorageFailure('device_journal_in_use');
    RandomAccessFile? lock;
    sqlite.Database? native;
    _DeviceFileDatabase? db;
    try {
      final lockFile = File('$canonical/operations.lock');
      await _regularOrAbsent(lockFile.path);
      if (!await lockFile.exists()) await lockFile.create(exclusive: true);
      await _privateMode(lockFile.path, '600');
      lock = await lockFile.open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      final file = File('$canonical/operations.db');
      final exists = await _regularOrAbsent(file.path);
      final keyStore =
          keys ?? _PrivateDeviceFileKey('$canonical/operations.key');
      var key = await keyStore.read();
      if (key == null) {
        if (exists) throw const StorageFailure('key_unavailable');
        final random = Random.secure();
        key = List.generate(32, (_) => random.nextInt(256));
        await keyStore.create(key);
        final saved = await keyStore.read();
        if (saved == null || jsonEncode(key) != jsonEncode(saved)) {
          throw const StorageFailure('key_unavailable');
        }
      }
      if (key.length != 32 || key.any((b) => b < 0 || b > 255)) {
        throw const StorageFailure('invalid_key');
      }
      final probe = sqlite.sqlite3.openInMemory();
      try {
        final version = probe.select('PRAGMA cipher_version');
        if (version.isEmpty ||
            !(version.single.values.single as String).startsWith('4.')) {
          throw const StorageFailure('cipher_unavailable');
        }
      } finally {
        probe.close();
      }
      native = sqlite.sqlite3.open(file.path);
      final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      native.execute('PRAGMA key = "x\'$hex\'"');
      native.execute('PRAGMA temp_store = MEMORY');
      final tables = native.select(
        "SELECT name FROM sqlite_master WHERE type='table'",
      );
      final version =
          native.select('PRAGMA user_version').single.values.single as int;
      if (version > 1 ||
          tables.any(
            (r) => !const {
              'backup_operations',
              'device_file_scope',
            }.contains(r['name']),
          )) {
        throw const StorageFailure('unsupported_device_journal');
      }
      final database = _DeviceFileDatabase(NativeDatabase.opened(native));
      db = database;
      native = null;
      await database.transaction(() async {
        final rows = await database
            .customSelect('SELECT server_id FROM device_file_scope')
            .get();
        if (rows.isEmpty) {
          await database.customStatement(
            'INSERT INTO device_file_scope(singleton,server_id) VALUES(1,?)',
            [serverId],
          );
        } else if (rows.length != 1 ||
            rows.single.read<String>('server_id') != serverId) {
          throw const StorageFailure('device_journal_scope_changed');
        }
      });
      await _privateMode(file.path, '600');
      return DeviceFileOperations._(db, lock, canonical);
    } catch (e) {
      await db?.close();
      native?.close();
      await lock?.close();
      _open.remove(canonical);
      if (e is StorageFailure) rethrow;
      throw const StorageFailure('device_journal_unavailable');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _db.close();
    } finally {
      await _lock.close();
      _open.remove(_directory);
    }
  }
}

Future<void> _privateMode(String path, String mode) async {
  if ((await Process.run('chmod', [mode, path])).exitCode != 0) {
    throw const StorageFailure('device_journal_unavailable');
  }
}

Future<bool> _regularOrAbsent(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type != FileSystemEntityType.file &&
      type != FileSystemEntityType.notFound) {
    throw const StorageFailure('device_journal_unavailable');
  }
  return type == FileSystemEntityType.file;
}

final class _PrivateDeviceFileKey implements DatabaseKeyStore {
  _PrivateDeviceFileKey(this.path);
  final String path;
  @override
  Future<List<int>?> read() async {
    if (!await _regularOrAbsent(path)) return null;
    final file = File(path), stat = await File(path).stat();
    if (stat.mode & 0xE3F != 0 || stat.size != 32) {
      throw const StorageFailure('key_unavailable');
    }
    return file.readAsBytes();
  }

  @override
  Future<void> create(List<int> key) async {
    if (key.length != 32) throw const StorageFailure('invalid_key');
    final file = File(path);
    await file.create(exclusive: true);
    await _privateMode(file.path, '600');
    await file.writeAsBytes(key, flush: true);
  }
}

final class _DeviceFileDatabase extends GeneratedDatabase {
  _DeviceFileDatabase(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement(
        'CREATE TABLE backup_operations(operation_id TEXT PRIMARY KEY,payload TEXT NOT NULL,invalidated INTEGER NOT NULL DEFAULT 0 CHECK(invalidated IN (0,1)))',
      );
      await customStatement(
        'CREATE TABLE device_file_scope(singleton INTEGER PRIMARY KEY CHECK(singleton=1),server_id TEXT NOT NULL)',
      );
    },
    onUpgrade: (_, _, _) async =>
        throw const StorageFailure('unsupported_device_journal'),
  );
}
