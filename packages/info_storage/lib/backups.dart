part of 'info_storage.dart';

/// A fully authenticated and validated snapshot, held in memory.
/// It carries no usable grant, pending request or source database key.
class BackupContents {
  BackupContents._(
    this._tables,
    this.createdAt,
    this.formatVersion, {
    this.attachments = const [],
    _AttachmentBackupOrigin? origin,
  }) : _origin = origin;
  final Map<String, List<Map<String, Object?>>> _tables;
  final List<InformationAttachmentVersion> attachments;
  final _AttachmentBackupOrigin? _origin;
  final DateTime createdAt;
  final int formatVersion;
  int get informationCount => _tables['information_items']!.length;
  int get directoryCount => _tables['information_directories']!.length;
  int get directoryRecycleBatchCount =>
      _tables['library_recycle_batches']?.where((row) {
        final b = LibraryRecycleBatch.fromJson(_backupJson(row));
        return b.state == RecycleState.available &&
            createdAt.isBefore(b.expiresAt);
      }).length ??
      0;
  int get tagCount => _tables['information_tags']!.length;
  int get templateCount => _tables['field_templates']!.length;
  int get templatePackageCount => _tables['template_packages']?.length ?? 0;
  int get templatePackageTemplateCount =>
      (_tables['template_packages'] ?? const <Map<String, Object?>>[]).fold(
        0,
        (n, row) =>
            n +
            (_templatePackageFromRow(row).definition?.templates.length ?? 0),
      );
  int get revisionCount =>
      _tables['information_revisions']!.length +
      (_tables['information_revision_snapshots']?.length ?? 0);
  int get recycleCount => _tables['recycle_entries']!
      .where((r) => jsonDecode(r['payload'] as String)['state'] == 'available')
      .length;
  int get grantHistoryCount => _tables['grant_history']!.length;
  int get accessRecordCount => _tables['access_records']!.length;
  int get requestHistoryCount => _tables['request_history']!.length;
  int get credentialCount => _tables['managed_credentials']!.length;
  int get credentialVersionCount =>
      _tables['credential_materials']!.length +
      (_tables['credential_material_snapshots']?.length ?? 0);
  int get credentialUseHistoryCount =>
      _tables['credential_use_requests']!.length +
      (_tables['credential_batches']?.length ?? 0);
  int get credentialExecutionCount =>
      _tables['credential_executions']!.length +
      (_tables['credential_batch_operations']?.length ?? 0) +
      (_tables['credential_program_operations']?.length ?? 0);
  int get focusedFillCount => _tables['credential_focused_fills']!.length;
  int get sshTrustCount => _tables['ssh_host_trust']!.length;
  int get attachmentCount => attachments.where((v) => v.available).length;
  int get currentAttachmentCount =>
      _tables['information_file_fields']?.length ?? 0;
  int get attachmentBytes => attachments
      .where((v) => v.available)
      .fold(0, (sum, v) => sum + v.byteLength);
  int get fileDeliveryCount => _tables['information_deliveries']?.length ?? 0;
}

/// Private counts from the exact snapshot that was successfully published.
/// Contains neither recovery material nor a reusable snapshot/source handle.
final class BackupExportSummary {
  BackupExportSummary._(BackupContents snapshot)
    : currentAttachmentCount = snapshot.currentAttachmentCount,
      attachmentCount = snapshot.attachmentCount,
      attachmentBytes = snapshot.attachmentBytes,
      fileDeliveryCount = snapshot.fileDeliveryCount;
  final int currentAttachmentCount,
      attachmentCount,
      attachmentBytes,
      fileDeliveryCount;
}

/// Owner-only manual backup capability. It is never part of the agent server.
/// All supported payload versions use the existing SQLCipher 4 envelope.
class InformationBackups {
  InformationBackups._(EncryptedInformationRepository repository)
    : _repositoryValue = repository,
      _db = repository._db,
      _isClosed = (() => repository._closed),
      _preparedVerifier = null;

  /// Device publication uses the original journal/state machine and native
  /// publisher, but has no information repository, recovery key or snapshots.
  InformationBackups._device(this._db, this._isClosed, this._preparedVerifier)
    : _repositoryValue = null;
  final EncryptedInformationRepository? _repositoryValue;
  EncryptedInformationRepository get _repository =>
      _repositoryValue ??
      (throw const StorageFailure('unsupported_capability'));
  final GeneratedDatabase _db;
  final bool Function() _isClosed;
  final Future<Map<String, int>> Function(
    String id,
    BackupOutputAction action,
    String commandDigest,
    MacBackupPublication publication,
  )?
  _preparedVerifier;
  final _preparedBackupOutputs = <String>{};
  final _activeBackupOutputs = <String>{};
  static const _keyPrefix = 'aim-recovery-v1:';
  static const _format = 'agent-info-manage-current-data';
  static const maxFileBytes = 128 * 1024 * 1024;
  static const maxPayloadBytes = 64 * 1024 * 1024;
  static const _itemColumns = [
    'id',
    'name',
    'description',
    'version',
    'directory_id',
  ];
  static const _columns = <String, List<String>>{
    'information_directories': ['id', 'name', 'parent_id', 'version'],
    'information_tags': ['id', 'name', 'version'],
    'field_templates': ['id', 'name', 'description', 'version', 'fields_json'],
    'information_items': _itemColumns,
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
  static const _historyColumns = <String, List<String>>{
    'information_revisions': ['item_id', 'version', 'replaced_at', 'payload'],
    'recycle_entries': ['id', 'payload'],
    'recycle_facts': ['payload'],
    'revision_purge_facts': ['item_id', 'version', 'purged_at'],
    'grant_history': ['id', 'approved_at', 'payload'],
    'access_records': ['id', 'recorded_at', 'payload'],
  };
  static const _v2Columns = {..._columns, ..._historyColumns};
  static final _v3Columns = Map<String, List<String>>.unmodifiable({
    ..._v2Columns,
    'information_items': [..._itemColumns, 'created_at', 'modified_at'],
  });
  static final _v4Columns = Map<String, List<String>>.unmodifiable({
    ..._v3Columns,
    'request_history': ['id', 'created_at', 'payload'],
  });
  static const _credentialColumns = <String, List<String>>{
    'managed_credentials': ['id', 'payload'],
    'credential_materials': ['credential_id', 'version', 'payload'],
    'ssh_host_trust': ['id', 'payload'],
    'credential_use_requests': ['id', 'payload'],
    'credential_executions': ['id', 'request_id', 'payload'],
  };
  static final _v6Columns = Map<String, List<String>>.unmodifiable({
    ..._v4Columns,
    ..._credentialColumns,
  });
  static final _allColumns = Map<String, List<String>>.unmodifiable({
    ..._v6Columns,
    'credential_focused_fills': ['id', 'request_id', 'payload'],
  });
  static final _v8Columns = Map<String, List<String>>.unmodifiable({
    ..._allColumns,
    'information_file_fields': [
      'field_id',
      'attachment_id',
      'attachment_version',
    ],
  });
  static final _v9Columns = Map<String, List<String>>.unmodifiable({
    ..._v8Columns,
    'information_deliveries': ['id', 'payload'],
  });

  static final _v12Columns = Map<String, List<String>>.unmodifiable({
    ..._v9Columns,
    'information_items': [..._v3Columns['information_items']!, 'layout_json'],
  });
  static final _v15Columns = Map<String, List<String>>.unmodifiable({
    ..._v12Columns,
    'template_packages': ['id', 'source', 'enabled', 'origin', 'legacy_json'],
  });

  static final _v20Columns = Map<String, List<String>>.unmodifiable({
    ..._v15Columns,
    'library_recycle_batches': ['id', 'payload'],
  });
  static final _v21Columns = Map<String, List<String>>.unmodifiable({
    ..._v20Columns,
    'library_order_state': ['id', 'payload'],
  });

  static final _v25Columns = Map<String, List<String>>.unmodifiable({
    ..._v21Columns,
    'information_revision_snapshots': [
      'item_id',
      'version',
      'snapshot_id',
      'replaced_at',
      'payload',
    ],
  });

  static final _v26Columns = Map<String, List<String>>.unmodifiable({
    ..._v25Columns,
    'credential_material_snapshots': [
      'credential_id',
      'version',
      'snapshot_id',
      'payload',
    ],
  });
  static final _v28Columns = Map<String, List<String>>.unmodifiable({
    ..._v26Columns,
    'credential_batches': ['id', 'session_binding', 'operation_id', 'payload'],
    'credential_batch_operations': [
      'session_binding',
      'operation_id',
      'request_id',
      'payload',
    ],
  });
  static final _v29Columns = Map<String, List<String>>.unmodifiable({
    ..._v28Columns,
    'credential_program_operations': [
      'execution_id',
      'session_binding',
      'operation_id',
      'request_id',
      'payload',
    ],
  });

  // Portable formats 1–7 keep their table keys independent of the schema17+
  // physical names. Legacy readers must not find a writable old runtime table.
  static const _physicalTables = {
    'credential_use_requests': 'credential_runtime_requests',
    'credential_executions': 'credential_operations',
  };

  void _checkOpen() {
    if (_isClosed()) throw const StorageFailure('library_closed');
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
        await _advanceOperationVersion();
        return key;
      });
    } catch (_) {
      throw const StorageFailure('backup_key_unavailable');
    }
  }

  Future<bool> recoveryKeySaved() async {
    _checkOpen();
    final rows = await _repository._db
        .customSelect(
          'SELECT recovery_saved FROM backup_configuration WHERE singleton=1',
        )
        .get();
    return rows.isNotEmpty && rows.single.read<int>('recovery_saved') == 1;
  }

  Future<String> readRecoveryKeyFrom(String path) async {
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file ||
          await File(path).length() > 256) {
        throw const StorageFailure('invalid_recovery_key');
      }
      final key = (await File(path).readAsString()).trim();
      _decodeKey(key);
      return key;
    } catch (_) {
      throw const StorageFailure('invalid_recovery_key');
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
      // Independent file I/O must succeed before export can be enabled.
      await _repository._db.transaction(() async {
        await _repository._db.customStatement(
          'UPDATE backup_configuration SET recovery_saved=1 WHERE singleton=1',
        );
        await _advanceOperationVersion();
      });
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
    final hex = _decodeKey(recoveryKey)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
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

  static void _requireCipher() {
    final probe = sqlite.sqlite3.openInMemory();
    try {
      final result = probe.select('PRAGMA cipher_version');
      if (result.isEmpty ||
          result.first.values.first is! String ||
          !(result.first.values.first as String).startsWith('4.')) {
        throw const StorageFailure('cipher_unavailable');
      }
    } finally {
      probe.close();
    }
  }

  static Future<Directory> _createStaging(String parent, String prefix) async {
    final directory = await Directory(parent).createTemp(prefix);
    // Inherited Windows ACLs do not satisfy the protected descriptor required
    // by the retained-original publisher. Protect before registration or bytes.
    return Platform.isWindows
        ? WindowsPrivateFiles.directory(directory)
        : directory;
  }

  Future<BackupContents> _snapshot() async {
    return _repository._db.transaction(() async {
      final document = await _rawSnapshotDocument();
      final retained = _retain(
        _validate(document),
        DateTime.parse(document['createdAt'] as String),
      );
      // Old libraries may predate admission reservations. Never publish an
      // archive that retention has expanded beyond its own row limits.
      if (!_backupRowsWithinLimits(retained._tables)) {
        throw const StorageFailure('backup_capacity_exceeded');
      }
      return retained;
    });
  }

  // Budget checks also run between ordered audit writes, where a newly saved
  // request/grant pair may not yet both exist. Count the exact portable shape
  // without requiring that intermediate state to be a restorable library.
  Future<Map<String, Object?>> _rawSnapshotDocument({
    bool reserveLifecycleOutcomes = false,
  }) async {
    _checkOpen();
    return _repository._db.transaction(() async {
      final tables = <String, List<Map<String, Object?>>>{};
      final now = _repository._clock().toUtc();
      final versions = await _repository._allAttachmentVersions();
      final deliveryRows = await _repository._db
          .customSelect('SELECT id FROM information_deliveries LIMIT 1')
          .get();
      final fileTemplates = _repository.templates.any(
        (t) => t.fields.any((f) => f.kind == FieldKind.file),
      );
      // Read templates in this transaction: a template may just have been saved
      // while its owner cache is deliberately still unpublished.
      final templates = await _repository._db
          .customSelect('SELECT fields_json FROM field_templates')
          .get();
      final v8 =
          versions.isNotEmpty ||
          fileTemplates ||
          templates.any(
            (r) => (jsonDecode(r.read<String>('fields_json')) as List).any(
              (f) => f['kind'] == 'file',
            ),
          );
      var formatVersion = deliveryRows.isNotEmpty
          ? 9
          : v8
          ? 8
          : 7;
      for (final table
          in (formatVersion == 9
                  ? _v9Columns
                  : v8
                  ? _v8Columns
                  : _allColumns)
              .entries) {
        final rows = await _repository._db
            .customSelect(
              'SELECT ${table.value.join(',')} FROM ${_physicalTables[table.key] ?? table.key} ORDER BY rowid',
            )
            .get();
        tables[table.key] = rows.map((row) => row.data).toList();
      }
      final directoryIds = tables['information_directories']!
          .map((r) => r['id'])
          .toSet();
      final tagIds = tables['information_tags']!.map((r) => r['id']).toSet();
      bool removedOrganization(Map<String, dynamic> item) =>
          (item['directoryId'] != null &&
              !directoryIds.contains(item['directoryId'])) ||
          (item['tagIds'] as List).any((id) => !tagIds.contains(id));
      final detachedHistory =
          tables['information_revisions']!.any(
            (r) => removedOrganization(
              jsonDecode(r['payload'] as String) as Map<String, dynamic>,
            ),
          ) ||
          tables['recycle_entries']!.any((r) {
            final entry =
                jsonDecode(r['payload'] as String) as Map<String, dynamic>;
            return entry['snapshot'] != null &&
                removedOrganization(entry['snapshot'] as Map<String, dynamic>);
          });
      final currentLayouts = await _repository._db
          .customSelect(
            'SELECT 1 FROM information_items WHERE layout_json IS NOT NULL LIMIT 1',
          )
          .get();
      final hasLayouts =
          currentLayouts.isNotEmpty ||
          tables['information_revisions']!.any(
            (r) => _backupJson(r)['layout'] != null,
          ) ||
          tables['recycle_entries']!.any(
            (r) => (_backupJson(r)['snapshot'] as Map?)?['layout'] != null,
          );
      // Pending requests are not portable history. Select the new label only
      // after archiving, but before metadata admission/validation or publication.
      _archiveCredentialRuntime(tables, now);
      if (await _repository._hasCredentialBatchTables()) {
        for (final table in [
          'credential_batches',
          'credential_batch_operations',
        ]) {
          tables[table] = [
            for (final row
                in await _repository._db
                    .customSelect(
                      'SELECT ${_v28Columns[table]!.join(',')} FROM $table ORDER BY rowid',
                    )
                    .get())
              row.data,
          ];
        }
        _archiveCredentialBatches(tables, now);
        tables['credential_program_operations'] =
            await _repository._hasCredentialProgramTable()
            ? [
                for (final row
                    in await _repository._db
                        .customSelect(
                          'SELECT execution_id,session_binding,operation_id,request_id,payload FROM credential_program_operations ORDER BY rowid',
                        )
                        .get())
                  row.data,
              ]
            : [];
        _archiveCredentialPrograms(tables);
      }
      final hasBatchHistory = tables['credential_batches']?.isNotEmpty ?? false;
      final hasSshHistory =
          tables['credential_batches']?.any(
            (row) =>
                _storedBatch(row).items.any((i) => i.destination.ssh != null),
          ) ??
          false;
      final hasNativeHistory =
          tables['credential_batches']?.any(
            (row) =>
                _storedBatch(row).items
                    .any((i) => i.destination.native != null),
          ) ??
          false;
      final hasProgramBatchHistory =
          tables['credential_batches']?.any(
            (row) => _storedBatch(row).programPlan != null,
          ) ??
          false;
      if (!hasBatchHistory) {
        tables.remove('credential_batches');
        tables.remove('credential_batch_operations');
      }
      if (!hasProgramBatchHistory && !hasNativeHistory && !hasSshHistory)
        tables.remove('credential_program_operations');
      final sessionSshGrants = tables['credential_use_requests']!.any(
        (row) =>
            CredentialUseRequest.fromJson(_backupJson(row))
                .credentialValidity ==
            CredentialUseValidity.session,
      );
      final portableFills = _hasPortableFocusedFill(
        tables['credential_use_requests']!.map(
          (row) => CredentialUseRequest.fromJson(_backupJson(row)),
        ),
      );
      if (portableFills && !await _repository._portableFocusedFillFormat()) {
        throw const StorageFailure('invalid_runtime_snapshot');
      }
      final hasGrantVersions = tables['grant_history']!.any(
        (r) => _backupJson(r).containsKey('itemVersions'),
      );
      final hasGrantSnapshots = tables['grant_history']!.any(
        (r) => _backupJson(r).containsKey('itemSnapshots'),
      );
      final credentialClassification = tables['managed_credentials']!.any(
        (r) =>
            _backupJson(r).containsKey('directoryId') ||
            _backupJson(r).containsKey('tagIds'),
      );
      final credentialTemplates = tables['managed_credentials']!.any(
        (r) => _backupJson(r).containsKey('template'),
      );
      final accountMetadata = tables['managed_credentials']!.any(
        (r) => (_backupJson(r)['account'] as String? ?? '').isNotEmpty,
      );
      final hasRevisionSnapshots =
          await _repository._hasRevisionSnapshots() &&
          (await _repository._db
                  .customSelect(
                    'SELECT 1 FROM information_revision_snapshots LIMIT 1',
                  )
                  .get())
              .isNotEmpty;
      final hasCredentialSnapshots =
          (await _repository._db
                  .customSelect(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name='credential_material_snapshots'",
                  )
                  .get())
              .isNotEmpty &&
          (await _repository._db
                  .customSelect(
                    'SELECT 1 FROM credential_material_snapshots LIMIT 1',
                  )
                  .get())
              .isNotEmpty;
      final longTermAttachments = versions.isNotEmpty;
      final fileBranches = versions.any(
        (v) => v.seriesId != v.reference.attachmentId,
      );
      final describedFileVersions = versions.any(
        (v) => v.label.isNotEmpty || v.sourceNote.isNotEmpty,
      );
      final templatePackages =
          (await _repository._db
                  .customSelect('SELECT id FROM template_packages LIMIT 1')
                  .get())
              .isNotEmpty;
      final directoryRecycle =
          (await _repository._db
                  .customSelect(
                    'SELECT id FROM library_recycle_batches LIMIT 1',
                  )
                  .get())
              .isNotEmpty;
      final orderedLibrary =
          (await _repository._db
                  .customSelect('SELECT id FROM library_order_state LIMIT 1')
                  .get())
              .isNotEmpty;
      final hasCredentialDeliveryExtensions = _repository.credentialUseRequests
          .any((r) => r.isReveal || r.isCommand && r.plan.isProgramReceiver);
      final extendedColumns =
          hasBatchHistory ||
          hasCredentialDeliveryExtensions ||
          hasCredentialSnapshots ||
          hasRevisionSnapshots ||
          hasGrantSnapshots ||
          fileBranches ||
          sessionSshGrants ||
          orderedLibrary ||
          directoryRecycle ||
          hasLayouts ||
          hasGrantVersions ||
          credentialClassification ||
          templatePackages ||
          credentialTemplates ||
          accountMetadata ||
          longTermAttachments;
      if (detachedHistory || portableFills || extendedColumns) {
        formatVersion = hasSshHistory
            ? 31
            : hasNativeHistory
            ? 30
            : hasProgramBatchHistory
            ? 29
            : hasBatchHistory
            ? 28
            : hasCredentialDeliveryExtensions
            ? 27
            : hasCredentialSnapshots
            ? 26
            : hasRevisionSnapshots
            ? 25
            : hasGrantSnapshots
            ? 24
            : fileBranches
            ? 23
            : sessionSshGrants
            ? 22
            : orderedLibrary
            ? 21
            : directoryRecycle
            ? 20
            : accountMetadata
            ? 19
            : describedFileVersions
            ? 18
            : longTermAttachments
            ? 17
            : credentialTemplates
            ? 16
            : templatePackages
            ? 15
            : credentialClassification
            ? 14
            : hasGrantVersions
            ? 13
            : hasLayouts
            ? 12
            : portableFills
            ? 11
            : 10;
        for (final table
            in (hasProgramBatchHistory || hasNativeHistory || hasSshHistory
                    ? _v29Columns
                    : hasBatchHistory
                    ? _v28Columns
                    : hasCredentialDeliveryExtensions || hasCredentialSnapshots
                    ? _v26Columns
                    : hasRevisionSnapshots
                    ? _v25Columns
                    : hasGrantSnapshots ||
                          fileBranches ||
                          sessionSshGrants ||
                          orderedLibrary
                    ? _v21Columns
                    : directoryRecycle
                    ? _v20Columns
                    : templatePackages ||
                          credentialTemplates ||
                          accountMetadata ||
                          longTermAttachments
                    ? _v15Columns
                    : extendedColumns
                    ? _v12Columns
                    : _v9Columns)
                .entries
                .where(
                  (e) =>
                      !tables.containsKey(e.key) ||
                      (extendedColumns && e.key == 'information_items'),
                )) {
          final rows = await _repository._db
              .customSelect(
                'SELECT ${table.value.join(',')} FROM ${_physicalTables[table.key] ?? table.key} ORDER BY rowid',
              )
              .get();
          tables[table.key] = rows.map((r) => r.data).toList();
        }
      }
      // Persist only archive facts. Never serialize private runtime DTOs into
      // a portable backup, even when an execution is currently active.
      if (reserveLifecycleOutcomes) _reserveRuntimeBackupOutcomes(tables);
      if (tables.containsKey('information_deliveries')) {
        tables['information_deliveries'] = [
          for (final row in tables['information_deliveries']!)
            {
              'id': row['id'],
              'payload': jsonEncode(
                _deliveryBudgetArchive(
                  InformationFileDelivery.fromPrivateJson(
                    decodeProtocolObject(row['payload'] as String),
                  ),
                  reserveLifecycleOutcomes,
                ),
              ),
            },
        ];
      }
      return {
        'format': _format,
        'version': formatVersion,
        'createdAt': reserveLifecycleOutcomes
            ? _metadataBudgetTimestamp
            : now.toIso8601String(),
        'tables': tables,
        if (formatVersion >= 8)
          'attachments': [
            for (final v in versions)
              {
                ...v.toPrivateJson(),
                if (reserveLifecycleOutcomes && v.available) ...{
                  'retiredAt': _metadataBudgetTimestamp,
                  'purgedAt': _metadataBudgetTimestamp,
                },
              },
          ],
      };
    });
  }

  /// Advisory preview only; restore rechecks every table inside its transaction.
  Future<bool> recipientEmpty() async {
    _checkOpen();
    final tables = await _repository._db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
        )
        .get();
    for (final table
        in tables
            .map((r) => r.read<String>('name'))
            .where(
              (name) => !{
                'settings',
                'backup_configuration',
                'library_format',
                'information_file_stages',
                'information_draft_commits',
                'information_record_operations',
                'information_classification_state',
                'information_classification_operations',
                'information_lifecycle_operations',
                'library_recycle_operations',
                'library_move_operations',
                'library_order_state',
                'information_approval_operations',
                'desktop_preference_operations',
                'owner_proposal_operations',
                'template_package_operations',
                'additional_approval_operations',
                'backup_operations',
                'backup_operation_state',
                'server_runtime_state',
                'library_replica_state',
                'library_replica_receipts',
                'library_sync_change_state',
                'library_sync_dirty',
                'library_sync_changes',
                'library_sync_projection',
                'library_sync_units',
                'library_sync_feed',
                'library_sync_progress',
                'library_sync_blobs',
                'library_sync_resolutions',
                'library_sync_parent_versions',
                'library_sync_resolution_commands',
                'library_file_branch_format',
              }.contains(name),
            )) {
      final quoted = table.replaceAll('"', '""');
      final count = await _repository._db
          .customSelect('SELECT count(*) AS n FROM "$quoted"')
          .getSingle();
      if (count.read<int>('n') != 0) return false;
    }
    return true;
  }

  /// An existing output is always refused, even when the file dialog confirmed
  /// overwrite. A failed/interrupted export leaves existing backups untouched.
  Future<BackupExportSummary> exportTo(
    String path, {
    String? stagingParent,
    Future<void> Function(String directory)? onStagingCreated,
  }) async {
    _checkOpen();
    sqlite.Database? db;
    Directory? staging;
    late BackupExportSummary summary;
    try {
      _requireCipher();
      final key = await recoveryKey();
      if (key == null) throw const StorageFailure('backup_not_enabled');
      if (!await recoveryKeySaved()) {
        throw const StorageFailure('recovery_key_not_saved');
      }
      // Registration must commit before the source snapshot transaction starts.
      // Registering from the attachment writer inside that transaction would
      // only create a savepoint and could leave crash-time files unregistered.
      if (onStagingCreated != null) {
        staging = await _createStaging(
          stagingParent ?? File(path).parent.path,
          '.agent-info-backup-',
        );
        await onStagingCreated(staging.path);
      }
      final snapshot = await _repository._db.transaction(() async {
        final snapshot = await _snapshot();
        summary = BackupExportSummary._(snapshot);
        if (snapshot.formatVersion < 8) return snapshot;
        // Metadata and every range of original bytes share one source snapshot.
        await AttachmentBackupContainer.write(
          path: path,
          recoveryKey: key,
          createdAt: snapshot.createdAt,
          tables: snapshot._tables,
          stagingParent: stagingParent,
          registeredStagingDirectory: staging?.path,
          formatVersion: snapshot.formatVersion,
          attachments: [
            for (final v in snapshot.attachments)
              AttachmentBackupSource(
                v,
                read: v.available
                    ? (offset, length) => _repository._readAttachmentChunk(
                        v.reference,
                        offset,
                        length,
                      )
                    : null,
              ),
          ],
        );
        return null;
      });
      if (snapshot == null) return summary;
      final payload = jsonEncode(_document(snapshot));
      if (utf8.encode(payload).length > maxPayloadBytes) {
        throw const StorageFailure('backup_too_large');
      }
      final output = File(path);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const StorageFailure('output_exists');
      }
      staging ??= await _createStaging(
        stagingParent ?? output.parent.path,
        '.agent-info-backup-',
      );
      final temporary = File('${staging.path}/backup.partial');
      if (Platform.isWindows) WindowsPrivateFiles.reserve(temporary);
      db = sqlite.sqlite3.open(temporary.path);
      _key(db, key);
      db.execute(
        'CREATE TABLE backup_snapshot(singleton INTEGER PRIMARY KEY CHECK(singleton=1),payload TEXT NOT NULL)',
      );
      db.execute('INSERT INTO backup_snapshot(singleton,payload) VALUES(1,?)', [
        payload,
      ]);
      db.close();
      db = null;
      await inspect(temporary.path, key);
      try {
        publishNewBackup(temporary.absolute.path, output.absolute.path);
      } catch (_) {
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const StorageFailure('output_exists');
        }
        throw const StorageFailure('backup_publish_failed');
      }
      return summary;
    } catch (error) {
      db?.close();
      if (error is StorageFailure) rethrow;
      throw const StorageFailure('backup_export_failed');
    } finally {
      if (staging != null) {
        // Remove only known generated files; never recursively delete an output
        // directory or follow an unrelated filesystem entry.
        for (final name in [
          'backup.partial',
          'backup.partial-journal',
          'backup.partial-wal',
          'backup.partial-shm',
        ]) {
          try {
            final file = File('${staging.path}/$name');
            if (await file.exists()) await file.delete();
          } catch (_) {
            /* Keep encrypted leftovers on cleanup failure. */
          }
        }
        try {
          await staging.delete();
        } catch (_) {
          /* No path or secret diagnostics. */
        }
      }
    }
  }

  Future<BackupContents> inspect(String path, String recoveryKey) async {
    _decodeKey(recoveryKey);
    sqlite.Database? db;
    try {
      _requireCipher();
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const StorageFailure('invalid_backup');
      }
      final length = await File(path).length();
      if (length < 4096 ||
          length > AttachmentBackupContainer.maxFileBytes ||
          length % 4096 != 0) {
        throw const StorageFailure('invalid_backup');
      }
      db = sqlite.sqlite3.open(path, mode: sqlite.OpenMode.readOnly);
      _key(db, recoveryKey);
      db.execute('BEGIN');
      // SQLCipher authenticates every page before any schema or payload parsing.
      if (db.select('PRAGMA cipher_integrity_check').isNotEmpty) {
        throw const StorageFailure('invalid_backup');
      }
      final objects = db.select(
        "SELECT type,name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
      );
      if (objects.length == 2 &&
          objects.every((r) => r['type'] == 'table') &&
          objects.map((r) => r['name']).toSet().containsAll({
            'backup_snapshot',
            'attachment_chunks',
          })) {
        db.close();
        db = null;
        return await _inspectAttachmentBackup(path, recoveryKey);
      }
      if (length > maxFileBytes) throw const StorageFailure('invalid_backup');
      if (objects.length != 1 ||
          objects.single['type'] != 'table' ||
          objects.single['name'] != 'backup_snapshot') {
        throw const StorageFailure('unsupported_backup');
      }
      final integrity = db.select('PRAGMA integrity_check');
      if (integrity.length != 1 || integrity.single.values.single != 'ok') {
        throw const StorageFailure('invalid_backup');
      }
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
      return _retain(
        _validate(jsonDecode(payload)),
        _repository._clock().toUtc(),
      );
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
    if (contents.formatVersion >= 8) return _restoreAttachmentBackup(contents);
    return _installBackup(contents);
  }

  Future<BackupContents> _installBackup(
    BackupContents contents, {
    AttachmentBackupReader? reader,
    _BackupRestoreIntent? intent,
    bool preserveHistory = false,
    bool preserveSettings = false,
    Future<void> Function()? commitReplication,
  }) async {
    _checkOpen();
    if (_repository.managedCredentials.isNotEmpty) {
      throw const StorageFailure('recipient_not_empty');
    }
    try {
      contents = _retain(
        contents,
        _repository._clock().toUtc(),
        restored: true,
        preserveHistory: preserveHistory,
      );
      if (preserveSettings) {
        final settings = await _repository._db
            .customSelect('SELECT name,value FROM settings')
            .get();
        contents = BackupContents._(
          {
            ...contents._tables,
            'settings': settings.map((r) => r.data).toList(),
          },
          contents.createdAt,
          contents.formatVersion,
          attachments: contents.attachments,
          origin: contents._origin,
        );
      }
      // Construct all models before committing; cache publication cannot fail
      // afterward due to a payload decode or a second database read.
      final install = _prepareInstall(contents);
      await _repository._db.transaction(() async {
        if (intent != null) await _checkRestoreIntent(intent, contents);
        final existingTables = await _repository._db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
            )
            .get();
        // Preserve every existing owner record, including modules newer than
        // this current-data format. Only preferences and local backup setup may
        // exist in a recipient. Table names are quoted, never executable input.
        for (final table
            in existingTables
                .map((r) => r.read<String>('name'))
                .where(
                  (name) => !{
                    'settings',
                    'backup_configuration',
                    'library_format',
                    'information_file_stages',
                    'information_draft_commits',
                    'information_record_operations',
                    'information_classification_state',
                    'information_classification_operations',
                    'information_lifecycle_operations',
                    'library_recycle_operations',
                    'library_move_operations',
                    'library_order_state',
                    'information_approval_operations',
                    'desktop_preference_operations',
                    'owner_proposal_operations',
                    'template_package_operations',
                    'additional_approval_operations',
                    'backup_operations',
                    'backup_operation_state',
                    'server_runtime_state',
                    'library_replica_state',
                    'library_replica_receipts',
                    'library_sync_change_state',
                    'library_sync_dirty',
                    'library_sync_changes',
                    'library_sync_projection',
                    'library_sync_units',
                    'library_sync_feed',
                    'library_sync_progress',
                    'library_sync_blobs',
                    'library_sync_resolutions',
                    'library_sync_parent_versions',
                    'library_sync_resolution_commands',
                    'library_file_branch_format',
                  }.contains(name),
                )) {
          final quoted = table.replaceAll('"', '""');
          final rows = await _repository._db
              .customSelect('SELECT count(*) AS n FROM "$quoted"')
              .getSingle();
          if (rows.read<int>('n') != 0) {
            throw const StorageFailure('recipient_not_empty');
          }
        }
        // Uncommitted owner forms are ephemeral, excluded from backup and
        // invalidated by a successful restore. A failed restore keeps them.
        // Ordering alone is not recipient content. Replace it even when an
        // older archive has no ordering table; never retain the previous IDs.
        // An initial copy or restored library starts a new common base. Remove
        // the capture scope first so imported rows do not become local edits.
        final names = existingTables.map((r) => r.read<String>('name')).toSet();
        for (final name in [
          'library_sync_projection',
          'library_sync_units',
          'library_sync_feed',
          'library_sync_progress',
          'library_sync_blobs',
          'library_sync_resolutions',
          'library_sync_parent_versions',
          'library_sync_resolution_commands',
          'library_sync_change_state',
          'library_sync_dirty',
          'library_sync_changes',
        ]) {
          if (names.contains(name)) {
            await _repository._db.customStatement('DELETE FROM $name');
          }
        }
        await _repository._invalidateServerState();
        await _repository._db.customStatement(
          'DELETE FROM library_order_state',
        );
        await _repository._db.customStatement(
          'DELETE FROM information_file_stages',
        );
        await _repository._db.customStatement(
          'DELETE FROM information_draft_commits',
        );
        // A restored library must not acknowledge or replay an old UI intent.
        // Keep content-free tombstones so lookup cannot mistake it for untried.
        await _repository._db.customStatement(
          'UPDATE information_record_operations SET invalidated=1',
        );
        await _repository._db.customStatement(
          'UPDATE information_classification_operations SET invalidated=1',
        );
        await _repository._db.customStatement(
          'UPDATE information_lifecycle_operations SET invalidated=1',
        );
        await _repository._db.customStatement(
          'UPDATE library_recycle_operations SET invalidated=1',
        );
        await _repository._db.customStatement(
          'UPDATE library_move_operations SET invalidated=1',
        );
        await _repository._db.customStatement(
          'UPDATE information_approval_operations SET invalidated=1',
        );
        await _repository._db.customStatement(
          'UPDATE backup_operations SET invalidated=1',
        );
        await _advanceOperationVersion();
        // Keep local versions monotonic even when restoring an empty catalog.
        await _repository._db.customStatement(
          'UPDATE information_classification_state SET version=version+1 WHERE singleton=1',
        );
        await _repository._db.customStatement('DELETE FROM settings');
        await _repository._db.customStatement(
          'UPDATE desktop_preference_operations SET invalidated=1',
        );
        await _repository._db.customStatement(
          'UPDATE owner_proposal_operations SET invalidated=1',
        );
        await _repository._db.customStatement(
          'UPDATE template_package_operations SET invalidated=1',
        );
        await _repository._db.customStatement(
          'UPDATE additional_approval_operations SET invalidated=1',
        );
        await _repository._db.customStatement('DELETE FROM organization_tasks');
        if (_hasPortableFocusedFill(
          contents._tables['credential_use_requests']!.map(
            (r) => CredentialUseRequest.fromJson(_backupJson(r)),
          ),
        )) {
          await _repository._requirePortableFocusedFillFormat();
        }
        if (contents.formatVersion >= 14) {
          await _repository._requireCredentialClassificationFormat();
        }
        if (contents.formatVersion >= 15) {
          await _repository._requireTemplatePackageFormat();
        }
        if (contents.formatVersion >= 16) {
          await _repository._requireAdmissionFormat(
            _credentialImportLibraryFormat,
          );
        }
        if (contents.formatVersion >= 17) {
          await _repository._requireAdmissionFormat(
            _longTermAttachmentLibraryFormat,
          );
        }
        if (contents.formatVersion >= 18) {
          await _repository._requireAdmissionFormat(
            _informationImportFileLibraryFormat,
          );
        }
        if (contents.formatVersion >= 19) {
          await _repository._requireAdmissionFormat(
            _credentialProposalPreviewLibraryFormat,
          );
        }
        if (contents.formatVersion >= 20) {
          await _repository._requireAdmissionFormat(
            _libraryRecycleLibraryFormat,
          );
        }
        if (contents.formatVersion >= 21) {
          await _repository._requireAdmissionFormat(_libraryOrderLibraryFormat);
        }
        if (contents.formatVersion >= 22) {
          await _repository._requireAdmissionFormat(
            _sshSessionUseLibraryFormat,
          );
        }
        if (contents.formatVersion >= 23) {
          await _repository._requireAdmissionFormat(_libraryFileBranchFormat);
        }
        if (contents.formatVersion >= 24) {
          await _repository._requireAdmissionFormat(
            _libraryGrantSnapshotFormat,
          );
        }
        // Directory parents may appear after a moved child in source row order.
        await _repository._db.customStatement('PRAGMA defer_foreign_keys = ON');
        if (contents.formatVersion >= 8) {
          if (reader == null) throw const StorageFailure('invalid_backup');
          await _installAttachmentBodies(contents, reader);
        }
        if (contents.formatVersion >= 28) {
          await _repository._createCredentialBatchTables();
        }
        if (contents.formatVersion >= 31) {
          await _repository._requireAdmissionFormat(
            _sshInteractiveLibraryFormat,
          );
        }
        if (contents.formatVersion >= 30) {
          await _repository._requireAdmissionFormat(_nativeFillLibraryFormat);
        }
        if (contents.formatVersion >= 29) {
          await _repository._createCredentialProgramTable();
        }
        if (contents.formatVersion >= 27) {
          await _repository._requireAdmissionFormat(
            _credentialDeliveryLibraryFormat,
          );
        }
        if (contents.formatVersion >= 26) {
          await _repository._requireAdmissionFormat(
            _libraryCredentialArchiveFormat,
          );
        }
        if (contents.formatVersion >= 25) {
          await _repository._requireAdmissionFormat(
            _libraryRevisionSnapshotFormat,
          );
        }
        for (final table
            in (contents.formatVersion >= 29
                    ? _v29Columns
                    : contents.formatVersion >= 28
                    ? _v28Columns
                    : contents.formatVersion >= 26
                    ? _v26Columns
                    : contents.formatVersion >= 25
                    ? _v25Columns
                    : contents.formatVersion >= 21
                    ? _v21Columns
                    : contents.formatVersion >= 20
                    ? _v20Columns
                    : contents.formatVersion >= 15
                    ? _v15Columns
                    : contents.formatVersion >= 12
                    ? _v12Columns
                    : contents.formatVersion >= 9
                    ? _v9Columns
                    : contents.formatVersion == 8
                    ? _v8Columns
                    : _allColumns)
                .entries) {
          final placeholders = List.filled(table.value.length, '?').join(',');
          for (final row in contents._tables[table.key]!) {
            if (table.key == 'information_deliveries') {
              final record = InformationFileDelivery.fromArchiveJson(
                decodeProtocolObject(row['payload'] as String),
              );
              await _repository._db.customStatement(
                'INSERT INTO information_deliveries(id,session_binding,operation_id,payload) VALUES(?,NULL,?,?)',
                [
                  record.id,
                  record.operationId,
                  jsonEncode(record.toPrivateJson()),
                ],
              );
              continue;
            }
            await _repository._db.customStatement(
              'INSERT INTO ${_physicalTables[table.key] ?? table.key}(${table.value.join(',')}) VALUES($placeholders)',
              table.value.map((column) => row[column]).toList(),
            );
          }
        }
        await _repository._checkAttachmentBackupBudget();
        if (intent != null) await _commitRestoreReceipt(intent, contents);
        if (commitReplication != null) await commitReplication();
      });
      install();
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
        ![
          1,
          2,
          3,
          4,
          5,
          6,
          7,
          8,
          9,
          10,
          11,
          12,
          13,
          14,
          15,
          16,
          17,
          18,
          19,
          20,
          21,
          22,
          23,
          24,
          25,
          26,
          27,
          28,
          29,
          30,
          31,
        ].contains(decoded['version'])) {
      throw const StorageFailure('unsupported_backup');
    }
    final v8 = (decoded['version'] as int) >= 8;
    if (decoded.length != (v8 ? 5 : 4) ||
        decoded['tables'] is! Map<String, dynamic> ||
        decoded['createdAt'] is! String ||
        (decoded['createdAt'] as String).length > 64) {
      invalid();
    }
    final createdAt = _backupDate(decoded['createdAt']);
    final columns = switch (decoded['version']) {
      1 => _columns,
      2 => _v2Columns,
      3 => _v3Columns,
      4 => _v4Columns,
      5 || 6 => _v6Columns,
      8 => _v8Columns,
      9 || 10 || 11 => _v9Columns,
      12 || 13 || 14 => _v12Columns,
      15 || 16 || 17 || 18 || 19 => _v15Columns,
      20 => _v20Columns,
      21 || 22 || 23 || 24 => _v21Columns,
      25 => _v25Columns,
      26 || 27 => _v26Columns,
      28 => _v28Columns,
      29 || 30 || 31 => _v29Columns,
      _ => _allColumns,
    };
    final data = decoded['tables'] as Map<String, dynamic>;
    if (data.length != columns.length ||
        data.keys.any((key) => !columns.containsKey(key))) {
      invalid();
    }
    final tables = <String, List<Map<String, Object?>>>{};
    var totalRows = 0;
    for (final table in columns.entries) {
      final rows = data[table.key];
      final maximum = _maximumBackupRows(table.key);
      if (rows is! List || rows.length > maximum) invalid();
      totalRows += rows.length;
      if (totalRows > _backupRowCeiling) invalid();
      tables[table.key] = rows
          .map((value) {
            if (value is! Map<String, dynamic> ||
                value.length != table.value.length ||
                value.keys.any((key) => !table.value.contains(key))) {
              invalid();
            }
            return Map<String, Object?>.unmodifiable(value);
          })
          .toList(growable: false);
    }
    for (final table in _historyColumns.keys) {
      tables.putIfAbsent(table, () => const []);
    }
    tables.putIfAbsent('request_history', () => const []);
    for (final table in _credentialColumns.keys) {
      tables.putIfAbsent(table, () => const []);
    }
    tables.putIfAbsent('credential_focused_fills', () => const []);
    final attachments = v8
        ? _AttachmentBackupManifest.parse(jsonEncode(decoded)).versions
        : <InformationAttachmentVersion>[];
    if ((decoded['version'] as int) < 23 &&
        attachments.any((v) => v.seriesId != v.reference.attachmentId))
      invalid();
    final available = attachments
        .where((v) => v.available)
        .map((v) => v.reference)
        .toSet();
    final fileFields = <String>{};
    if (v8) {
      final fields = {
        for (final f in tables['information_fields']!) f['id']: f,
      };
      for (final row in tables['information_file_fields']!) {
        final fieldId = row['field_id'];
        if (fieldId is! String ||
            !fileFields.add(fieldId) ||
            fields[fieldId]?['kind'] != 'file') {
          invalid();
        }
        final ref = InformationAttachmentRef.fromJson({
          'attachmentId': row['attachment_id'],
          'attachmentVersion': row['attachment_version'],
        });
        if (!available.contains(ref)) invalid();
      }
    }
    if ((decoded['version'] as int) < 3) {
      tables['information_items'] = [
        for (final row in tables['information_items']!)
          Map<String, Object?>.unmodifiable({
            ...row,
            'created_at': null,
            'modified_at': null,
          }),
      ];
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
          (required && value.trim().isEmpty)) {
        invalid();
      }
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
          (parent is! String || !directories.contains(parent))) {
        invalid();
      }
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
      if (row['layout_json'] != null) {
        InformationLayout.fromJson(
          decodeProtocolObject(
            text(row, 'layout_json', InformationLayout.maxBytes),
            maxBytes: InformationLayout.maxBytes,
          ),
        );
      }
      if (row['created_at'] != null) _backupDate(row['created_at']);
      if (row['modified_at'] != null) _backupDate(row['modified_at']);
      final directory = row['directory_id'];
      if (directory != null &&
          (directory is! String || !directories.contains(directory))) {
        invalid();
      }
      final count = fieldCounts[row['id']] ?? 0;
      // Explicit field deletion can leave an information item's public metadata
      // with zero fields. Only whole-item deletion removes that identity.
      if (count > 200) invalid();
    }
    for (final row in tables['information_fields']!) {
      if (!items.contains(id(row, 'item_id'))) invalid();
      text(row, 'description', 2000);
      text(row, 'value', 1000000);
      if (row['kind'] == 'file' && v8) {
        if (row['value'] != '' || !fileFields.contains(row['id'])) invalid();
      } else if (!{'structured', 'textNote'}.contains(row['kind']))
        invalid();
    }
    final associations = <String>{};
    final tagCounts = <String, int>{};
    for (final row in tables['information_item_tags']!) {
      if (!items.contains(id(row, 'item_id')) ||
          !tags.contains(id(row, 'tag_id')) ||
          !associations.add(jsonEncode([row['item_id'], row['tag_id']]))) {
        invalid();
      }
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
            !seen.add(id(field))) {
          invalid();
        }
        text(field, 'name', 200, required: true);
        text(field, 'description', 2000);
        if (!(v8
                ? {'structured', 'textNote', 'file'}
                : {'structured', 'textNote'})
            .contains(field['kind'])) {
          invalid();
        }
      }
    }
    final settings = <String>{};
    for (final row in tables['settings']!) {
      final name = text(row, 'name', 200, required: true);
      if (!settings.add(name) || row['value'] is! int) invalid();
      final value = row['value'] as int;
      if (value < 0 || value > 9007199254740991) invalid();
      if (name == 'requestLifetimeMs' && (value < 60000 || value > 604800000)) {
        invalid();
      }
      if (name == 'auditRetentionDays' && ![30, 90, 180, 365].contains(value)) {
        invalid();
      }
    }
    final deliveries = _validateBackupFileDeliveries(tables, attachments);
    _validateBackupHistory(
      tables,
      availableAttachments: v8 ? available : null,
      deliveries: deliveries,
      allowRemovedOrganization: (decoded['version'] as int) >= 10,
      allowLayouts: (decoded['version'] as int) >= 12,
      allowGrantVersions: (decoded['version'] as int) >= 13,
      allowGrantSnapshots: (decoded['version'] as int) >= 24,
    );
    _validateBackupCredentials(
      tables,
      formatVersion: decoded['version'] as int,
    );
    _validateBackupLibraryRecycle(tables);
    _validateBackupLibraryOrder(tables);
    _validateBackupCredentialBatches(
      tables,
      formatVersion: decoded['version'] as int,
    );
    _validateBackupCredentialPrograms(
      tables,
      formatVersion: decoded['version'] as int,
    );
    final packageIds = <String>{};
    final packages =
        tables['template_packages'] ?? const <Map<String, Object?>>[];
    if (packages.length > 100) invalid();
    for (final row in packages) {
      try {
        final p = _templatePackageFromRow(row);
        if (!packageIds.add(p.id)) invalid();
      } on Object {
        invalid();
      }
    }
    return BackupContents._(
      Map.unmodifiable(tables),
      createdAt,
      decoded['version'] as int,
      attachments: List.unmodifiable(attachments),
    );
  }
}
