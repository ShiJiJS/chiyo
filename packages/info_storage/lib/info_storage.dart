import 'dart:io';
import 'dart:convert';
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
  final _directories = <String, InformationDirectory>{};
  final _tags = <String, InformationTag>{};
  final _templates = <String, InformationTemplate>{};
  final _history = <String, GrantHistory>{};
  final _accesses = <String, AccessRecord>{};
  final _proposals = <String, ImportProposal>{};
  final _updates = <String, UpdateProposal>{};
  final _revisions = <InformationRevision>[];
  final _recycle = <String, RecycleEntry>{};
  final _recycleFacts = <RecycleFact>[];
  final _deletes = <String, DeleteProposal>{};
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
        final random = Random.secure();
        key = List.generate(32, (_) => random.nextInt(256));
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
        probe.close();
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
      native?.close();
      await lock?.close();
      _openDirectories.remove(canonical);
      if (error is StorageFailure) rethrow;
      throw const StorageFailure('library_unavailable');
    }
  }

  Future<void> _load() async {
    for (final row
        in await _db
            .customSelect('SELECT payload FROM recycle_entries ORDER BY rowid')
            .get()) {
      final entry = RecycleEntry.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      _recycle[entry.id] = entry;
    }
    for (final row
        in await _db
            .customSelect('SELECT payload FROM recycle_facts ORDER BY rowid')
            .get()) {
      _recycleFacts.add(
        RecycleFact.fromJson(
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
        ),
      );
    }
    for (final row
        in await _db
            .customSelect('SELECT payload FROM delete_proposals ORDER BY rowid')
            .get()) {
      final proposal = DeleteProposal.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      _deletes[proposal.id] = proposal;
    }
    for (final row in await _db
            .customSelect('SELECT payload FROM grant_history ORDER BY rowid')
            .get()) {
      final history = GrantHistory.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      _history[history.id] = history;
    }
    for (final row
        in await _db
            .customSelect('SELECT payload FROM access_records ORDER BY rowid')
            .get()) {
      final record = AccessRecord.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      _accesses[record.id] = record;
    }
    for (final row
        in await _db
            .customSelect('SELECT payload FROM update_proposals ORDER BY rowid')
            .get()) {
      final proposal = UpdateProposal.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      _updates[proposal.id] = proposal;
    }
    for (final row
        in await _db
            .customSelect(
              'SELECT payload,replaced_at FROM information_revisions ORDER BY rowid',
            )
            .get()) {
      _revisions.add(
        InformationRevision(
          informationFromJson(
            jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
          ),
          DateTime.parse(row.read<String>('replaced_at')),
        ),
      );
    }
    for (final row
        in await _db
            .customSelect('SELECT payload FROM import_proposals ORDER BY rowid')
            .get()) {
      final proposal = ImportProposal.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      _proposals[proposal.id] = proposal;
      if (proposal.state != ImportProposalState.pending) {
        // Scrub values retained by earlier development versions. Pending work
        // remains untouched; terminal receipts do not depend on current items.
        await _writeProposal(proposal);
      }
    }
    for (final row
        in await _db
            .customSelect(
              'SELECT * FROM information_directories ORDER BY rowid',
            )
            .get()) {
      final value = InformationDirectory(
        row.read<String>('id'),
        row.read<String>('name'),
        row.readNullable<String>('parent_id'),
        row.read<int>('version'),
      );
      _directories[value.id] = value;
    }
    for (final row
        in await _db
            .customSelect('SELECT * FROM information_tags ORDER BY rowid')
            .get()) {
      final value = InformationTag(
        row.read<String>('id'),
        row.read<String>('name'),
        row.read<int>('version'),
      );
      _tags[value.id] = value;
    }
    final itemTags = await _db
        .customSelect('SELECT * FROM information_item_tags ORDER BY rowid')
        .get();
    for (final row
        in await _db
            .customSelect('SELECT * FROM field_templates ORDER BY rowid')
            .get()) {
      final fields = (jsonDecode(row.read<String>('fields_json')) as List)
          .cast<Map<String, dynamic>>();
      final template = InformationTemplate(
        row.read<String>('id'),
        row.read<String>('name'),
        row.read<String>('description'),
        row.read<int>('version'),
        fields.map(
          (f) => TemplateFieldDefinition(
            f['id'] as String,
            f['name'] as String,
            f['description'] as String,
            FieldKind.values.byName(f['kind'] as String),
          ),
        ),
      );
      _templates[template.id] = template;
    }
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
                kind: FieldKind.values.byName(f.read<String>('kind')),
              ),
            )
            .toList(),
        directoryId: item.readNullable<String>('directory_id'),
        tagIds: itemTags
            .where((t) => t.read<String>('item_id') == id)
            .map((t) => t.read<String>('tag_id')),
      );
    }
  }

  @override
  List<GrantHistory> get grantHistory {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_history.values);
  }

  @override
  List<AccessRecord> get accessRecords {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_accesses.values);
  }

  @override
  Future<void> saveGrantHistory(GrantHistory history) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.customStatement(
        'INSERT INTO grant_history(id,approved_at,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
        [
          history.id,
          history.approvedAt.toUtc().millisecondsSinceEpoch,
          jsonEncode(history.toJson()),
        ],
      );
      _history[history.id] = history;
    } on Object {
      throw const StorageFailure('audit_save_failed');
    }
  }

  @override
  Future<void> saveAccessRecord(AccessRecord record) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.customStatement(
        'INSERT INTO access_records(id,recorded_at,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
        [
          record.id,
          record.at.toUtc().millisecondsSinceEpoch,
          jsonEncode(record.toJson()),
        ],
      );
      _accesses[record.id] = record;
    } on Object {
      throw const StorageFailure('audit_save_failed');
    }
  }

  @override
  Future<void> pruneAudit(DateTime cutoff) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        await _db.customStatement(
          'DELETE FROM grant_history WHERE approved_at < ?',
          [cutoff.toUtc().millisecondsSinceEpoch],
        );
        await _db.customStatement(
          'DELETE FROM access_records WHERE recorded_at < ?',
          [cutoff.toUtc().millisecondsSinceEpoch],
        );
      });
      _history.removeWhere((_, h) => h.approvedAt.isBefore(cutoff));
      _accesses.removeWhere((_, a) => a.at.isBefore(cutoff));
    } on Object {
      throw const StorageFailure('audit_save_failed');
    }
  }

  @override
  List<InformationTemplate> get templates {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_templates.values);
  }

  @override
  Future<void> saveTemplate(InformationTemplate template) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.customStatement(
        'INSERT INTO field_templates(id,name,description,version,fields_json) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,description=excluded.description,version=excluded.version,fields_json=excluded.fields_json',
        [
          template.id,
          template.name,
          template.description,
          template.version,
          jsonEncode(
            template.fields
                .map(
                  (f) => {
                    'id': f.id,
                    'name': f.name,
                    'description': f.description,
                    'kind': f.kind.name,
                  },
                )
                .toList(),
          ),
        ],
      );
      _templates[template.id] = template;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  @override
  List<InformationItem> get items {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_items.values);
  }

  @override
  List<InformationDirectory> get directories {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_directories.values);
  }

  @override
  List<InformationTag> get tags {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_tags.values);
  }

  @override
  Future<void> saveDirectory(InformationDirectory directory) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.customStatement(
        'INSERT INTO information_directories(id,name,parent_id,version) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,parent_id=excluded.parent_id,version=excluded.version',
        [directory.id, directory.name, directory.parentId, directory.version],
      );
      _directories[directory.id] = directory;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  @override
  Future<void> saveTag(InformationTag tag) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.customStatement(
        'INSERT INTO information_tags(id,name,version) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,version=excluded.version',
        [tag.id, tag.name, tag.version],
      );
      _tags[tag.id] = tag;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
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
        await _writeItem(item);
      });
      _items[item.id] = item;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  Future<void> _writeItem(InformationItem item) async {
    await _db.customStatement(
      'INSERT INTO information_items(id,name,description,version,directory_id) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,description=excluded.description,version=excluded.version,directory_id=excluded.directory_id',
      [item.id, item.name, item.description, item.version, item.directoryId],
    );
    await _db.customStatement(
      'DELETE FROM information_item_tags WHERE item_id=?',
      [item.id],
    );
    for (final tag in item.tagIds) {
      await _db.customStatement(
        'INSERT INTO information_item_tags(item_id,tag_id) VALUES(?,?)',
        [item.id, tag],
      );
    }
    await _db.customStatement(
      'DELETE FROM information_fields WHERE item_id=?',
      [item.id],
    );
    for (final field in item.fields) {
      await _db.customStatement(
        'INSERT INTO information_fields(id,item_id,name,description,value,version,kind) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,description=excluded.description,value=excluded.value,version=excluded.version,kind=excluded.kind',
        [
          field.id,
          item.id,
          field.name,
          field.description,
          field.value,
          field.version,
          field.kind.name,
        ],
      );
    }
  }

  @override
  List<ImportProposal> get importProposals {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_proposals.values);
  }

  Future<void> _writeProposal(ImportProposal proposal) => _db.customStatement(
    'INSERT INTO import_proposals(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
    [proposal.id, jsonEncode(proposal.toJson())],
  );

  @override
  Future<void> saveImportProposal(ImportProposal proposal) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _writeProposal(proposal);
      _proposals[proposal.id] = proposal;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  @override
  Future<void> confirmImportProposal(
    ImportProposal proposal,
    List<InformationItem> items,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        for (final item in items) {
          await _writeItem(item);
        }
        await _writeProposal(proposal);
      });
      for (final item in items) {
        _items[item.id] = item;
      }
      _proposals[proposal.id] = proposal;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _items.clear();
    _directories.clear();
    _tags.clear();
    _templates.clear();
    _history.clear();
    _accesses.clear();
    _proposals.clear();
    _updates.clear();
    _revisions.clear();
    try {
      await _db.close();
    } finally {
      await _lock.close();
      _openDirectories.remove(_directory);
    }
  }

  @override
  List<UpdateProposal> get updateProposals {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_updates.values);
  }

  @override
  List<InformationRevision> get informationRevisions {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_revisions);
  }

  Future<void> _writeUpdate(UpdateProposal proposal) => _db.customStatement(
    'INSERT INTO update_proposals(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
    [proposal.id, jsonEncode(proposal.toJson())],
  );
  Future<void> _writeRevision(
    InformationRevision revision,
  ) => _db.customStatement(
    'INSERT INTO information_revisions(item_id,version,replaced_at,payload) VALUES(?,?,?,?)',
    [
      revision.item.id,
      revision.item.version,
      revision.replacedAt.toUtc().toIso8601String(),
      jsonEncode(informationToJson(revision.item)),
    ],
  );
  @override
  Future<void> saveUpdateProposal(UpdateProposal proposal) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _writeUpdate(proposal);
      _updates[proposal.id] = proposal;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  @override
  Future<void> saveInformationRevision(
    InformationItem item,
    InformationRevision previous,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        await _writeItem(item);
        await _writeRevision(previous);
      });
      _items[item.id] = item;
      _revisions.add(previous);
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  @override
  Future<void> confirmUpdateProposal(
    UpdateProposal proposal,
    InformationItem item,
    InformationRevision previous, {
    List<RecycleEntry> recycled = const [],
    List<RecycleFact> facts = const [],
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        await _writeItem(item);
        await _writeRevision(previous);
        await _writeUpdate(proposal);
        await _writeRecycle(recycled, facts);
      });
      _items[item.id] = item;
      _revisions.add(previous);
      _updates[proposal.id] = proposal;
      for (final entry in recycled) {
        _recycle[entry.id] = entry;
      }
      _recycleFacts.addAll(facts);
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  @override
  List<RecycleEntry> get recycleEntries {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_recycle.values);
  }

  @override
  List<RecycleFact> get recycleFacts {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_recycleFacts);
  }

  @override
  List<DeleteProposal> get deleteProposals {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_deletes.values);
  }

  Future<void> _writeDelete(DeleteProposal proposal) => _db.customStatement(
    'INSERT INTO delete_proposals(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
    [proposal.id, jsonEncode(proposal.toJson())],
  );
  @override
  Future<void> saveDeleteProposal(DeleteProposal proposal) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _writeDelete(proposal);
      _deletes[proposal.id] = proposal;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  Future<void> _writeRecycle(
    List<RecycleEntry> entries,
    List<RecycleFact> facts,
  ) async {
    for (final entry in entries) {
      await _db.customStatement(
        'INSERT INTO recycle_entries(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
        [entry.id, jsonEncode(entry.toJson())],
      );
    }
    for (final fact in facts) {
      await _db.customStatement(
        'INSERT INTO recycle_facts(payload) VALUES(?)',
        [jsonEncode(fact.toJson())],
      );
    }
  }

  @override
  Future<void> commitRecycleChange({
    required String itemId,
    InformationItem? item,
    InformationRevision? previous,
    required List<RecycleEntry> entries,
    required List<RecycleFact> facts,
    DeleteProposal? proposal,
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        if (item != null) {
          await _writeItem(item);
        } else {
          await _db.customStatement(
            'DELETE FROM information_item_tags WHERE item_id=?',
            [itemId],
          );
          await _db.customStatement(
            'DELETE FROM information_fields WHERE item_id=?',
            [itemId],
          );
          await _db.customStatement(
            'DELETE FROM information_items WHERE id=?',
            [itemId],
          );
        }
        if (previous != null) await _writeRevision(previous);
        await _writeRecycle(entries, facts);
        if (proposal != null) await _writeDelete(proposal);
      });
      if (item == null) {
        _items.remove(itemId);
      } else {
        _items[itemId] = item;
      }
      if (previous != null) _revisions.add(previous);
      for (final entry in entries) {
        _recycle[entry.id] = entry;
      }
      _recycleFacts.addAll(facts);
      if (proposal != null) _deletes[proposal.id] = proposal;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }
}

class _InformationDatabase extends GeneratedDatabase {
  _InformationDatabase(super.executor);
  @override
  int get schemaVersion => 9;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await _createRecycle();
      await _createAudit();
      await _createUpdates();
      await _createProposals();
      await _createTemplates();
      await customStatement(
        'CREATE TABLE settings(name TEXT PRIMARY KEY,value INTEGER NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE information_items(id TEXT PRIMARY KEY,name TEXT NOT NULL,description TEXT NOT NULL,version INTEGER NOT NULL DEFAULT 1)',
      );
      await customStatement(
        'CREATE TABLE information_fields(id TEXT PRIMARY KEY,item_id TEXT NOT NULL REFERENCES information_items(id),name TEXT NOT NULL,description TEXT NOT NULL,value TEXT NOT NULL,version INTEGER NOT NULL DEFAULT 1,kind TEXT NOT NULL DEFAULT \'structured\')',
      );
      await _organizationSchema();
    },
    onUpgrade: (_, from, to) async {
      if (from < 1 || to != 9) throw const StorageFailure('unsupported_schema');
      await transaction(() async {
        if (from < 2) {
          await customStatement(
            'CREATE TABLE settings(name TEXT PRIMARY KEY,value INTEGER NOT NULL)',
          );
          await customStatement(
            'ALTER TABLE information_items ADD COLUMN version INTEGER NOT NULL DEFAULT 1',
          );
          await customStatement(
            'ALTER TABLE information_fields ADD COLUMN version INTEGER NOT NULL DEFAULT 1',
          );
        }
        if (from < 3) await _organizationSchema();
        if (from < 4) {
          await _createTemplates();
          await customStatement(
            'ALTER TABLE information_fields ADD COLUMN kind TEXT NOT NULL DEFAULT \'structured\'',
          );
        }
        // Schema 5 is reserved for the independent backup configuration.
        if (from < 6) await _createProposals();
        if (from < 7) await _createAudit();
        if (from < 8) await _createUpdates();
        if (from < 9) await _createRecycle();
      });
    },
    beforeOpen: (details) async {
      if (details.versionNow > schemaVersion)
        throw const StorageFailure('unsupported_schema');
      // An unpublished development schema 8 preceded the reserved audit
      // tables. Backfill only after rejecting unknown future versions.
      await _createAudit();
    },
  );

  Future<void> _createRecycle() async {
    await customStatement(
      'CREATE TABLE recycle_entries(id TEXT PRIMARY KEY,payload TEXT NOT NULL)',
    );
    await customStatement('CREATE TABLE recycle_facts(payload TEXT NOT NULL)');
    await customStatement(
      'CREATE TABLE delete_proposals(id TEXT PRIMARY KEY,payload TEXT NOT NULL)',
    );
  }

  Future<void> _createProposals() => customStatement(
    'CREATE TABLE import_proposals(id TEXT PRIMARY KEY,payload TEXT NOT NULL)',
  );
  Future<void> _createUpdates() async {
    await customStatement(
      'CREATE TABLE update_proposals(id TEXT PRIMARY KEY,payload TEXT NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE information_revisions(item_id TEXT NOT NULL,version INTEGER NOT NULL,replaced_at TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(item_id,version))',
    );
  }

  Future<void> _organizationSchema() async {
    await customStatement(
      'CREATE TABLE information_directories(id TEXT PRIMARY KEY,name TEXT NOT NULL,parent_id TEXT REFERENCES information_directories(id),version INTEGER NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE information_tags(id TEXT PRIMARY KEY,name TEXT NOT NULL,version INTEGER NOT NULL)',
    );
    await customStatement(
      'ALTER TABLE information_items ADD COLUMN directory_id TEXT REFERENCES information_directories(id)',
    );
    await customStatement(
      'CREATE TABLE information_item_tags(item_id TEXT NOT NULL REFERENCES information_items(id),tag_id TEXT NOT NULL REFERENCES information_tags(id),PRIMARY KEY(item_id,tag_id))',
    );
  }

  Future<void> _createTemplates() => customStatement(
    'CREATE TABLE field_templates(id TEXT PRIMARY KEY,name TEXT NOT NULL,description TEXT NOT NULL,version INTEGER NOT NULL,fields_json TEXT NOT NULL)',
  );

  Future<void> _createAudit() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS grant_history(id TEXT PRIMARY KEY,approved_at INTEGER NOT NULL,payload TEXT NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS access_records(id TEXT PRIMARY KEY,recorded_at INTEGER NOT NULL,payload TEXT NOT NULL)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS grant_history_retention ON grant_history(approved_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS access_records_retention ON access_records(recorded_at)',
    );
  }
}
