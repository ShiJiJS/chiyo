part of 'info_storage.dart';

InstalledTemplatePackage _templatePackageFromRow(Map<String, Object?> row) {
  final source = row['source'] as String?;
  if (source != null &&
      source.length >
          ((DeclarativeTemplatePackageDecoder.maxBytes + 2) ~/ 3) * 4) {
    throw const StorageFailure('invalid_package');
  }
  final bytes = source == null ? null : base64Decode(source);
  if (bytes != null && base64Encode(bytes) != source) {
    throw const StorageFailure('invalid_package');
  }
  final enabled = row['enabled'];
  if (enabled != 0 && enabled != 1) {
    throw const StorageFailure('invalid_package');
  }
  return InstalledTemplatePackage(
    id: row['id'] as String,
    enabled: enabled == 1,
    origin: row['origin'] as String,
    bytes: bytes,
    legacySource: row['legacy_json'] == null
        ? null
        : Map<String, Object?>.from(
            jsonDecode(row['legacy_json'] as String) as Map,
          ),
  );
}

extension _TemplatePackageStorage on EncryptedInformationRepository {
  Future<void> _requireTemplatePackageFormat() async {
    final row = await _db
        .customSelect('SELECT version FROM library_format WHERE singleton=1')
        .getSingle();
    if (row.read<int>('version') >= _templatePackageLibraryFormat) return;
    await _db.customStatement(
      'UPDATE library_format SET version=? WHERE singleton=1',
      [_templatePackageLibraryFormat],
    );
    await _db.customStatement(
      'PRAGMA user_version = $_templatePackageLibraryFormat',
    );
  }

  Future<void> _loadTemplatePackages() async {
    _templatePackages.clear();
    final rows = await _db
        .customSelect('SELECT * FROM template_packages ORDER BY id')
        .get();
    final marker = await _db
        .customSelect('SELECT version FROM library_format WHERE singleton=1')
        .getSingle();
    if (rows.isNotEmpty &&
        marker.read<int>('version') < _templatePackageLibraryFormat) {
      throw const StorageFailure('unsupported_schema');
    }
    if (rows.length > 100) throw const StorageFailure('invalid_package');
    try {
      for (final row in rows) {
        final p = _templatePackageFromRow(row.data);
        _templatePackages[p.id] = p;
      }
    } on Object {
      throw const StorageFailure('invalid_package');
    }
  }

  Future<TemplatePackageReceipt?> _templateReceipt(String id) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT payload,invalidated FROM template_package_operations WHERE operation_id=?',
          variables: [Variable(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    if (rows.single.read<int>('invalidated') != 0) {
      throw const AccessFailure('library_changed');
    }
    final r = TemplatePackageReceipt.fromJson(
      jsonDecode(rows.single.read<String>('payload')) as Map<String, dynamic>,
    );
    if (r.command.operationId != id) {
      throw const StorageFailure('invalid_operation_receipt');
    }
    return r;
  }

  Future<void> _commitTemplatePackage(
    TemplatePackageReceipt receipt,
    InstalledTemplatePackage? package,
    void Function() validate,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        validate();
        final rows = await _db
            .customSelect(
              "SELECT value FROM settings WHERE name='templateCatalogVersion'",
            )
            .get();
        if ((rows.isEmpty ? 1 : rows.single.read<int>('value')) !=
            receipt.command.expectedVersion) {
          throw const AccessFailure('catalog_changed');
        }
        await _requireTemplatePackageFormat();
        if (package == null) {
          await _db.customStatement(
            'DELETE FROM template_packages WHERE id=?',
            [receipt.command.packageId],
          );
        } else {
          await _db.customStatement(
            'INSERT INTO template_packages(id,source,enabled,origin,legacy_json) VALUES(?,?,?,?,?) '
            'ON CONFLICT(id) DO UPDATE SET source=excluded.source,enabled=excluded.enabled,origin=excluded.origin,legacy_json=excluded.legacy_json',
            [
              package.id,
              package.bytes == null ? null : base64Encode(package.bytes!),
              package.enabled ? 1 : 0,
              package.origin,
              package.legacySource == null
                  ? null
                  : jsonEncode(package.legacySource),
            ],
          );
        }
        await _db.customStatement(
          "INSERT INTO settings(name,value) VALUES('templateCatalogVersion',?) ON CONFLICT(name) DO UPDATE SET value=excluded.value",
          [receipt.version],
        );
        await _db.customStatement(
          'INSERT INTO template_package_operations(operation_id,payload) VALUES(?,?)',
          [receipt.command.operationId, jsonEncode(receipt.toJson())],
        );
        await _checkAttachmentBackupBudget();
        validate();
      });
      _settings['templateCatalogVersion'] = receipt.version;
      if (package == null) {
        _templatePackages.remove(receipt.command.packageId);
      } else {
        _templatePackages[package.id] = package;
      }
    } on AccessFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('save_failed');
    }
  }
}
