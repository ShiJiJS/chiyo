import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:info_core/info_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:crypto/crypto.dart' as crypto;
import 'package:info_core/protocol_json.dart';
import 'package:info_core/server_state.dart';
import 'package:info_core/library_replication.dart';
import 'package:info_core/library_sync_changes.dart';
import 'backup_publish.dart';
import 'macos_backup_publication.dart';
import 'platform_keys.dart';
export 'platform_keys.dart';
part 'backups.dart';
part 'backup_history.dart';
part 'backup_credentials.dart';
part 'backup_metadata_budget.dart';
part 'credentials_storage.dart';
part 'credential_record_storage.dart';
part 'credential_runtime_storage.dart';
part 'credential_batches_storage.dart';
part 'credential_program_storage.dart';
part 'focused_fill_storage.dart';
part 'information_files_storage.dart';
part 'information_import_files_storage.dart';
part 'attachment_backup.dart';
part 'information_attachments_storage.dart';
part 'attachment_backup_integration.dart';
part 'information_delivery_storage.dart';
part 'classification_storage.dart';
part 'library_recycle_storage.dart';
part 'library_move_storage.dart';
part 'library_order_storage.dart';
part 'backup_library_recycle.dart';
part 'lifecycle_storage.dart';
part 'approval_operations_storage.dart';
part 'backup_operations.dart';
part 'backup_output_operations.dart';
part 'backup_remote_outputs.dart';
part 'backup_restore_operations.dart';
part 'backup_staging_operations.dart';
part 'backup_owner_operations.dart';
part 'information_purge_storage.dart';
part 'information_file_outputs.dart';
part 'device_file_operations.dart';
part 'device_backup_operations.dart';
part 'information_file_opens.dart';
part 'desktop_preferences_storage.dart';
part 'proposal_operations_storage.dart';
part 'additional_approval_storage.dart';
part 'template_packages_storage.dart';
part 'server_state_storage.dart';
part 'library_replication_storage.dart';
part 'library_change_journal.dart';
part 'library_sync_contents.dart';
part 'library_incremental_storage.dart';
part 'library_incremental_receive.dart';
part 'library_sync_conflicts.dart';
part 'library_delta_archive.dart';

const _libraryFormat = 38;
// A content-triggered extension, not the default format of ordinary libraries.
// Older readers reject this independent marker before loading portable fills.
const _portableFocusedFillLibraryFormat = 39;
// Only libraries that actually retain credential classification require this
// reader. Older binaries must reject instead of silently discarding metadata.
const _credentialClassificationLibraryFormat = 40;
const _templatePackageLibraryFormat = 41;
// Typed pending proposals must never be flattened by an older reader.
const _templateImportLibraryFormat = 42;
const _importAdmissionLibraryFormat = 43;
const _updateAdmissionLibraryFormat = 44;
const _credentialImportLibraryFormat = 45;
const _longTermAttachmentLibraryFormat = 46;
const _informationImportFileLibraryFormat = 47;
const _informationFileUpdateLibraryFormat = 48;
const _credentialProposalPreviewLibraryFormat = 49;
const _libraryRecycleLibraryFormat = 50;
const _libraryOrderLibraryFormat = 51;
const _sshSessionUseLibraryFormat = 52;
const _serverRuntimeLibraryFormat = 53;
// Server deliveries have device-side copies instead of a host-native lease.
const _deviceDeliveryLibraryFormat = 54;
const _copyCleanupLibraryFormat = 55;
const _libraryReplicationFormat = 56;
const _libraryChangeJournalFormat = 57;
const _libraryIncrementalFormat = 58;
const _libraryDirectionalSyncFormat = 59;
const _libraryFileBranchFormat = 60;
const _libraryGrantSnapshotFormat = 61;
const _libraryRevisionSnapshotFormat = 62;
const _libraryCredentialArchiveFormat = 63;
const _credentialDeliveryLibraryFormat = 64;
const _credentialBatchLibraryFormat = 65;
const _agentSubmissionLibraryFormat = 66;
const _credentialProgramBatchLibraryFormat = 67;

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
  Iterable<Map<String, Object?>> links, [
  Iterable<Map<String, Object?>> fileFields = const [],
]) => InformationItem(
  row['id'] as String,
  row['name'] as String,
  row['description'] as String,
  row['version'] as int,
  [
    for (final field in fields.where((f) => f['item_id'] == row['id']))
      if (field['kind'] == 'file')
        InformationField.file(
          field['id'] as String,
          field['name'] as String,
          field['description'] as String,
          InformationAttachmentRef(
            fileFields.singleWhere(
                  (r) => r['field_id'] == field['id'],
                )['attachment_id']
                as String,
            fileFields.singleWhere(
                  (r) => r['field_id'] == field['id'],
                )['attachment_version']
                as int,
          ),
          field['version'] as int,
        )
      else
        InformationField(
          field['id'] as String,
          field['name'] as String,
          field['description'] as String,
          field['value'] as String,
          field['version'] as int,
          kind: FieldKind.values.byName(field['kind'] as String),
        ),
  ],
  layout: row['layout_json'] == null
      ? null
      : InformationLayout.fromJson(
          decodeProtocolObject(
            row['layout_json'] as String,
            maxBytes: InformationLayout.maxBytes,
          ),
        ),
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

/// A trusted owner/server capability. The Agent CLI never opens this store.
class EncryptedInformationRepository
    implements
        InformationRepository,
        LibraryRecycleRepository,
        LibraryMoveRepository,
        LibraryOrderRepository,
        CredentialRepository,
        CredentialRecordRepository,
        CredentialFieldMigrationRepository,
        FocusedFillRuntimeRepository,
        CredentialBatchRepository,
        CredentialProgramRepository,
        InformationAttachmentRepository,
        InformationImportFileRepository,
        InformationFileDeliveryRepository,
        InformationRecordOperationRepository,
        InformationAttachmentSeparationRepository,
        InformationLifecycleRepository,
        InformationApprovalRepository,
        InformationPurgeRepository,
        InformationClassificationRepository,
        DesktopPreferencesRepository,
        OwnerProposalOperationRepository,
        AdditionalApprovalRepository,
        TemplatePackageRepository,
        SshHostTrustRepository,
        ServerProposalPasswordRepository {
  final _credentialBatches = <String, CredentialUseBatch>{};
  final _credentialBatchOperations = <String, CredentialBatchOperation>{};
  final _credentialProgramOperations = <String, CredentialProgramOperation>{};
  @override
  List<CredentialProgramOperation> get credentialProgramOperations =>
      List.unmodifiable(_credentialProgramOperations.values);
  @override
  Future<void> commitCredentialProgramOperation(
    CredentialProgramOperation operation, {
    required int expectedRevision,
    required int requestRevision,
    required void Function() validate,
  }) => _commitCredentialProgramOperation(
    operation,
    expectedRevision: expectedRevision,
    requestRevision: requestRevision,
    validate: validate,
  );
  @override
  List<CredentialUseBatch> get credentialBatches =>
      List.unmodifiable(_credentialBatches.values);
  @override
  List<CredentialBatchOperation> get credentialBatchOperations =>
      List.unmodifiable(_credentialBatchOperations.values);
  @override
  Future<void> commitCredentialBatch(
    CredentialUseBatch request, {
    required int expectedRevision,
    required void Function() validate,
    CredentialBatchOperation? operation,
    int? expectedOperationRevision,
  }) => _commitCredentialBatch(
    request,
    expectedRevision: expectedRevision,
    validate: validate,
    operation: operation,
    expectedOperationRevision: expectedOperationRevision,
  );
  @override
  Future<ServerStateSnapshot> openServerState() => _openServerState();
  @override
  Future<ServerStateSnapshot> commitServerState(
    ServerStateSnapshot expected,
    Map<String, Object?> payload,
  ) => _commitServerState(expected, payload);
  @override
  Future<void> commitServerProposalPasswords(
    ServerStateSnapshot expected,
    Map<String, Object?> payload,
    ImportProposal revised,
    int expectedProposalVersion,
  ) => _commitProposalPasswords(
    expected,
    payload,
    revised,
    expectedProposalVersion,
  );
  final _templatePackages = <String, InstalledTemplatePackage>{};
  @override
  List<InstalledTemplatePackage> get installedTemplatePackages {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_templatePackages.values);
  }

  @override
  Future<TemplatePackageReceipt?> templatePackageReceipt(String id) =>
      _templateReceipt(id);
  @override
  Future<void> commitTemplatePackage(
    TemplatePackageReceipt receipt,
    InstalledTemplatePackage? package, {
    required void Function() validate,
  }) => _commitTemplatePackage(receipt, package, validate);
  @override
  Future<OwnerProposalReceipt?> ownerProposalReceipt(String id) =>
      _proposalReceipt(id);
  @override
  Future<DesktopPreferencesReceipt?> desktopPreferencesReceipt(String id) =>
      _desktopReceipt(id);
  @override
  Future<void> commitDesktopPreferences(
    DesktopPreferencesReceipt receipt,
    DesktopHistoryCleanup cleanup, {
    required void Function() validate,
  }) => _commitDesktop(receipt, cleanup, validate);
  @override
  Future<InformationApprovalReceipt?> informationApprovalReceipt(String id) =>
      _approvalReceipt(id);
  @override
  Future<int> informationApprovalRevision(String id) => _approvalRevision(id);
  @override
  Future<void> commitInformationApproval(
    InformationApprovalCommit change, {
    void Function()? validate,
  }) => _commitApproval(change, validate: validate);
  @override
  Future<void> commitInformationPurge(InformationPurgeChange change) =>
      _commitInformationPurge(change);
  @override
  Future<InformationLifecycleReceipt?> informationLifecycleReceipt(String id) =>
      _lifecycleReceipt(id);
  @override
  Future<int> informationClassificationVersion() => _classificationVersion();
  @override
  Future<InformationClassificationReceipt?> informationClassificationReceipt(
    String operationId,
  ) => _classificationReceipt(operationId);
  @override
  Future<InformationClassificationReceipt> commitInformationClassification(
    InformationClassificationChange change,
  ) => _commitClassification(change);
  @override
  Future<InformationRecordReceipt?> informationRecordReceipt(
    String operationId,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT payload,invalidated FROM information_record_operations WHERE operation_id=?',
          variables: [Variable(operationId)],
        )
        .get();
    if (rows.isEmpty) return null;
    if (rows.single.read<int>('invalidated') != 0) {
      throw const AccessFailure('library_changed');
    }
    final receipt = InformationRecordReceipt.fromJson(
      jsonDecode(rows.single.read<String>('payload')) as Map<String, dynamic>,
    );
    if (receipt.operationId != operationId) {
      throw const StorageFailure('invalid_operation_receipt');
    }
    return receipt;
  }

  @override
  Future<void> commitAttachmentSeparation({
    required InformationItem source,
    required InformationRevision previous,
    required InformationItem file,
    required InformationRecordReceipt receipt,
    required void Function() validate,
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    await _db.transaction(() async {
      validate();
      final rows = await _db
          .customSelect(
            'SELECT version FROM information_items WHERE id=?',
            variables: [Variable(source.id)],
          )
          .get();
      if (rows.length != 1 ||
          rows.single.read<int>('version') != previous.item.version) {
        throw const AccessFailure('version_conflict');
      }
      if (await informationRecordReceipt(receipt.operationId) != null ||
          _items.containsKey(file.id)) {
        throw const AccessFailure('operation_conflict');
      }
      await _writeItem(source);
      await _writeItem(file);
      await _writeRevision(previous);
      await _db.customStatement(
        'INSERT INTO information_record_operations(operation_id,payload) VALUES(?,?)',
        [receipt.operationId, jsonEncode(receipt.toJson())],
      );
      await _checkAttachmentBackupBudget();
      validate();
    });
    _items[source.id] = source;
    _items[file.id] = file;
    _revisions.add(previous);
  }

  @override
  List<InformationFileDelivery> get informationFileDeliveries {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_fileDeliveries.values);
  }

  @override
  Future<void> saveInformationFileDelivery(InformationFileDelivery record) =>
      _saveFileDelivery(record);
  @override
  Future<void> pruneInformationFileDeliveryHistory(Set<String> ids) =>
      _pruneFileDeliveries(ids);
  final _fileDeliveries = <String, InformationFileDelivery>{};
  @override
  Future<InformationAttachmentUsage> informationAttachmentUsage() async {
    if (_closed) throw const StorageFailure('library_closed');
    return _db.transaction(() async {
      final versions = await _allAttachmentVersions();
      final stages = await _fileStagingUsage();
      final available = versions.where((v) => v.available).toList();
      return InformationAttachmentUsage(
        versionRecords: versions.length,
        availableVersions: available.length,
        storedBytes: available.fold(0, (sum, v) => sum + v.byteLength),
        stagedFiles: stages.files,
        stagedBytes: stages.bytes,
      );
    });
  }

  @override
  Future<InformationFileStage> informationStage(
    String draftId,
    String stageId,
  ) => _informationStage(draftId, stageId);
  @override
  Future<List<InformationAttachmentVersion>> informationAttachmentVersions(
    String id,
  ) => _attachmentVersions(id);
  @override
  Future<Uint8List> readInformationAttachmentChunk(
    InformationAttachmentRef ref,
    int offset,
    int length,
  ) => _readAttachmentChunk(ref, offset, length);
  @override
  Future<T> withInformationAttachment<T>(
    InformationAttachmentRef ref,
    Future<T> Function(InformationAttachmentVersion, Stream<Uint8List>) action,
  ) => _withAttachment(ref, action);
  @override
  Future<void> reconcileInformationAttachments(DateTime now) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() => _reconcileAttachmentRetention(now.toUtc()));
    } on AccessFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('attachment_cleanup_failed');
    }
  }

  @override
  Future<InformationDraftReceipt?> informationDraftReceipt(
    String draftId,
    String operationId,
  ) => _draftReceipt(draftId, operationId);
  @override
  Future<InformationDraftReceipt> commitInformationDraft(
    InformationDraftChange change,
  ) => _commitAttachmentDraft(change);
  @override
  Future<InformationFileStage> stageInformationBytes({
    required String draftId,
    required String stageId,
    required String originalName,
    required String mediaType,
    required Uint8List bytes,
  }) => _stageInformationFileBytes(
    draftId: draftId,
    stageId: stageId,
    originalName: originalName,
    mediaType: mediaType,
    bytes: bytes,
  );
  @override
  Future<InformationFileStagingUsage> informationFileStagingUsage() =>
      _fileStagingUsage();
  @override
  Future<InformationImportUpload?> importFileUpload(String id) =>
      _importFileUpload(id);
  @override
  Future<InformationImportUpload?> importFileOperation(
    String binding,
    String operationId,
  ) => _importFileOperation(binding, operationId);
  @override
  Future<void> stageImportFile(
    InformationImportUpload upload,
    Uint8List bytes,
  ) => _stageImportFile(upload, bytes);
  @override
  Future<T> withImportFile<T>(
    String id,
    Future<T> Function(InformationImportUpload, Stream<Uint8List>) action,
  ) => _withImportFile(id, action);
  @override
  Future<void> pruneImportFiles(DateTime cutoff, Set<String> retained) =>
      _pruneImportFiles(cutoff, retained);
  @override
  Future<void> releaseInformationStage(String draftId, String stageId) =>
      _releaseInformationFileStage(draftId, stageId);
  @override
  Future<void> releaseInformationDraft(String draftId) =>
      _releaseInformationFileStage(draftId, null);
  SshHostTrustSnapshot? _sshHostTrust;
  @override
  SshHostTrustSnapshot? get sshHostTrust => _sshHostTrust;
  @override
  Future<void> saveSshHostTrust(SshHostTrustSnapshot? snapshot) =>
      _saveSshTrust(snapshot);
  EncryptedInformationRepository._(
    this._db,
    this._lock,
    this.cipherVersion,
    this._clock,
    this._preserveOnlineCredentialFacts,
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
  final _libraryRecycleBatches = <String, LibraryRecycleBatch>{};
  LibraryOrderSnapshot? _libraryOrder;
  @override
  LibraryOrderSnapshot? get libraryOrder => _libraryOrder;
  @override
  Future<LibraryMoveReceipt?> libraryMoveReceipt(String id) =>
      _libraryMoveReceipt(id);
  @override
  Future<LibraryMoveReceipt> commitLibraryMove(LibraryMoveChange change) =>
      _commitLibraryMove(change);
  @override
  List<LibraryRecycleBatch> get libraryRecycleBatches =>
      List.unmodifiable(_libraryRecycleBatches.values);
  @override
  Future<LibraryRecycleReceipt?> libraryRecycleReceipt(String id) =>
      _libraryRecycleReceipt(id);
  @override
  Future<LibraryRecycleReceipt> commitLibraryRecycle(
    LibraryRecycleChange change,
  ) => _commitLibraryRecycle(change);
  final _recycleFacts = <RecycleFact>[];
  final _deletes = <String, DeleteProposal>{};
  final _credentials = <ManagedCredential>[];
  final _credentialMaterials = <CredentialMaterial>[];
  @override
  Future<void> commitCredentialFieldMigration(
    CredentialFieldMigration change,
  ) => _migrateCredentialField(change);
  final _credentialUseRequests = <CredentialUseRequest>[];
  final _credentialExecutions = <CredentialExecution>[];
  final _focusedFillOperations = <FocusedFillOperation>[];
  @override
  List<FocusedFillOperation> get focusedFillOperations =>
      List.unmodifiable(_focusedFillOperations);
  @override
  Future<void> commitFocusedFillRuntime(
    List<CredentialUseRequest> requests,
    List<FocusedFillOperation> operations, {
    void Function()? validate,
    List<CredentialExecution>? executions,
  }) => _commitRuntime(
    requests,
    executions ?? List.of(_credentialExecutions),
    fills: operations,
    validate: validate,
  );
  @override
  List<CredentialUseRequest> get credentialUseRequests =>
      List.unmodifiable(_credentialUseRequests);
  @override
  List<CredentialExecution> get credentialExecutions =>
      List.unmodifiable(_credentialExecutions);
  @override
  Future<void> commitCredentialRuntime(
    List<CredentialUseRequest> requests,
    List<CredentialExecution> executions, {
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    void Function()? validate,
  }) => _commitRuntime(
    requests,
    executions,
    fieldGrant: fieldGrant,
    fieldRequest: fieldRequest,
    validate: validate,
  );
  @override
  List<ManagedCredential> get managedCredentials =>
      List.unmodifiable(_credentials);
  @override
  List<CredentialMaterial> get credentialMaterials =>
      List.unmodifiable(_credentialMaterials);
  @override
  Future<CredentialRecordReceipt?> credentialRecordReceipt(String id) =>
      _credentialRecordReceipt(id);
  @override
  Future<void> commitCredentialRecord(CredentialRecordChange change) =>
      _commitCredentialRecord(change);

  @override
  Future<void> commitCredentials(
    List<ManagedCredential> credentials,
    List<CredentialMaterial> materials,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    _validateVault(credentials, materials);
    try {
      await _writeMetadata(() async {
        await _writeCredentialSnapshot(credentials, materials);
      });
      _publishCredentialSnapshot(credentials, materials);
    } catch (_) {
      throw const StorageFailure('credential_save_failed');
    }
  }

  bool _closed = false;
  final bool _preserveOnlineCredentialFacts;
  static final _openDirectories = <String>{};
  late final String _directory;
  late final backups = InformationBackups._(this);
  late final _fileOperationContext = _RepositoryFileOperationContext(this);
  late final fileOutputs = InformationFileOutputs._(_fileOperationContext);
  late final fileOpens = InformationFileOpens._(_fileOperationContext);

  static Future<EncryptedInformationRepository> open(
    String directory,
    DatabaseKeyStore keys, {
    DateTime Function()? clock,
  }) => _open(
    directory,
    keys,
    clock: clock,
    preserveOnlineCredentialFacts: false,
  );

  /// Trusted standalone Host. This preserves facts, never grants authority:
  /// OnlineInformationRuntime must reconcile the private device/chat bindings
  /// before serving requests. Portable restores still discard those bindings.
  static Future<EncryptedInformationRepository> openOnline(
    String directory,
    DatabaseKeyStore keys, {
    DateTime Function()? clock,
    int readCacheMiB = 128,
  }) {
    if (readCacheMiB < 32 || readCacheMiB > 512) {
      throw ArgumentError.value(readCacheMiB, 'readCacheMiB');
    }
    return _open(
      directory,
      keys,
      clock: clock,
      preserveOnlineCredentialFacts: true,
      readCacheMiB: readCacheMiB,
    );
  }

  static Future<EncryptedInformationRepository> _open(
    String directory,
    DatabaseKeyStore keys, {
    DateTime Function()? clock,
    required bool preserveOnlineCredentialFacts,
    int? readCacheMiB,
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
      final headerVersion =
          native.select('PRAGMA user_version').single.values.single as int;
      var openingFormat = _libraryFormat;
      var captureOnOpen = false;
      if (headerVersion > _credentialProgramBatchLibraryFormat) {
        throw const StorageFailure('unsupported_schema');
      }
      if (native
          .select(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='library_format'",
          )
          .isNotEmpty) {
        final marker = native.select(
          'SELECT singleton,version FROM library_format',
        );
        if (marker.length != 1 ||
            marker.single['singleton'] != 1 ||
            marker.single['version'] is! int ||
            (marker.single['version'] as int) < 17 ||
            (marker.single['version'] as int) >
                _credentialProgramBatchLibraryFormat ||
            headerVersion > (marker.single['version'] as int)) {
          throw const StorageFailure('unsupported_schema');
        }
        final storedFormat = marker.single['version'] as int;
        var capabilityFormat = storedFormat;
        final fileBranchState = native.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='library_file_branch_format'",
        );
        if (storedFormat >= _libraryFileBranchFormat) {
          if (fileBranchState.length != 1)
            throw const StorageFailure('unsupported_schema');
          final base = native.select(
            'SELECT singleton,base_format FROM library_file_branch_format',
          );
          if (base.length != 1 ||
              base.single['singleton'] != 1 ||
              base.single['base_format'] is! int ||
              (base.single['base_format'] as int) < 17 ||
              (base.single['base_format'] as int) >
                  _libraryDirectionalSyncFormat) {
            throw const StorageFailure('unsupported_schema');
          }
          capabilityFormat = base.single['base_format'] as int;
        } else if (fileBranchState.isNotEmpty) {
          throw const StorageFailure('unsupported_schema');
        }
        final hasServerState = native
            .select(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='server_runtime_state'",
            )
            .isNotEmpty;
        if (hasServerState !=
            (capabilityFormat >= _serverRuntimeLibraryFormat)) {
          throw const StorageFailure('unsupported_schema');
        }
        final replicaTables = native.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('library_replica_state','library_replica_receipts')",
        );
        if ((capabilityFormat >= _libraryReplicationFormat &&
                replicaTables.length != 2) ||
            (capabilityFormat < _libraryReplicationFormat &&
                replicaTables.isNotEmpty)) {
          throw const StorageFailure('unsupported_schema');
        }
        final journalTables = native.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('library_sync_change_state','library_sync_dirty','library_sync_changes')",
        );
        if ((capabilityFormat >= _libraryChangeJournalFormat &&
                journalTables.length != 3) ||
            (capabilityFormat < _libraryChangeJournalFormat &&
                journalTables.isNotEmpty)) {
          throw const StorageFailure('unsupported_schema');
        }
        final incrementalTables = native.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('library_sync_projection','library_sync_units','library_sync_feed','library_sync_progress','library_sync_blobs')",
        );
        if ((capabilityFormat >= _libraryIncrementalFormat &&
                incrementalTables.length != 5) ||
            (capabilityFormat < _libraryIncrementalFormat &&
                incrementalTables.isNotEmpty)) {
          throw const StorageFailure('unsupported_schema');
        }
        if (capabilityFormat >= _libraryDirectionalSyncFormat &&
            !native
                .select('PRAGMA table_info(library_sync_progress)')
                .any((row) => row['name'] == 'uploaded_cursor')) {
          throw const StorageFailure('unsupported_schema');
        }
        final snapshots = native.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='information_revision_snapshots'",
        );
        if ((storedFormat >= _libraryRevisionSnapshotFormat) !=
            snapshots.isNotEmpty)
          throw const StorageFailure('unsupported_schema');
        final credentialArchives = native.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='credential_material_snapshots'",
        );
        if ((storedFormat >= _libraryCredentialArchiveFormat) !=
            credentialArchives.isNotEmpty)
          throw const StorageFailure('unsupported_schema');
        captureOnOpen = capabilityFormat >= _libraryChangeJournalFormat;
        // Preserve the portable-fill boundary across older receipt/layout
        // formats. Format38 adds local recovery-key operation receipts.
        openingFormat =
            (storedFormat == 23 ||
                storedFormat == 25 ||
                storedFormat == 27 ||
                storedFormat == 29 ||
                storedFormat == 31 ||
                storedFormat == 33 ||
                storedFormat == 35 ||
                storedFormat == 37)
            ? _portableFocusedFillLibraryFormat
            : max(_libraryFormat, storedFormat);
      } else if (headerVersion > _libraryFormat ||
          native
              .select(
                "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('credential_runtime_requests','credential_operations','credential_focused_fills')",
              )
              .isNotEmpty) {
        throw const StorageFailure('unsupported_schema');
      }
      native.execute('PRAGMA foreign_keys = ON');
      if (preserveOnlineCredentialFacts) {
        native.close();
        native = null;
        db = _InformationDatabase(
          NativeDatabase.createInBackground(
            file,
            setup: _onlineDatabaseSetup(hex, readCacheMiB!),
            readPool: 0,
          ),
          openingFormat,
        );
      } else {
        db = _InformationDatabase(NativeDatabase.opened(native), openingFormat);
        native = null; // Drift owns the handle now.
      }
      if (captureOnOpen) {
        // Open/migrate first: beforeOpen itself must not recursively open a
        // transaction through the capture wrapper. Resume before maintenance
        // writes in _load so restart cannot leave ungrouped committed changes.
        await db.customSelect('SELECT 1').get();
        db.syncJournalEnabled = true;
      }
      final repository = EncryptedInformationRepository._(
        db,
        lock,
        version,
        clock ?? DateTime.now,
        preserveOnlineCredentialFacts,
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
    await _createImportFiles();
    // A stage belongs to an in-process owner form, never a resumed grant or
    // formal item. A new process has no valid form handle for orphan bytes.
    await _db.customStatement('DELETE FROM information_file_stages');
    await _db.customStatement('DELETE FROM information_draft_commits');
    await _loadSshTrust();
    await _loadRuntime();
    await _loadCredentialBatches();
    await _loadCredentialPrograms();
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
    if (_credentials.any((c) => c.directoryId != null || c.tagIds.isNotEmpty) &&
        !await _credentialClassificationFormat()) {
      throw const StorageFailure('unsupported_schema');
    }
    await _validateCredentialClassification(_credentials);
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
        in await _db.customSelect(await _revisionRowsQuery()).get()) {
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
    await _loadLibraryRecycleBatches();
    await _loadLibraryOrder();
    await _loadTemplatePackages();
    final items = await _db
        .customSelect('SELECT * FROM information_items ORDER BY rowid')
        .get();
    final fields = await _db
        .customSelect('SELECT * FROM information_fields ORDER BY rowid')
        .get();
    final fieldRows = fields.map((row) => row.data).toList();
    final tagRows = itemTags.map((row) => row.data).toList();
    final fileRows =
        (await _db.customSelect('SELECT * FROM information_file_fields').get())
            .map((r) => r.data)
            .toList();
    for (final item in items) {
      final decoded = _informationFromRows(
        item.data,
        fieldRows,
        tagRows,
        fileRows,
      );
      _items[decoded.id] = decoded;
    }
    await _checkStoredFileReferences();
    await _loadFileDeliveries();
    await _db.transaction(
      () => _reconcileAttachmentRetention(_clock().toUtc()),
    );
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
      await _writeMetadata(
        () => _db.customStatement(
          'INSERT INTO request_history(id,created_at,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
          [
            history.id,
            history.createdAt.toUtc().millisecondsSinceEpoch,
            jsonEncode(history.toJson()),
          ],
        ),
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
      await _writeMetadata(() => _writeGrantHistory(history));
      _history[history.id] = history;
    } on Object {
      throw const StorageFailure('audit_save_failed');
    }
  }

  Future<void> _writeGrantHistory(GrantHistory history) async {
    if (history.itemSnapshots.isNotEmpty) {
      await _requireAdmissionFormat(_libraryGrantSnapshotFormat);
    }
    await _db.customStatement(
      'INSERT INTO grant_history(id,approved_at,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
      [
        history.id,
        history.approvedAt.toUtc().millisecondsSinceEpoch,
        jsonEncode(history.toJson()),
      ],
    );
  }

  @override
  Future<void> saveAccessRecord(AccessRecord record) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _writeMetadata(
        () => _db.customStatement(
          'INSERT INTO access_records(id,recorded_at,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
          [
            record.id,
            record.at.toUtc().millisecondsSinceEpoch,
            jsonEncode(record.toJson()),
          ],
        ),
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
      await _db.transaction(() async {
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
        await _checkAttachmentBackupBudget();
      });
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
      await _writeMetadata(() => _writeDirectory(directory));
      _directories[directory.id] = directory;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  @override
  Future<void> saveTag(InformationTag tag) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _writeMetadata(() => _writeTag(tag));
      _tags[tag.id] = tag;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  @override
  Future<void> commitOrganizationRemoval({
    String? directoryId,
    String? tagId,
    List<InformationItem> items = const [],
    List<InformationRevision> previous = const [],
    required void Function() validate,
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        validate();
        await _guardCredentialClassificationRemoval(
          directoryId: directoryId,
          tagId: tagId,
        );
        for (final item in items) {
          await _writeItem(item);
        }
        for (final revision in previous) {
          await _writeRevision(revision);
        }
        if (directoryId != null) {
          await _db.customStatement(
            'DELETE FROM information_directories WHERE id=?',
            [directoryId],
          );
        }
        if (tagId != null) {
          await _db.customStatement(
            'DELETE FROM information_item_tags WHERE tag_id=?',
            [tagId],
          );
          await _db.customStatement('DELETE FROM information_tags WHERE id=?', [
            tagId,
          ]);
        }
        await _checkAttachmentBackupBudget();
        validate();
      });
      if (directoryId != null) _directories.remove(directoryId);
      if (tagId != null) _tags.remove(tagId);
      for (final item in items) {
        _items[item.id] = item;
      }
      _revisions.addAll(previous);
    } catch (error) {
      if (error is AccessFailure) rethrow;
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
      await _writeMetadata(
        () => _db.customStatement(
          'INSERT INTO settings(name,value) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value',
          [key, value],
        ),
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
        await _checkAttachmentBackupBudget();
      });
      _items[item.id] = item;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  Future<void> _writeItem(InformationItem item) async {
    await _checkItemAttachments(item);
    await _db.customStatement(
      'INSERT INTO information_items(id,name,description,version,directory_id,created_at,modified_at,layout_json) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,description=excluded.description,version=excluded.version,directory_id=excluded.directory_id,created_at=excluded.created_at,modified_at=excluded.modified_at,layout_json=excluded.layout_json',
      [
        item.id,
        item.name,
        item.description,
        item.version,
        item.directoryId,
        item.createdAt?.toUtc().toIso8601String(),
        item.modifiedAt?.toUtc().toIso8601String(),
        item.layout == null ? null : jsonEncode(item.layout!.toJson()),
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
          field.kind == FieldKind.file ? '' : field.value,
          field.version,
          field.kind.name,
        ],
      );
      if (field.attachment case final ref?) {
        await _db.customStatement(
          'INSERT INTO information_file_fields(field_id,attachment_id,attachment_version) VALUES(?,?,?)',
          [field.id, ref.attachmentId, ref.attachmentVersion],
        );
      }
    }
  }

  @override
  List<OrganizationTask> get organizationTasks {
    if (_closed) throw const StorageFailure('library_closed');
    return List.unmodifiable(_organizationTasks.values);
  }

  @override
  Future<InformationApprovalReceipt?> additionalApprovalReceipt(String id) =>
      _additionalApprovalReceipt(id);
  @override
  Future<int> additionalApprovalRevision(String requestId) =>
      _additionalApprovalRevision(requestId);

  Future<void> _writeOrganizationTask(OrganizationTask task) async {
    await _db.customStatement(
      'INSERT INTO organization_tasks(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
      [task.id, jsonEncode(task.toJson())],
    );
    if (pendingAdditionalApproval?.kind == 'organization') {
      await _additionalApprovalCommit(task.id, 'organization');
    }
    if ({
      OrganizationTaskState.confirmed,
      OrganizationTaskState.rejected,
    }.contains(task.state)) {
      await _proposalCommit(
        task.id,
        ProposalKind.organization,
        task.state == OrganizationTaskState.confirmed,
        2,
        task.state == OrganizationTaskState.confirmed
            ? [
                for (final c in task.changes)
                  OwnerProposalTarget(c.itemId, c.baseVersion + 1),
              ]
            : [],
      );
    }
  }

  @override
  Future<void> saveOrganizationTask(OrganizationTask task) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _writeMetadata(
        () => _writeOrganizationTask(task),
        validate:
            {
              OrganizationTaskState.confirmed,
              OrganizationTaskState.rejected,
            }.contains(task.state)
            ? pendingOwnerProposalOperation?.validate
            : pendingAdditionalApproval?.validate,
      );
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
        await _checkAttachmentBackupBudget();
        pendingOwnerProposalOperation?.validate();
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

  Future<void> _requireAdmissionFormat(int format) async {
    final marker = await _db
        .customSelect('SELECT version FROM library_format WHERE singleton=1')
        .getSingle();
    final stored = marker.read<int>('version');
    if (format >= _libraryCredentialArchiveFormat) {
      await _db.customStatement(
        'CREATE TABLE IF NOT EXISTS credential_material_snapshots(credential_id TEXT NOT NULL,version INTEGER NOT NULL,snapshot_id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(credential_id,snapshot_id))',
      );
    }
    if (format >= _libraryRevisionSnapshotFormat) {
      await _db.customStatement(
        'CREATE TABLE IF NOT EXISTS information_revision_snapshots(item_id TEXT NOT NULL,version INTEGER NOT NULL,snapshot_id TEXT NOT NULL,replaced_at TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(item_id,snapshot_id))',
      );
    }
    if (stored >= _libraryFileBranchFormat &&
        format < _libraryFileBranchFormat) {
      final state = await _db
          .customSelect(
            'SELECT base_format FROM library_file_branch_format WHERE singleton=1',
          )
          .getSingle();
      if (state.read<int>('base_format') < format) {
        await _db.customStatement(
          'UPDATE library_file_branch_format SET base_format=? WHERE singleton=1',
          [format],
        );
      }
    } else if (stored < _libraryFileBranchFormat &&
        format >= _libraryFileBranchFormat) {
      // File families are independent of optional server/sync tables. Keep
      // their exact prior capabilities rather than pretending those exist.
      await _db.customStatement(
        'CREATE TABLE library_file_branch_format(singleton INTEGER PRIMARY KEY CHECK(singleton=1),base_format INTEGER NOT NULL)',
      );
      await _db.customStatement(
        'INSERT INTO library_file_branch_format VALUES(1,?)',
        [stored],
      );
    }
    final version = max(stored, format);
    if (stored < version) {
      await _db.customStatement(
        'UPDATE library_format SET version=? WHERE singleton=1 AND version<?',
        [version, version],
      );
    }
    final header = await _db.customSelect('PRAGMA user_version').getSingle();
    if (header.read<int>('user_version') > version) {
      throw const StorageFailure('unsupported_schema');
    }
    if (header.read<int>('user_version') < version) {
      await _db.customStatement('PRAGMA user_version = $version');
    }
  }

  Future<void> _requireTemplateImportFormat() =>
      _requireAdmissionFormat(_templateImportLibraryFormat);

  Future<void> _writeProposal(
    ImportProposal proposal, {
    bool operationReceipt = true,
  }) async {
    if (proposal.credentialSnapshots.isNotEmpty ||
        proposal.items.any((i) => i.credential?.account.isNotEmpty ?? false)) {
      await _requireAdmissionFormat(_credentialProposalPreviewLibraryFormat);
    }
    if (proposal.items.any((i) => i.attachments.isNotEmpty)) {
      await _requireAdmissionFormat(_informationImportFileLibraryFormat);
      await _claimProposalUploads(proposal);
    }
    if (proposal.candidateKinds.values.contains('credential') ||
        proposal.operationId != null) {
      await _requireAdmissionFormat(_credentialImportLibraryFormat);
    }
    if (proposal.admissionVersion > 0) {
      await _requireAdmissionFormat(_importAdmissionLibraryFormat);
    }
    if (proposal.items.any((i) => i.templateId != null)) {
      await _requireTemplateImportFormat();
    }
    await _db.customStatement(
      'INSERT INTO import_proposals(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
      [proposal.id, jsonEncode(proposal.toJson())],
    );
    await _reconcileImportFiles();
    if (operationReceipt && proposal.state != ImportProposalState.pending) {
      await _proposalCommit(
        proposal.id,
        ProposalKind.addition,
        proposal.state == ImportProposalState.confirmed,
        proposal.version,
        proposal.receipts.map(
          (r) => OwnerProposalTarget(r.id, r.version, kind: r.kind),
        ),
      );
    }
  }

  @override
  Future<void> saveImportProposal(ImportProposal proposal) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _writeMetadata(
        () => _writeProposal(proposal),
        validate: proposal.state != ImportProposalState.pending
            ? pendingOwnerProposalOperation?.validate
            : null,
      );
      _proposals[proposal.id] = proposal;
    } catch (_) {
      throw const StorageFailure('save_failed');
    }
  }

  @override
  Future<void> commitInformationAdmission(
    List<ImportProposal> proposals,
    List<InformationItem> items, {
    required String decisionProposalId,
    required bool confirm,
    ProposalKind decisionKind = ProposalKind.addition,
    List<InformationUpdateAdmission> updates = const [],
    List<ManagedCredential> credentialRecords = const [],
    List<CredentialMaterial> credentialMaterials = const [],
    List<InformationImportFilePromotion> filePromotions = const [],
    List<ImportReceipt> decisionRecords = const [],
    List<String> awaitingKeys = const [],
    List<InformationDirectory> newDirectories = const [],
    List<InformationTag> newTags = const [],
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    final decidingVersion = decisionKind == ProposalKind.addition
        ? proposals.singleWhere((p) => p.id == decisionProposalId).version
        : updates
              .singleWhere((u) => u.proposal.id == decisionProposalId)
              .proposal
              .version;
    try {
      await _db.transaction(() async {
        for (final directory in newDirectories) {
          await _writeDirectory(directory);
        }
        for (final tag in newTags) {
          await _writeTag(tag);
        }
        await _promoteImportFiles(filePromotions);
        for (final item in items) {
          await _writeItem(item);
        }
        if (credentialRecords.isNotEmpty) {
          await _requireAdmissionFormat(_credentialImportLibraryFormat);
          await _writeCredentialSnapshot(
            [..._credentials, ...credentialRecords],
            [..._credentialMaterials, ...credentialMaterials],
          );
        }
        for (final proposal in proposals) {
          await _writeProposal(proposal, operationReceipt: false);
        }
        for (final update in updates) {
          if (update.item case final item?) await _writeItem(item);
          if (update.previous case final previous?)
            await _writeRevision(previous);
          await _writeUpdate(update.proposal, operationReceipt: false);
          await _writeRecycle(update.recycled, update.facts);
        }
        if (filePromotions.isNotEmpty) await _checkImportCapacity();
        await _checkAttachmentBackupBudget();
        await _proposalCommit(
          decisionProposalId,
          decisionKind,
          confirm,
          decidingVersion,
          decisionRecords.map(
            (r) => OwnerProposalTarget(r.id, r.version, kind: r.kind),
          ),
          awaitingKeys: awaitingKeys,
        );
        pendingOwnerProposalOperation?.validate();
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
      if (credentialRecords.isNotEmpty) {
        _publishCredentialSnapshot(
          [..._credentials, ...credentialRecords],
          [..._credentialMaterials, ...credentialMaterials],
        );
      }
      for (final proposal in proposals) {
        _proposals[proposal.id] = proposal;
      }
      for (final update in updates) {
        if (update.item case final item?) _items[item.id] = item;
        if (update.previous case final previous?) _revisions.add(previous);
        for (final entry in update.recycled) {
          _recycle[entry.id] = entry;
        }
        _recycleFacts.addAll(update.facts);
        _updates[update.proposal.id] = update.proposal;
      }
    } on AccessFailure catch (e) {
      if (filePromotions.isNotEmpty &&
          {
            'attachment_capacity_exceeded',
            'attachment_integrity_failed',
            'upload_unavailable',
          }.contains(e.status))
        rethrow;
      throw const StorageFailure('save_failed');
    } on sqlite.SqliteException catch (e) {
      if (filePromotions.isNotEmpty &&
          e.resultCode == sqlite.SqlError.SQLITE_FULL)
        throw const AccessFailure('attachment_capacity_exceeded');
      throw const StorageFailure('save_failed');
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
    _fileDeliveries.clear();
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
      await _writeMetadata(() async {
        for (final revision in expired) {
          await _db.customStatement(
            'INSERT INTO revision_purge_facts(item_id,version,purged_at) VALUES(?,?,?) ON CONFLICT(item_id,version) DO NOTHING',
            [
              revision.item.id,
              revision.item.version,
              purgedAt.toUtc().toIso8601String(),
            ],
          );
          final legacy = await _db
              .customSelect(
                'SELECT payload FROM information_revisions WHERE item_id=? AND version=?',
                variables: [
                  Variable(revision.item.id),
                  Variable(revision.item.version),
                ],
              )
              .get();
          if (legacy.isNotEmpty &&
              informationSnapshotId(
                    informationFromJson(_backupJson(legacy.single.data)),
                  ) ==
                  informationSnapshotId(revision.item)) {
            await _db.customStatement(
              'DELETE FROM information_revisions WHERE item_id=? AND version=?',
              [revision.item.id, revision.item.version],
            );
          }
          if (await _hasRevisionSnapshots()) {
            await _db.customStatement(
              'DELETE FROM information_revision_snapshots WHERE item_id=? AND snapshot_id=?',
              [revision.item.id, informationSnapshotId(revision.item)],
            );
          }
        }
        await _reconcileAttachmentRetention(purgedAt.toUtc());
      });
      for (final revision in expired) {
        if (!_revisionPurges.any(
          (p) =>
              p.itemId == revision.item.id &&
              p.version == revision.item.version,
        )) {
          _revisionPurges.add(
            RevisionPurgeFact(
              revision.item.id,
              revision.item.version,
              purgedAt,
            ),
          );
        }
      }
      _revisions.removeWhere((r) => !r.replacedAt.isAfter(cutoff));
    } catch (_) {
      throw const StorageFailure('revision_cleanup_failed');
    }
  }

  Future<void> _writeUpdate(
    UpdateProposal proposal, {
    bool operationReceipt = true,
  }) async {
    if (proposal.operationId != null || proposal.input.attachments.isNotEmpty) {
      await _requireAdmissionFormat(_informationFileUpdateLibraryFormat);
    }
    await _claimFileChanges(
      proposal.sessionBinding,
      proposal.input.attachments,
    );
    if (proposal.approved || proposal.input.pendingRelations.isNotEmpty) {
      await _requireAdmissionFormat(_updateAdmissionLibraryFormat);
    }
    if (proposal.input.templateId != null) {
      await _requireTemplateImportFormat();
    }
    await _db.customStatement(
      'INSERT INTO update_proposals(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
      [proposal.id, jsonEncode(proposal.toJson())],
    );
    await _reconcileImportFiles();
    if (operationReceipt &&
        {
          UpdateProposalState.confirmed,
          UpdateProposalState.rejected,
        }.contains(proposal.state)) {
      await _proposalCommit(
        proposal.id,
        ProposalKind.modification,
        proposal.state == UpdateProposalState.confirmed,
        proposal.version,
        proposal.result == null
            ? []
            : [
                OwnerProposalTarget(
                  proposal.result!.itemId,
                  proposal.result!.version,
                ),
              ],
      );
    }
  }

  Future<bool> _hasRevisionSnapshots() async =>
      (await _db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='information_revision_snapshots'",
              )
              .get())
          .isNotEmpty;

  Future<String> _revisionRowsQuery() async => await _hasRevisionSnapshots()
      ? 'SELECT payload,replaced_at FROM information_revisions UNION ALL SELECT payload,replaced_at FROM information_revision_snapshots ORDER BY replaced_at'
      : 'SELECT payload,replaced_at FROM information_revisions ORDER BY rowid';

  Future<void> _writeRevision(InformationRevision revision) async {
    await _checkItemAttachments(revision.item);
    final existing = await _db
        .customSelect(
          'SELECT payload FROM information_revisions WHERE item_id=? AND version=?',
          variables: [
            Variable(revision.item.id),
            Variable(revision.item.version),
          ],
        )
        .get();
    if (existing.isEmpty ||
        informationSnapshotId(
              informationFromJson(_backupJson(existing.single.data)),
            ) ==
            informationSnapshotId(revision.item)) {
      await _db.customStatement(
        'INSERT INTO information_revisions(item_id,version,replaced_at,payload) VALUES(?,?,?,?) '
        'ON CONFLICT(item_id,version) DO UPDATE SET replaced_at=max(replaced_at,excluded.replaced_at)',
        [
          revision.item.id,
          revision.item.version,
          revision.replacedAt.toUtc().toIso8601String(),
          jsonEncode(informationToJson(revision.item)),
        ],
      );
      return;
    }
    await _requireAdmissionFormat(_libraryRevisionSnapshotFormat);
    await _db.customStatement(
      'INSERT INTO information_revision_snapshots(item_id,version,snapshot_id,replaced_at,payload) VALUES(?,?,?,?,?) '
      'ON CONFLICT(item_id,snapshot_id) DO UPDATE SET replaced_at=max(replaced_at,excluded.replaced_at)',
      [
        revision.item.id,
        revision.item.version,
        informationSnapshotId(revision.item),
        revision.replacedAt.toUtc().toIso8601String(),
        jsonEncode(informationToJson(revision.item)),
      ],
    );
  }

  @override
  Future<void> saveUpdateProposal(UpdateProposal proposal) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _writeMetadata(
        () => _writeUpdate(proposal),
        validate:
            {
              UpdateProposalState.confirmed,
              UpdateProposalState.rejected,
            }.contains(proposal.state)
            ? pendingOwnerProposalOperation?.validate
            : null,
      );
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
        await _checkAttachmentBackupBudget();
      });
      _items[item.id] = item;
      _revisions.add(previous);
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

  Future<void> _writeDelete(DeleteProposal proposal) async {
    await _db.customStatement(
      'INSERT INTO delete_proposals(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
      [proposal.id, jsonEncode(proposal.toJson())],
    );
    if ({
      DeleteProposalState.confirmed,
      DeleteProposalState.rejected,
    }.contains(proposal.state)) {
      await _proposalCommit(
        proposal.id,
        ProposalKind.deletion,
        proposal.state == DeleteProposalState.confirmed,
        proposal.version,
        proposal.state == DeleteProposalState.confirmed
            ? [
                OwnerProposalTarget(
                  proposal.itemId,
                  proposal.baseVersion + 1,
                  recycleId: proposal.entryId,
                ),
              ]
            : [],
      );
    }
  }

  @override
  Future<void> saveDeleteProposal(DeleteProposal proposal) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _writeMetadata(
        () => _writeDelete(proposal),
        validate:
            {
              DeleteProposalState.confirmed,
              DeleteProposalState.rejected,
            }.contains(proposal.state)
            ? pendingOwnerProposalOperation?.validate
            : null,
      );
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
    InformationLifecycleReceipt? lifecycleReceipt,
    void Function()? validate,
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        validate?.call();
        if (lifecycleReceipt != null) {
          if (lifecycleReceipt.command.itemId != itemId) {
            throw const AccessFailure('invalid_information');
          }
          await _validateLifecycle(lifecycleReceipt);
        }
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
        if (lifecycleReceipt != null) {
          await _db.customStatement(
            'INSERT INTO information_lifecycle_operations(operation_id,payload) VALUES(?,?)',
            [
              lifecycleReceipt.command.operationId,
              jsonEncode(lifecycleReceipt.toJson()),
            ],
          );
        }
        await _checkAttachmentBackupBudget();
        validate?.call();
        if (proposal != null) pendingOwnerProposalOperation?.validate();
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
    } catch (error) {
      // Legacy callers retain their storage-failure contract. Commands with
      // explicit version/generation checks expose those conflicts to the UI.
      if (error is AccessFailure &&
          (lifecycleReceipt != null || validate != null)) {
        rethrow;
      }
      throw const StorageFailure('save_failed');
    }
  }
}

class _InformationDatabase extends GeneratedDatabase {
  _InformationDatabase(super.executor, this._openingFormat);
  final int _openingFormat;
  bool syncJournalEnabled = false;
  final _syncTransactionZone = Object();
  final _syncIncomingZone = Object();

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) {
    final outermost = Zone.current[_syncTransactionZone] != true;
    return super.transaction(
      () => runZoned(() async {
        final result = await action();
        if (outermost && syncJournalEnabled) await _flushSyncChanges();
        return result;
      }, zoneValues: {_syncTransactionZone: true}),
      requireNew: requireNew,
    );
  }

  @override
  Future<void> customStatement(String statement, [List<Object?>? args]) {
    // Most business writes already use a transaction. Keep any single-statement
    // write in the same commit as its journal entry too; reads use customSelect.
    if (syncJournalEnabled && Zone.current[_syncTransactionZone] != true) {
      return transaction(() => super.customStatement(statement, args));
    }
    return super.customStatement(statement, args);
  }

  @override
  int get schemaVersion => _openingFormat;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await _createLibraryFormat();
      await _createInformationFileStages();
      await _createSshHostTrust();
      await _createCredentialRuntime();
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
        'CREATE TABLE information_items(id TEXT PRIMARY KEY,name TEXT NOT NULL,description TEXT NOT NULL,version INTEGER NOT NULL DEFAULT 1,created_at TEXT,modified_at TEXT,layout_json TEXT)',
      );
      await customStatement(
        'CREATE TABLE information_fields(id TEXT PRIMARY KEY,item_id TEXT NOT NULL REFERENCES information_items(id),name TEXT NOT NULL,description TEXT NOT NULL,value TEXT NOT NULL,version INTEGER NOT NULL DEFAULT 1,kind TEXT NOT NULL DEFAULT \'structured\')',
      );
      await _createInformationAttachments();
      await _createInformationRecordOperations();
      await _createInformationDeliveries();
      await _organizationSchema();
      await _createInformationClassification();
      await _createInformationLifecycle();
      await _createInformationApproval();
      await _createBackupOperations();
      await _backupSchema();
    },
    onUpgrade: (_, from, to) async {
      if (from < 1 || from > to || to != schemaVersion) {
        throw const StorageFailure('unsupported_schema');
      }
      var sourceVersion = from;
      final hasMarker = await customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='library_format'",
      ).get();
      if (hasMarker.isNotEmpty) {
        final marker = await customSelect(
          'SELECT version FROM library_format WHERE singleton=1',
        ).getSingle();
        if (marker.read<int>('version') == schemaVersion) return;
        sourceVersion = marker.read<int>('version');
      }
      await transaction(() async {
        if (sourceVersion < 21 &&
            (await customSelect(
              "SELECT name FROM sqlite_master WHERE name='information_deliveries'",
            ).get()).isNotEmpty) {
          throw const StorageFailure('unsupported_schema');
        }
        if (sourceVersion < 20 &&
            (await customSelect(
              "SELECT name FROM sqlite_master WHERE name IN ('information_attachment_versions','information_file_fields','information_draft_commits')",
            ).get()).isNotEmpty) {
          throw const StorageFailure('unsupported_schema');
        }
        if (sourceVersion < 19 &&
            (await customSelect(
              "SELECT name FROM sqlite_master WHERE name='information_file_stages'",
            ).get()).isNotEmpty) {
          throw const StorageFailure('unsupported_schema');
        }
        if (sourceVersion < 18 &&
            (await customSelect(
              "SELECT name FROM sqlite_master WHERE name='credential_focused_fills'",
            ).get()).isNotEmpty) {
          throw const StorageFailure('unsupported_schema');
        }
        if (sourceVersion < 16) await _createSshHostTrust();
        if (sourceVersion < 15) {
          await _createCredentialRuntime();
        } else if (sourceVersion < 17) {
          await _migrateCredentialRuntime17();
        }
        if (sourceVersion < 14) await _createCredentials();
        if (sourceVersion < 2) {
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
        if (sourceVersion < 3) await _organizationSchema();
        if (sourceVersion < 4) {
          await _createTemplates();
          await customStatement(
            'ALTER TABLE information_fields ADD COLUMN kind TEXT NOT NULL DEFAULT \'structured\'',
          );
        }
        if (sourceVersion < 5) await _backupSchema();
        if (sourceVersion < 6) await _createProposals();
        if (sourceVersion < 7) await _createAudit();
        if (sourceVersion < 8) await _createUpdates();
        if (sourceVersion < 9) await _createRecycle();
        if (sourceVersion < 10) await _createRevisionPurges();
        if (sourceVersion < 12) await _createOrganizationTasks();
        if (sourceVersion < 13) await _createRequestHistory();
        if (sourceVersion < 11) {
          await customStatement(
            'ALTER TABLE information_items ADD COLUMN created_at TEXT',
          );
          await customStatement(
            'ALTER TABLE information_items ADD COLUMN modified_at TEXT',
          );
        }
        if (sourceVersion < 18) await _createFocusedFillRuntime();
        if (sourceVersion < 19) await _createInformationFileStages();
        if (sourceVersion < 20) await _createInformationAttachments();
        if (sourceVersion < 21) await _createInformationDeliveries();
        if (sourceVersion < 24) await _createInformationRecordOperations();
        if (sourceVersion < 26) await _createInformationLayout();
        if (sourceVersion < 30) await _createInformationClassification();
        if (sourceVersion < 32) await _createInformationLifecycle();
        if (sourceVersion < 36) await _createInformationApproval();
        if (sourceVersion < 38) await _createBackupOperations();
        await _createLibraryFormat();
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
      // Local receipts add no portable content or live capabilities.
      await customStatement(
        'CREATE TABLE IF NOT EXISTS desktop_preference_operations('
        'operation_id TEXT PRIMARY KEY,payload TEXT NOT NULL,invalidated INTEGER NOT NULL DEFAULT 0 CHECK(invalidated IN (0,1)))',
      );
      await customStatement(
        'CREATE TABLE IF NOT EXISTS owner_proposal_operations('
        'operation_id TEXT PRIMARY KEY,payload TEXT NOT NULL,invalidated INTEGER NOT NULL DEFAULT 0 CHECK(invalidated IN (0,1)))',
      );
      await customStatement(
        'CREATE TABLE IF NOT EXISTS template_packages('
        'id TEXT PRIMARY KEY,source TEXT,enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),origin TEXT NOT NULL,legacy_json TEXT)',
      );
      await customStatement(
        'CREATE TABLE IF NOT EXISTS additional_approval_operations(operation_id TEXT PRIMARY KEY,request_id TEXT NOT NULL,payload TEXT NOT NULL,invalidated INTEGER NOT NULL DEFAULT 0)',
      );
      await customStatement(
        'CREATE TABLE IF NOT EXISTS library_recycle_batches(id TEXT PRIMARY KEY,payload TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE IF NOT EXISTS library_recycle_operations(operation_id TEXT PRIMARY KEY,payload TEXT NOT NULL,invalidated INTEGER NOT NULL DEFAULT 0 CHECK(invalidated IN (0,1)))',
      );
      await customStatement(
        'CREATE TABLE IF NOT EXISTS library_move_operations(operation_id TEXT PRIMARY KEY,payload TEXT NOT NULL,invalidated INTEGER NOT NULL DEFAULT 0 CHECK(invalidated IN (0,1)))',
      );
      await customStatement(
        'CREATE TABLE IF NOT EXISTS library_order_state(id TEXT PRIMARY KEY CHECK(id=\'current\'),payload TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE IF NOT EXISTS template_package_operations('
        'operation_id TEXT PRIMARY KEY,payload TEXT NOT NULL,invalidated INTEGER NOT NULL DEFAULT 0 CHECK(invalidated IN (0,1)))',
      );
    },
  );

  Future<void> _createLibraryFormat() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS library_format(singleton INTEGER PRIMARY KEY CHECK(singleton=1),version INTEGER NOT NULL)',
    );
    await customStatement(
      'INSERT INTO library_format(singleton,version) VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET version=excluded.version WHERE version<excluded.version',
      [schemaVersion],
    );
  }

  Future<void> _createInformationFileStages() => customStatement(
    'CREATE TABLE information_file_stages('
    'id TEXT PRIMARY KEY,draft_id TEXT NOT NULL,byte_length INTEGER NOT NULL '
    'CHECK(byte_length>=0),metadata TEXT NOT NULL,body BLOB NOT NULL '
    'CHECK(length(body)=byte_length))',
  );

  Future<void> _createInformationLayout() async {
    final columns = await customSelect(
      'PRAGMA table_info(information_items)',
    ).get();
    if (columns.any((r) => r.read<String>('name') == 'layout_json')) {
      // Development/legacy fixtures can carry the empty additive column, but a
      // downgraded marker must never hide already persisted layout content.
      final used = await customSelect(
        'SELECT 1 FROM information_items WHERE layout_json IS NOT NULL LIMIT 1',
      ).get();
      if (used.isNotEmpty) throw const StorageFailure('unsupported_schema');
      return;
    }
    await customStatement(
      'ALTER TABLE information_items ADD COLUMN layout_json TEXT',
    );
  }

  Future<void> _createInformationRecordOperations() => customStatement(
    'CREATE TABLE IF NOT EXISTS information_record_operations('
    'operation_id TEXT PRIMARY KEY,payload TEXT NOT NULL,'
    'invalidated INTEGER NOT NULL DEFAULT 0 CHECK(invalidated IN (0,1)))',
  );

  Future<void> _createInformationApproval() => customStatement(
    'CREATE TABLE IF NOT EXISTS information_approval_operations(operation_id TEXT PRIMARY KEY,request_id TEXT NOT NULL,revision INTEGER NOT NULL CHECK(revision>0),payload TEXT NOT NULL,invalidated INTEGER NOT NULL DEFAULT 0 CHECK(invalidated IN (0,1)),UNIQUE(request_id,revision))',
  );

  Future<void> _createInformationLifecycle() => customStatement(
    'CREATE TABLE IF NOT EXISTS information_lifecycle_operations(operation_id TEXT PRIMARY KEY,payload TEXT NOT NULL,invalidated INTEGER NOT NULL DEFAULT 0 CHECK(invalidated IN (0,1)))',
  );

  Future<void> _createInformationClassification() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS information_classification_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),version INTEGER NOT NULL CHECK(version>=1))',
    );
    await customStatement(
      'INSERT OR IGNORE INTO information_classification_state VALUES(1,1)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS information_classification_operations(operation_id TEXT PRIMARY KEY,payload TEXT NOT NULL,invalidated INTEGER NOT NULL DEFAULT 0 CHECK(invalidated IN (0,1)))',
    );
    for (final table in ['information_directories', 'information_tags']) {
      for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
        await customStatement(
          'CREATE TRIGGER IF NOT EXISTS ${table}_${operation.toLowerCase()}_classification AFTER $operation ON $table BEGIN UPDATE information_classification_state SET version=version+1 WHERE singleton=1; END',
        );
      }
    }
  }

  Future<void> _createInformationAttachments() async {
    await customStatement(
      'CREATE TABLE information_attachment_versions(attachment_id TEXT NOT NULL,version INTEGER NOT NULL,metadata TEXT NOT NULL,byte_length INTEGER NOT NULL CHECK(byte_length>=0),body BLOB CHECK(body IS NULL OR length(body)=byte_length),PRIMARY KEY(attachment_id,version))',
    );
    await customStatement(
      'CREATE TABLE information_file_fields(field_id TEXT PRIMARY KEY REFERENCES information_fields(id) ON DELETE CASCADE,attachment_id TEXT NOT NULL,attachment_version INTEGER NOT NULL,FOREIGN KEY(attachment_id,attachment_version) REFERENCES information_attachment_versions(attachment_id,version))',
    );
    await customStatement(
      'CREATE TABLE information_draft_commits(draft_id TEXT NOT NULL,operation_id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(draft_id,operation_id))',
    );
  }

  Future<void> _createInformationDeliveries() => customStatement(
    'CREATE TABLE information_deliveries(id TEXT PRIMARY KEY,session_binding TEXT,operation_id TEXT NOT NULL,'
    'payload TEXT NOT NULL CHECK(length(CAST(payload AS BLOB))<=262144),UNIQUE(session_binding,operation_id))',
  );

  Future<void> _migrateCredentialRuntime17() async {
    final names = (await customSelect(
      "SELECT name FROM sqlite_master WHERE type='table'",
    ).get()).map((r) => r.read<String>('name')).toSet();
    const old = {'credential_use_requests', 'credential_executions'},
        current = {'credential_runtime_requests', 'credential_operations'};
    if (names.containsAll(old) && names.intersection(current).isEmpty) {
      await customStatement(
        'ALTER TABLE credential_use_requests RENAME TO credential_runtime_requests',
      );
      await customStatement(
        'ALTER TABLE credential_executions RENAME TO credential_operations',
      );
    } else if (!names.containsAll(current) ||
        names.intersection(old).isNotEmpty) {
      throw const StorageFailure('unsupported_schema');
    }
    // An old Drift reader may reset user_version before its missing-table
    // failure. The independent native format marker remains authoritative.
  }

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

  Future<void> _createSshHostTrust() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS ssh_host_trust(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL)',
    );
  }

  Future<void> _createCredentialRuntime() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS credential_runtime_requests(id TEXT PRIMARY KEY,payload TEXT NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS credential_operations(id TEXT PRIMARY KEY,request_id TEXT NOT NULL REFERENCES credential_runtime_requests(id),payload TEXT NOT NULL)',
    );
    await _createFocusedFillRuntime();
  }

  Future<void> _createFocusedFillRuntime() => customStatement(
    'CREATE TABLE IF NOT EXISTS credential_focused_fills(id TEXT PRIMARY KEY,request_id TEXT NOT NULL REFERENCES credential_runtime_requests(id),payload TEXT NOT NULL)',
  );

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

  Future<void> _createBackupOperations() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS backup_operation_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),version INTEGER NOT NULL CHECK(version>=1))',
    );
    await customStatement(
      'INSERT OR IGNORE INTO backup_operation_state VALUES(1,1)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS backup_operations(operation_id TEXT PRIMARY KEY,payload TEXT NOT NULL,invalidated INTEGER NOT NULL DEFAULT 0 CHECK(invalidated IN (0,1)))',
    );
  }

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

// Construct outside the opener so the worker captures only these two values,
// never the native handle, key store, repository lock or caller's stack.
DatabaseSetup _onlineDatabaseSetup(String hex, int readCacheMiB) => (db) {
  if (db.select('PRAGMA cipher_version').isEmpty) {
    throw const StorageFailure('cipher_unavailable');
  }
  db.execute('PRAGMA key = "x\'$hex\'"');
  db.execute('PRAGMA temp_store = MEMORY');
  db.execute('PRAGMA foreign_keys = ON');
  final budget = -readCacheMiB * 1024;
  db.execute('PRAGMA cache_size = $budget');
  if (db.select('PRAGMA cache_size').single.values.single != budget) {
    throw const StorageFailure('cache_configuration_failed');
  }
};
