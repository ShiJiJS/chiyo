import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:info_core/info_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'backup_publish.dart';
export 'platform_keys.dart';
part 'backups.dart';
part 'backup_history.dart';
part 'credentials_storage.dart';

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

InformationItem _informationFromRows(
  Map<String, Object?> row,
  Iterable<Map<String, Object?>> fields,
  Iterable<Map<String, Object?>> links,
) => InformationItem(
  row['id'] as String,
  row['name'] as String,
  row['description'] as String,
  row['version'] as int,
  [
    for (final field in fields.where((f) => f['item_id'] == row['id']))
      InformationField(
        field['id'] as String,
        field['name'] as String,
        field['description'] as String,
        field['value'] as String,
        field['version'] as int,
        kind: FieldKind.values.byName(field['kind'] as String),
      ),
  ],
  directoryId: row['directory_id'] as String?,
  createdAt: row['created_at'] == null
      ? null
      : DateTime.parse(row['created_at'] as String),
  modifiedAt: row['modified_at'] == null
      ? null
      : DateTime.parse(row['modified_at'] as String),
  tagIds: links
      .where((l) => l['item_id'] == row['id'])
      .map((l) => l['tag_id'] as String),
);

/// A desktop-only capability. The CLI depends on info_core, never this package.
class EncryptedInformationRepository
    implements InformationRepository, CredentialRepository {
  EncryptedInformationRepository._(
    this._db,
    this._lock,
    this.cipherVersion,
    this._clock,
  );
  final DateTime Function() _clock;
  final _InformationDatabase _db;
  final RandomAccessFile _lock;
  final String cipherVersion;
  final _items = <String, InformationItem>{};
  final _settings = <String, int>{};
  final _directories = <String, InformationDirectory>{};
  final _tags = <String, InformationTag>{};
  final _templates = <String, InformationTemplate>{};
  final _history = <String, GrantHistory>{};
  final _requestHistory = <String, RequestHistory>{};
  final _accesses = <String, AccessRecord>{};
  final _organizationTasks = <String, OrganizationTask>{};
  final _proposals = <String, ImportProposal>{};
  final _updates = <String, UpdateProposal>{};
  final _revisions = <InformationRevision>[];
  final _revisionPurges = <RevisionPurgeFact>[];
  final _recycle = <String, RecycleEntry>{};
  final _recycleFacts = <RecycleFact>[];
  final _deletes = <String, DeleteProposal>{};
  final _credentials = <ManagedCredential>[];
  final _credentialMaterials = <CredentialMaterial>[];
  @override
  List<ManagedCredential> get managedCredentials =>
      List.unmodifiable(_credentials);
  @override
  List<CredentialMaterial> get credentialMaterials =>
      List.unmodifiable(_credentialMaterials);
  @override
  Future<void> commitCredentials(
    List<ManagedCredential> credentials,
    List<CredentialMaterial> materials,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    _validateVault(credentials, materials);
    try {
      await _db.transaction(() async {
        await _db.customStatement('DELETE FROM credential_materials');
        await _db.customStatement('DELETE FROM managed_credentials');
        for (final c in credentials) {
          await _db.customStatement(
            'INSERT INTO managed_credentials(id,payload) VALUES(?,?)',
            [c.id, jsonEncode(c.toJson())],
          );
        }
        for (final m in materials) {
          await _db.customStatement(
            'INSERT INTO credential_materials(credential_id,version,payload) VALUES(?,?,?)',
            [m.credentialId, m.version, jsonEncode(m.toStorageJson())],
          );
        }
      });
      _credentials
        ..clear()
        ..addAll(credentials);
      _credentialMaterials
        ..clear()
        ..addAll(materials);
    } catch (_) {
      throw const StorageFailure('credential_save_failed');
    }
  }

  bool _closed = false;
  static final _openDirectories = <String>{};
  late final String _directory;
  late final backups = InformationBackups._(this);

  static Future<EncryptedInformationRepository> open(
    String directory,
    DatabaseKeyStore keys, {
    DateTime Function()? clock,
  }) async {
    final folder = Directory(directory);
    await folder.create(recursive: true);
    final canonical = await folder.resolveSymbolicLinks();
    if (!_openDirectories.add(canonical)) {
      throw const StorageFailure('library_in_use');
    }
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
      if (key.length != 32 || key.any((v) => v < 0 || v > 255)) {
        throw const StorageFailure('invalid_key');
      }
      // Probe before creating or opening the user's file: plaintext fallback is forbidden.
      final probe = sqlite.sqlite3.openInMemory();
      String version;
      try {
        final rows = probe.select('PRAGMA cipher_version');
        if (rows.isEmpty || !(rows.first.values.first is String)) {
          throw const StorageFailure('cipher_unavailable');
        }
        version = rows.first.values.first as String;
        if (!version.startsWith('4.')) {
          throw const StorageFailure('cipher_unavailable');
        }
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
      final repository = EncryptedInformationRepository._(
        db,
        lock,
        version,
        clock ?? DateTime.now,
      ).._directory = canonical;
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
    _credentials.clear();
    _credentialMaterials.clear();
    for (final row
        in await _db
            .customSelect(
              'SELECT payload FROM managed_credentials ORDER BY rowid',
            )
            .get()) {
      _credentials.add(
        ManagedCredential.fromJson(
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
        ),
      );
    }
    for (final row
        in await _db
            .customSelect(
              'SELECT payload FROM credential_materials ORDER BY rowid',
            )
            .get()) {
      _credentialMaterials.add(
        CredentialMaterial.fromStorageJson(
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
        ),
      );
    }
    final cutoff = _clock().subtract(const Duration(days: 30));
    final retained = _credentialMaterials
        .where((m) => m.retiredAt == null || m.retiredAt!.isAfter(cutoff))
        .toList();
    if (retained.length != _credentialMaterials.length) {
      await commitCredentials(_credentials.toList(), retained);
    }
    for (final row
        in await _db
            .customSelect(
              'SELECT payload FROM organization_tasks ORDER BY rowid',
            )
            .get()) {
      final task = OrganizationTask.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      _organizationTasks[task.id] = task;
    }

    for (final row
        in await _db
            .customSelect('SELECT * FROM revision_purge_facts ORDER BY rowid')
            .get()) {
      _revisionPurges.add(
        RevisionPurgeFact(
          row.read<String>('item_id'),
          row.read<int>('version'),
          DateTime.parse(row.read<String>('purged_at')),
        ),
      );
    }
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
    for (final row
        in await _db
            .customSelect('SELECT payload FROM request_history ORDER BY rowid')
            .get()) {
      final fact = RequestHistory.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      _requestHistory[fact.id] = fact;
    }
    for (final row
        in await _db
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
    final fieldRows = fields.map((row) => row.data).toList();
    final tagRows = itemTags.map((row) => row.data).toList();
    for (final item in items) {
      final decoded = _informationFromRows(item.data, fieldRows, tagRows);
      _items[decoded.id] = decoded;
    }
  }

  @override
  List<RequestHistory> get requestHistory {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_requestHistory.values);
  }

  @override
  Future<void> saveRequestHistory(RequestHistory history) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.customStatement(
        'INSERT INTO request_history(id,created_at,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
        [
          history.id,
          history.createdAt.toUtc().millisecondsSinceEpoch,
          jsonEncode(history.toJson()),
        ],
      );
      _requestHistory[history.id] = history;
    } on Object {
      throw const StorageFailure('audit_save_failed');
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
  Future<void> pruneOrganizationHistory(Set<String> ids) async {
    if (_closed) throw const StorageFailure('library_closed');
    if (ids.isEmpty) return;
    try {
      await _db.transaction(() async {
        for (final id in ids) {
          await _db.customStatement(
            'DELETE FROM organization_tasks WHERE id=?',
            [id],
          );
        }
      });
      _organizationTasks.removeWhere((id, _) => ids.contains(id));
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
          'DELETE FROM request_history WHERE created_at < ?',
          [cutoff.toUtc().millisecondsSinceEpoch],
        );
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
      _requestHistory.removeWhere((_, r) => r.createdAt.isBefore(cutoff));
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
  Future<void> deleteTemplate(String id) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.customStatement('DELETE FROM field_templates WHERE id=?', [id]);
      _templates.remove(id);
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
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

  Future<void> _writeDirectory(
    InformationDirectory directory,
  ) => _db.customStatement(
    'INSERT INTO information_directories(id,name,parent_id,version) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,parent_id=excluded.parent_id,version=excluded.version',
    [directory.id, directory.name, directory.parentId, directory.version],
  );
  Future<void> _writeTag(InformationTag tag) => _db.customStatement(
    'INSERT INTO information_tags(id,name,version) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,version=excluded.version',
    [tag.id, tag.name, tag.version],
  );

  @override
  Future<void> saveDirectory(InformationDirectory directory) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _writeDirectory(directory);
      _directories[directory.id] = directory;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  @override
  Future<void> saveTag(InformationTag tag) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _writeTag(tag);
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
      'INSERT INTO information_items(id,name,description,version,directory_id,created_at,modified_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,description=excluded.description,version=excluded.version,directory_id=excluded.directory_id,created_at=excluded.created_at,modified_at=excluded.modified_at',
      [
        item.id,
        item.name,
        item.description,
        item.version,
        item.directoryId,
        item.createdAt?.toUtc().toIso8601String(),
        item.modifiedAt?.toUtc().toIso8601String(),
      ],
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
  List<OrganizationTask> get organizationTasks {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_organizationTasks.values);
  }

  Future<void> _writeOrganizationTask(
    OrganizationTask task,
  ) => _db.customStatement(
    'INSERT INTO organization_tasks(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
    [task.id, jsonEncode(task.toJson())],
  );
  @override
  Future<void> saveOrganizationTask(OrganizationTask task) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _writeOrganizationTask(task);
      _organizationTasks[task.id] = task;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  @override
  Future<void> confirmOrganizationTask(
    OrganizationTask task,
    List<InformationItem> items,
    List<InformationRevision> previous, {
    List<InformationDirectory> newDirectories = const [],
    List<InformationTag> newTags = const [],
    void Function()? validate,
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        for (final d in newDirectories) {
          await _writeDirectory(d);
        }
        for (final t in newTags) {
          await _writeTag(t);
        }
        for (final i in items) {
          await _writeItem(i);
        }
        for (final r in previous) {
          await _writeRevision(r);
        }
        await _writeOrganizationTask(task);
        validate?.call();
      });
      for (final d in newDirectories) {
        _directories[d.id] = d;
      }
      for (final t in newTags) {
        _tags[t.id] = t;
      }
      for (final i in items) {
        _items[i.id] = i;
      }
      _revisions.addAll(previous);
      _organizationTasks[task.id] = task;
    } catch (_) {
      throw const StorageFailure('save_failed');
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
    List<InformationItem> items, {
    List<InformationDirectory> newDirectories = const [],
    List<InformationTag> newTags = const [],
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        for (final directory in newDirectories) {
          await _writeDirectory(directory);
        }
        for (final tag in newTags) {
          await _writeTag(tag);
        }
        for (final item in items) {
          await _writeItem(item);
        }
        await _writeProposal(proposal);
      });
      for (final directory in newDirectories) {
        _directories[directory.id] = directory;
      }
      for (final tag in newTags) {
        _tags[tag.id] = tag;
      }
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
    _requestHistory.clear();
    _accesses.clear();
    _organizationTasks.clear();
    _proposals.clear();
    _updates.clear();
    _revisions.clear();
    _revisionPurges.clear();
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

  @override
  List<RevisionPurgeFact> get revisionPurgeFacts {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_revisionPurges);
  }

  @override
  Future<void> pruneInformationRevisions(
    DateTime cutoff,
    DateTime purgedAt,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    final expired = _revisions
        .where((r) => !r.replacedAt.isAfter(cutoff))
        .toList();
    if (expired.isEmpty) return;
    try {
      await _db.transaction(() async {
        for (final revision in expired) {
          await _db.customStatement(
            'INSERT INTO revision_purge_facts(item_id,version,purged_at) VALUES(?,?,?) ON CONFLICT(item_id,version) DO NOTHING',
            [
              revision.item.id,
              revision.item.version,
              purgedAt.toUtc().toIso8601String(),
            ],
          );
          await _db.customStatement(
            'DELETE FROM information_revisions WHERE item_id=? AND version=?',
            [revision.item.id, revision.item.version],
          );
        }
      });
      for (final revision in expired) {
        _revisionPurges.add(
          RevisionPurgeFact(revision.item.id, revision.item.version, purgedAt),
        );
      }
      _revisions.removeWhere((r) => !r.replacedAt.isAfter(cutoff));
    } catch (_) {
      throw const StorageFailure('revision_cleanup_failed');
    }
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
  int get schemaVersion => 14;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await _createCredentials();
      await _createRevisionPurges();
      await _createRecycle();
      await _createAudit();
      await _createRequestHistory();
      await _createUpdates();
      await _createProposals();
      await _createOrganizationTasks();
      await _createTemplates();
      await customStatement(
        'CREATE TABLE settings(name TEXT PRIMARY KEY,value INTEGER NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE information_items(id TEXT PRIMARY KEY,name TEXT NOT NULL,description TEXT NOT NULL,version INTEGER NOT NULL DEFAULT 1,created_at TEXT,modified_at TEXT)',
      );
      await customStatement(
        'CREATE TABLE information_fields(id TEXT PRIMARY KEY,item_id TEXT NOT NULL REFERENCES information_items(id),name TEXT NOT NULL,description TEXT NOT NULL,value TEXT NOT NULL,version INTEGER NOT NULL DEFAULT 1,kind TEXT NOT NULL DEFAULT \'structured\')',
      );
      await _organizationSchema();
      await _backupSchema();
    },
    onUpgrade: (_, from, to) async {
      if (from < 1 || to != 14) {
        throw const StorageFailure('unsupported_schema');
      }
      await transaction(() async {
        if (from < 14) await _createCredentials();
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
        if (from < 5) await _backupSchema();
        if (from < 6) await _createProposals();
        if (from < 7) await _createAudit();
        if (from < 8) await _createUpdates();
        if (from < 9) await _createRecycle();
        if (from < 10) await _createRevisionPurges();
        if (from < 12) await _createOrganizationTasks();
        if (from < 13) await _createRequestHistory();
        if (from < 11) {
          await customStatement(
            'ALTER TABLE information_items ADD COLUMN created_at TEXT',
          );
          await customStatement(
            'ALTER TABLE information_items ADD COLUMN modified_at TEXT',
          );
        }
      });
    },
    beforeOpen: (details) async {
      if (details.versionNow > schemaVersion) {
        throw const StorageFailure('unsupported_schema');
      }
      // Some pre-merge development schema 6 databases reserved version 5 but
      // did not create its backup table. Backfill only this additive structure.
      await _backupSchema();
      // An unpublished development schema 8 preceded the reserved audit
      // tables. Backfill only after rejecting unknown future versions.
      await _createAudit();
    },
  );

  Future<void> _createRevisionPurges() => customStatement(
    'CREATE TABLE revision_purge_facts(item_id TEXT NOT NULL,version INTEGER NOT NULL,purged_at TEXT NOT NULL,PRIMARY KEY(item_id,version))',
  );
  Future<void> _createCredentials() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS managed_credentials(id TEXT PRIMARY KEY,payload TEXT NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS credential_materials(credential_id TEXT NOT NULL,version INTEGER NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(credential_id,version))',
    );
  }

  Future<void> _createRequestHistory() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS request_history(id TEXT PRIMARY KEY,created_at INTEGER NOT NULL,payload TEXT NOT NULL)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS request_history_retention ON request_history(created_at)',
    );
  }

  Future<void> _createRecycle() async {
    await customStatement(
      'CREATE TABLE recycle_entries(id TEXT PRIMARY KEY,payload TEXT NOT NULL)',
    );
    await customStatement('CREATE TABLE recycle_facts(payload TEXT NOT NULL)');
    await customStatement(
      'CREATE TABLE delete_proposals(id TEXT PRIMARY KEY,payload TEXT NOT NULL)',
    );
  }

  Future<void> _createOrganizationTasks() => customStatement(
    'CREATE TABLE organization_tasks(id TEXT PRIMARY KEY,payload TEXT NOT NULL)',
  );

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

  Future<void> _backupSchema() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS backup_configuration(singleton INTEGER PRIMARY KEY CHECK(singleton=1),recovery_key TEXT NOT NULL,recovery_saved INTEGER NOT NULL DEFAULT 0)',
    );
    final columns = await customSelect(
      'PRAGMA table_info(backup_configuration)',
    ).get();
    if (!columns.any((row) => row.read<String>('name') == 'recovery_saved')) {
      await customStatement(
        'ALTER TABLE backup_configuration ADD COLUMN recovery_saved INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

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
