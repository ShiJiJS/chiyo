import 'information_layout.dart';
export 'information_layout.dart';
import 'organization_tasks.dart';
import 'organization.dart';
export 'organization.dart';
import 'templates.dart';
import 'history.dart';
import 'import_proposals.dart';
import 'update_proposals.dart';
import 'recycle.dart';
import 'revisions.dart';
import 'credentials.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'information_files.dart';
import 'information_import_files.dart';
import 'info_core.dart'
    show
        AccessFailure,
        ProposalKind,
        CredentialRuntimeRepository,
        CredentialUseRequest,
        CredentialExecution,
        FocusedFillRuntimeRepository,
        FocusedFillOperation,
        InformationAttachmentRepository,
        InformationDraftChange,
        InformationDraftReceipt,
        InformationRecordReceipt,
        InformationApprovalRepository,
        InformationApprovalReceipt,
        InformationApprovalCommit,
        InformationApprovalAction,
        FieldRef,
        InformationLifecycleReceipt,
        InformationPurgeChange,
        InformationPurgeRepository,
        InformationLifecycleAction,
        InformationLifecycleRepository,
        InformationRecordOperationRepository,
        InformationAttachmentSeparationRepository,
        InformationClassificationRepository,
        InformationClassificationChange,
        InformationClassificationReceipt,
        InformationClassificationAction,
        InformationClassificationKind,
        InformationFileDeliveryRepository,
        InformationFileDelivery,
        SshHostTrustRepository,
        SshHostTrustSnapshot;
part 'memory_information_files.dart';
part 'memory_information_import_files.dart';
part 'memory_classification_operations.dart';
part 'memory_information_purge.dart';

enum FieldKind { structured, textNote, file }

/// A stable reference to immutable bytes, never a path or an access capability.
final class InformationAttachmentRef {
  InformationAttachmentRef(this.attachmentId, this.attachmentVersion) {
    if (attachmentId.isEmpty ||
        attachmentId.length > 200 ||
        attachmentId.codeUnits.any((c) => c < 33 || c > 126) ||
        attachmentVersion < 1) {
      throw const FormatException('Invalid attachment reference');
    }
  }
  final String attachmentId;
  final int attachmentVersion;
  Map<String, Object> toJson() => {
    'attachmentId': attachmentId,
    'attachmentVersion': attachmentVersion,
  };
  factory InformationAttachmentRef.fromJson(Map<String, dynamic> json) {
    if (json.length != 2 ||
        json['attachmentId'] is! String ||
        json['attachmentVersion'] is! int) {
      throw const FormatException('Invalid attachment reference');
    }
    return InformationAttachmentRef(
      json['attachmentId'] as String,
      json['attachmentVersion'] as int,
    );
  }
  @override
  bool operator ==(Object other) =>
      other is InformationAttachmentRef &&
      attachmentId == other.attachmentId &&
      attachmentVersion == other.attachmentVersion;
  @override
  int get hashCode => Object.hash(attachmentId, attachmentVersion);
}

sealed class InformationContent {
  const InformationContent();
}

final class InformationText extends InformationContent {
  const InformationText(this.value);
  final String value;
}

final class InformationFile extends InformationContent {
  const InformationFile(this.reference);
  final InformationAttachmentRef reference;
}

/// Public metadata is kept distinct from controlled field values.
class FieldInput {
  const FieldInput(
    this.name,
    this.description,
    String value, {
    this.kind = FieldKind.structured,
  }) : _value = value,
       _file = null,
       assert(kind != FieldKind.file);
  const FieldInput.file(
    this.name,
    this.description,
    InformationAttachmentRef file,
  ) : kind = FieldKind.file,
      _file = file,
      _value = null;
  final String name;
  final String description;
  final String? _value;
  final InformationAttachmentRef? _file;
  final FieldKind kind;
  InformationContent get content => kind == FieldKind.file
      ? InformationFile(
          _file ?? (throw const FormatException('Invalid file payload')),
        )
      : InformationText(_value!);
  String get value {
    if (kind == FieldKind.file) {
      throw const AccessFailure('file_delivery_required');
    }
    return _value!;
  }

  /// Agent proposals can write text or remove a file, not supply file bytes or IDs.
  Map<String, Object?> toJson() {
    if (kind == FieldKind.file) {
      throw const AccessFailure('unsupported_file_write');
    }
    return {
      'name': name,
      'description': description,
      'value': value,
      'kind': kind.name,
    };
  }

  factory FieldInput.fromJson(Map<String, dynamic> json) {
    final kind = FieldKind.values.byName(
      json['kind'] as String? ?? 'structured',
    );
    if (kind == FieldKind.file) {
      throw const AccessFailure('unsupported_file_write');
    }
    if (json.keys.any(
      (k) => !{'name', 'description', 'value', 'kind'}.contains(k),
    )) {
      throw const FormatException('Invalid text payload');
    }
    return FieldInput(
      json['name'] as String,
      json['description'] as String? ?? '',
      json['value'] as String,
      kind: kind,
    );
  }
}

class InformationField {
  const InformationField(
    this.id,
    this.name,
    this.description,
    String value,
    this.version, {
    this.kind = FieldKind.structured,
  }) : _value = value,
       _file = null,
       assert(kind != FieldKind.file);
  const InformationField.file(
    this.id,
    this.name,
    this.description,
    InformationAttachmentRef file,
    this.version,
  ) : _file = file,
      _value = null,
      kind = FieldKind.file;
  final String id, name, description;
  final String? _value;
  final InformationAttachmentRef? _file;
  final int version;
  final FieldKind kind;
  InformationContent get content => kind == FieldKind.file
      ? InformationFile(
          _file ?? (throw const FormatException('Invalid file payload')),
        )
      : InformationText(_value!);
  InformationAttachmentRef? get attachment =>
      kind == FieldKind.file ? (content as InformationFile).reference : null;
  String get value {
    if (kind == FieldKind.file) {
      throw const AccessFailure('file_delivery_required');
    }
    return _value!;
  }

  /// Copies identity/metadata while retaining the same discriminated payload.
  InformationField withMetadata({
    String? id,
    String? name,
    String? description,
    int? version,
  }) => switch (content) {
    InformationText(:final value) => InformationField(
      id ?? this.id,
      name ?? this.name,
      description ?? this.description,
      value,
      version ?? this.version,
      kind: kind,
    ),
    InformationFile(:final reference) => InformationField.file(
      id ?? this.id,
      name ?? this.name,
      description ?? this.description,
      reference,
      version ?? this.version,
    ),
  };

  bool hasSameContent(InformationField other) =>
      kind == other.kind &&
      (kind == FieldKind.file
          ? attachment == other.attachment
          : value == other.value);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'version': version,
    'kind': kind.name,
    if (kind == FieldKind.file)
      'content': attachment!.toJson()
    else
      'value': value,
  };
  factory InformationField.fromJson(Map<String, dynamic> json) {
    final kind = FieldKind.values.byName(json['kind'] as String);
    final file = kind == FieldKind.file;
    final allowed = {
      'id',
      'name',
      'description',
      'version',
      'kind',
      file ? 'content' : 'value',
    };
    if (json.keys.any((key) => !allowed.contains(key)) ||
        json['version'] is! int ||
        (json['version'] as int) < 1) {
      throw const FormatException('Invalid field payload');
    }
    if (file) {
      return InformationField.file(
        json['id'] as String,
        json['name'] as String,
        json['description'] as String,
        InformationAttachmentRef.fromJson(
          json['content'] as Map<String, dynamic>,
        ),
        json['version'] as int,
      );
    }
    return InformationField(
      json['id'] as String,
      json['name'] as String,
      json['description'] as String,
      json['value'] as String,
      json['version'] as int,
      kind: kind,
    );
  }

  /// Corrects the current value without changing the field's meaning or identity.
  InformationField correctValue(String value) {
    if (kind == FieldKind.file) {
      throw const AccessFailure('unsupported_file_write');
    }
    return InformationField(
      id,
      name,
      description,
      value,
      version + 1,
      kind: kind,
    );
  }
}

class InformationItem {
  InformationItem(
    this.id,
    this.name,
    this.description,
    this.version,
    List<InformationField> fields, {
    this.directoryId,
    this.createdAt,
    this.modifiedAt,
    this.layout,
    Iterable<String> tagIds = const [],
  }) : fields = List.unmodifiable(fields),
       tagIds = List.unmodifiable(tagIds);
  final String id, name, description;
  final int version;
  final List<InformationField> fields;
  final String? directoryId;

  /// Owner-only wall-clock facts; null means the original time is unknown.
  /// Versions order changes even when the system clock moves backwards.
  final DateTime? createdAt, modifiedAt;
  final List<String> tagIds;
  final InformationLayout? layout;
}

class InformationUpdateAdmission {
  const InformationUpdateAdmission(
    this.proposal, {
    this.item,
    this.previous,
    this.recycled = const [],
    this.facts = const [],
    this.filePromotions = const [],
  });
  final UpdateProposal proposal;
  final InformationItem? item;
  final InformationRevision? previous;
  final List<RecycleEntry> recycled;
  final List<RecycleFact> facts;
  final List<InformationImportFilePromotion> filePromotions;
}

/// Owner-side storage seam. Agent transports never receive this capability.
abstract interface class InformationRepository {
  List<OrganizationTask> get organizationTasks;
  Future<void> saveOrganizationTask(OrganizationTask task);
  Future<void> confirmOrganizationTask(
    OrganizationTask task,
    List<InformationItem> items,
    List<InformationRevision> previous, {
    List<InformationDirectory> newDirectories = const [],
    List<InformationTag> newTags = const [],
    void Function()? validate,
  });

  List<GrantHistory> get grantHistory;
  List<RequestHistory> get requestHistory;
  Future<void> saveRequestHistory(RequestHistory history);
  List<AccessRecord> get accessRecords;
  Future<void> saveGrantHistory(GrantHistory history);
  Future<void> saveAccessRecord(AccessRecord record);
  Future<void> pruneAudit(DateTime cutoff);
  Future<void> pruneOrganizationHistory(Set<String> ids);
  List<InformationItem> get items;
  Future<void> save(InformationItem item);
  List<InformationDirectory> get directories;
  List<InformationTag> get tags;
  Future<void> saveDirectory(InformationDirectory directory);
  Future<void> saveTag(InformationTag tag);

  /// Owner-only removal; values, field identities and historical snapshots stay.
  Future<void> commitOrganizationRemoval({
    String? directoryId,
    String? tagId,
    List<InformationItem> items = const [],
    List<InformationRevision> previous = const [],
    required void Function() validate,
  });
  int? readSetting(String key);
  Future<void> writeSetting(String key, int value);
  List<InformationTemplate> get templates;
  Future<void> saveTemplate(InformationTemplate template);
  Future<void> deleteTemplate(String id);
  List<ImportProposal> get importProposals;
  Future<void> saveImportProposal(ImportProposal proposal);

  /// One owner decision can release several previously approved proposals.
  /// Records, candidate states and the deciding operation receipt commit together.
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
  });

  List<UpdateProposal> get updateProposals;
  List<InformationRevision> get informationRevisions;
  List<RevisionPurgeFact> get revisionPurgeFacts;
  Future<void> pruneInformationRevisions(DateTime cutoff, DateTime purgedAt);
  Future<void> saveUpdateProposal(UpdateProposal proposal);
  Future<void> saveInformationRevision(
    InformationItem item,
    InformationRevision previous,
  );
  List<RecycleEntry> get recycleEntries;
  List<RecycleFact> get recycleFacts;
  List<DeleteProposal> get deleteProposals;
  Future<void> saveDeleteProposal(DeleteProposal proposal);
  Future<void> commitRecycleChange({
    required String itemId,
    InformationItem? item,
    InformationRevision? previous,
    required List<RecycleEntry> entries,
    required List<RecycleFact> facts,
    DeleteProposal? proposal,
    InformationLifecycleReceipt? lifecycleReceipt,
    void Function()? validate,
  });
}

class MemoryInformationRepository
    implements
        InformationRepository,
        CredentialRepository,
        CredentialRuntimeRepository,
        FocusedFillRuntimeRepository,
        InformationAttachmentRepository,
        InformationImportFileRepository,
        InformationFileDeliveryRepository,
        InformationRecordOperationRepository,
        InformationAttachmentSeparationRepository,
        InformationLifecycleRepository,
        InformationApprovalRepository,
        InformationPurgeRepository,
        InformationClassificationRepository,
        SshHostTrustRepository {
  @override
  Future<void> commitInformationPurge(InformationPurgeChange change) async =>
      _commitPurge(change);
  final _purgedInformationCommits = <String>{};
  final _importUploadData = <String, (InformationImportUpload, Uint8List?)>{};
  final _claimedImportUploads = <String>{};
  @override
  Future<InformationImportUpload?> importFileUpload(String id) async =>
      _importUploadData[id]?.$1;
  @override
  Future<InformationImportUpload?> importFileOperation(
    String binding,
    String operationId,
  ) async => _importUploadData.values
      .where(
        (v) =>
            v.$1.sessionBinding == binding && v.$1.operationId == operationId,
      )
      .firstOrNull
      ?.$1;
  @override
  Future<void> stageImportFile(
    InformationImportUpload upload,
    Uint8List bytes,
  ) => _stageImportOriginal(upload, bytes);
  @override
  Future<T> withImportFile<T>(
    String id,
    Future<T> Function(InformationImportUpload, Stream<Uint8List>) action,
  ) => _withImportOriginal(id, action);
  @override
  Future<void> pruneImportFiles(DateTime cutoff, Set<String> retained) async {
    _importUploadData.removeWhere(
      (id, row) => !retained.contains(id) && row.$1.createdAt.isBefore(cutoff),
    );
  }

  final _approvalReceipts = <String, InformationApprovalReceipt>{};
  @override
  Future<InformationApprovalReceipt?> informationApprovalReceipt(
    String id,
  ) async => _approvalReceipts[id];
  @override
  Future<int> informationApprovalRevision(String id) async => _approvalReceipts
      .values
      .where((r) => r.requestId == id)
      .fold<int>(0, (v, r) => v > r.revision ? v : r.revision);
  @override
  Future<void> commitInformationApproval(
    InformationApprovalCommit change, {
    void Function()? validate,
  }) async {
    final receipt = change.receipt;
    final revision = _approvalReceipts.values
        .where((r) => r.requestId == receipt.requestId)
        .fold<int>(0, (v, r) => v > r.revision ? v : r.revision);
    if (_approvalReceipts.containsKey(receipt.operationId) ||
        receipt.revision != revision + 1) {
      throw const AccessFailure('operation_conflict');
    }
    for (final entry in change.itemVersions.entries) {
      if (_items[entry.key]?.version != entry.value) {
        throw const AccessFailure('scope_changed');
      }
    }
    if (change.receipt.action == InformationApprovalAction.approve) {
      for (final recorded in change.grant!.fields) {
        final field = _items[recorded.itemId]?.fields
            .where((f) => f.id == recorded.fieldId)
            .firstOrNull;
        final expected =
            change.expectedFiles[FieldRef(recorded.itemId, recorded.fieldId)];
        if (field == null ||
            (field.kind == FieldKind.file
                ? expected != field.attachment
                : expected != null)) {
          throw const AccessFailure('scope_changed');
        }
      }
      for (final ref in change.expectedFiles.values.toSet()) {
        final original = _informationFiles[ref];
        if (original == null || !original.$1.available || original.$2 == null) {
          throw const AccessFailure('attachment_missing');
        }
        if (original.$2!.length != original.$1.byteLength ||
            crypto.sha256.convert(original.$2!).toString() !=
                original.$1.sha256) {
          throw const AccessFailure('attachment_integrity_failed');
        }
      }
    }
    change.validatePrevious(
      _requestHistory[change.request.id],
      _history[change.grant?.id],
    );
    validate?.call();
    _approvalReceipts[receipt.operationId] = receipt;
    _requestHistory[change.request.id] = change.request;
    if (change.grant case final grant?) _history[grant.id] = grant;
  }

  final _lifecycleReceipts = <String, InformationLifecycleReceipt>{};
  @override
  Future<InformationLifecycleReceipt?> informationLifecycleReceipt(
    String id,
  ) async => _lifecycleReceipts[id];
  final _classificationReceipts = <String, InformationClassificationReceipt>{};
  int _classificationRevision = 1;
  String? _classificationFingerprint;
  @override
  Future<int> informationClassificationVersion() async =>
      _classificationVersion();
  @override
  Future<InformationClassificationReceipt?> informationClassificationReceipt(
    String operationId,
  ) async => _classificationReceipts[operationId];
  @override
  Future<InformationClassificationReceipt> commitInformationClassification(
    InformationClassificationChange change,
  ) async {
    change.validate();
    if (_classificationVersion() != change.command.expectedVersion) {
      throw const AccessFailure('organization_conflict');
    }
    if (_classificationReceipts.containsKey(change.command.operationId)) {
      throw const AccessFailure('operation_conflict');
    }
    if (change.directory != null) {
      _directories[change.targetId] = change.directory!;
    }
    if (change.tag != null) _tags[change.targetId] = change.tag!;
    if (change.command.action == InformationClassificationAction.delete) {
      if (change.command.kind == InformationClassificationKind.directory) {
        _directories.remove(change.targetId);
      } else {
        _tags.remove(change.targetId);
      }
    }
    for (final item in change.items) {
      _items[item.id] = item;
    }
    _revisions.addAll(change.previous);
    for (final credential in change.credentials) {
      final index = _credentials.indexWhere((c) => c.id == credential.id);
      if (index >= 0) _credentials[index] = credential;
    }
    final receipt = change.receipt(_classificationVersion());
    _classificationReceipts[receipt.operationId] = receipt;
    return receipt;
  }

  final _fileStages = MemoryInformationFileStages();
  final _informationFileDeliveries = <String, InformationFileDelivery>{};
  @override
  List<InformationFileDelivery> get informationFileDeliveries =>
      List.unmodifiable(_informationFileDeliveries.values);
  @override
  Future<void> saveInformationFileDelivery(
    InformationFileDelivery value,
  ) async {
    _informationFileDeliveries[value.id] = value;
  }

  @override
  Future<void> pruneInformationFileDeliveryHistory(Set<String> ids) async {
    _informationFileDeliveries.removeWhere((id, _) => ids.contains(id));
  }

  final _informationFiles =
      <InformationAttachmentRef, (InformationAttachmentVersion, Uint8List?)>{};
  final _informationCommits = <String, InformationDraftReceipt>{};
  final _informationRecordReceipts = <String, InformationRecordReceipt>{};
  @override
  Future<void> commitAttachmentSeparation({
    required InformationItem source,
    required InformationRevision previous,
    required InformationItem file,
    required InformationRecordReceipt receipt,
    required void Function() validate,
  }) async {
    validate();
    if (_items[source.id]?.version != previous.item.version ||
        _items.containsKey(file.id)) {
      throw const AccessFailure('version_conflict');
    }
    if (_informationRecordReceipts.containsKey(receipt.operationId)) {
      throw const AccessFailure('operation_conflict');
    }
    _items[source.id] = source;
    _items[file.id] = file;
    _revisions.add(previous);
    _informationRecordReceipts[receipt.operationId] = receipt;
  }

  @override
  Future<InformationRecordReceipt?> informationRecordReceipt(
    String operationId,
  ) async => _informationRecordReceipts[operationId];
  @override
  Future<InformationFileStage> informationStage(
    String draftId,
    String stageId,
  ) async => _fileStages.stageMetadata(draftId, stageId);
  @override
  Future<List<InformationAttachmentVersion>> informationAttachmentVersions(
    String id,
  ) async => List.unmodifiable(
    _informationFiles.values
        .where((v) => v.$1.reference.attachmentId == id)
        .map((v) => v.$1),
  );
  @override
  Future<InformationAttachmentUsage> informationAttachmentUsage() async {
    final stages = await informationFileStagingUsage();
    final available = _informationFiles.values
        .where((v) => v.$1.available)
        .toList();
    return InformationAttachmentUsage(
      versionRecords: _informationFiles.length,
      availableVersions: available.length,
      storedBytes: available.fold(0, (sum, v) => sum + v.$1.byteLength),
      stagedFiles: stages.files,
      stagedBytes: stages.bytes,
    );
  }

  @override
  Future<Uint8List> readInformationAttachmentChunk(
    InformationAttachmentRef ref,
    int offset,
    int length,
  ) async => _readInformationFile(ref, offset, length);
  @override
  Future<T> withInformationAttachment<T>(
    InformationAttachmentRef ref,
    Future<T> Function(InformationAttachmentVersion, Stream<Uint8List>) action,
  ) => _withInformationFile(ref, action);
  @override
  Future<void> reconcileInformationAttachments(DateTime now) async =>
      _reconcileInformationFiles(now);
  @override
  Future<InformationDraftReceipt?> informationDraftReceipt(
    String draftId,
    String operationId,
  ) async {
    final key = jsonEncode([draftId, operationId]);
    if (_purgedInformationCommits.contains(key)) {
      throw const AccessFailure('information_purged');
    }
    return _informationCommits[key];
  }

  @override
  Future<InformationDraftReceipt> commitInformationDraft(
    InformationDraftChange change,
  ) async => _commitInformationDraft(change);
  @override
  Future<InformationFileStage> stageInformationBytes({
    required String draftId,
    required String stageId,
    required String originalName,
    required String mediaType,
    required Uint8List bytes,
  }) async {
    final pending = _importUploadData.values.where((v) => v.$2 != null);
    final own = await _fileStages.informationFileStagingUsage();
    InformationFileStage? previous;
    try {
      previous = await informationStage(draftId, stageId);
    } on AccessFailure {
      /* New stage. */
    }
    if (previous == null &&
        own.files + pending.length >= informationFileStageLimit) {
      throw const AccessFailure('attachment_capacity_exceeded');
    }
    return _fileStages.stageInformationBytes(
      draftId: draftId,
      stageId: stageId,
      originalName: originalName,
      mediaType: mediaType,
      bytes: bytes,
      retainedBytes:
          pending.fold(0, (n, v) => n + v.$1.byteLength) +
          _informationFiles.values.fold<int>(
            0,
            (sum, v) => sum + (v.$2?.length ?? 0),
          ),
    );
  }

  @override
  Future<InformationFileStagingUsage> informationFileStagingUsage() async {
    final own = await _fileStages.informationFileStagingUsage();
    final pending = _importUploadData.values.where((v) => v.$2 != null);
    return InformationFileStagingUsage(
      own.files + pending.length,
      own.bytes + pending.fold(0, (n, v) => n + v.$1.byteLength),
    );
  }

  @override
  Future<void> releaseInformationStage(String draftId, String stageId) =>
      _fileStages.releaseInformationStage(draftId, stageId);
  @override
  Future<void> releaseInformationDraft(String draftId) =>
      _fileStages.releaseInformationDraft(draftId);

  SshHostTrustSnapshot? _sshHostTrust;
  @override
  SshHostTrustSnapshot? get sshHostTrust => _sshHostTrust;
  @override
  Future<void> saveSshHostTrust(SshHostTrustSnapshot? snapshot) async {
    _sshHostTrust = snapshot;
  }

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
  }) async {
    validate?.call();
    _credentialUseRequests
      ..clear()
      ..addAll(requests);
    _focusedFillOperations
      ..clear()
      ..addAll(operations);
    if (executions != null) {
      _credentialExecutions
        ..clear()
        ..addAll(executions);
    }
  }

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
  }) async {
    validate?.call();
    _credentialUseRequests
      ..clear()
      ..addAll(requests);
    _credentialExecutions
      ..clear()
      ..addAll(executions);
    if (fieldGrant != null) _history[fieldGrant.id] = fieldGrant;
    if (fieldRequest != null) _requestHistory[fieldRequest.id] = fieldRequest;
  }

  final _credentials = <ManagedCredential>[];
  final _materials = <CredentialMaterial>[];
  @override
  List<ManagedCredential> get managedCredentials =>
      List.unmodifiable(_credentials);
  @override
  List<CredentialMaterial> get credentialMaterials =>
      List.unmodifiable(_materials);
  @override
  Future<void> commitCredentials(
    List<ManagedCredential> credentials,
    List<CredentialMaterial> materials,
  ) async {
    _credentials
      ..clear()
      ..addAll(credentials);
    _materials
      ..clear()
      ..addAll(materials);
  }

  MemoryInformationRepository([Iterable<InformationItem> items = const []]) {
    for (final item in items) {
      _items[item.id] = item;
    }
  }
  final _items = <String, InformationItem>{};
  final _organizationTasks = <String, OrganizationTask>{};
  @override
  List<OrganizationTask> get organizationTasks =>
      List.unmodifiable(_organizationTasks.values);
  @override
  Future<void> saveOrganizationTask(OrganizationTask task) async {
    _organizationTasks[task.id] = task;
  }

  @override
  Future<void> pruneOrganizationHistory(Set<String> ids) async {
    _organizationTasks.removeWhere((id, _) => ids.contains(id));
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
    validate?.call();
    for (final directory in newDirectories) {
      _directories[directory.id] = directory;
    }
    for (final tag in newTags) {
      _tags[tag.id] = tag;
    }
    for (final item in items) {
      _items[item.id] = item;
    }
    _revisions.addAll(previous);
    _organizationTasks[task.id] = task;
  }

  final _history = <String, GrantHistory>{};
  final _requestHistory = <String, RequestHistory>{};
  @override
  List<RequestHistory> get requestHistory =>
      List.unmodifiable(_requestHistory.values);
  @override
  Future<void> saveRequestHistory(RequestHistory history) async =>
      _requestHistory[history.id] = history;
  final _accesses = <String, AccessRecord>{};
  @override
  List<GrantHistory> get grantHistory => List.unmodifiable(_history.values);
  @override
  List<AccessRecord> get accessRecords => List.unmodifiable(_accesses.values);
  @override
  Future<void> saveGrantHistory(GrantHistory history) async =>
      _history[history.id] = history;
  @override
  Future<void> saveAccessRecord(AccessRecord record) async =>
      _accesses[record.id] = record;
  @override
  Future<void> pruneAudit(DateTime cutoff) async {
    _history.removeWhere((_, value) => value.approvedAt.isBefore(cutoff));
    _requestHistory.removeWhere((_, value) => value.createdAt.isBefore(cutoff));
    _accesses.removeWhere((_, value) => value.at.isBefore(cutoff));
  }

  final _settings = <String, int>{};
  final _recycle = <String, RecycleEntry>{};
  final _recycleFacts = <RecycleFact>[];
  final _deletes = <String, DeleteProposal>{};
  @override
  List<RecycleEntry> get recycleEntries => List.unmodifiable(_recycle.values);
  @override
  List<RecycleFact> get recycleFacts => List.unmodifiable(_recycleFacts);
  @override
  List<DeleteProposal> get deleteProposals =>
      List.unmodifiable(_deletes.values);
  @override
  Future<void> saveDeleteProposal(DeleteProposal proposal) async {
    _deletes[proposal.id] = proposal;
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
    validate?.call();
    if (lifecycleReceipt != null &&
        _lifecycleReceipts.containsKey(lifecycleReceipt.command.operationId)) {
      throw const AccessFailure('operation_conflict');
    }
    if (lifecycleReceipt != null) {
      final command = lifecycleReceipt.command;
      if (command.itemId != itemId) {
        throw const AccessFailure('invalid_information');
      }
      if (command.expectedCatalogVersion != null &&
          _classificationVersion() != command.expectedCatalogVersion) {
        throw const AccessFailure('organization_conflict');
      }
      final current = _items[itemId]?.version;
      if (command.action == InformationLifecycleAction.restoreRecycled) {
        final entry = _recycle[command.entryId];
        if (entry == null || entry.state != RecycleState.available) {
          throw const AccessFailure('recycle_unavailable');
        }
        if (entry.itemId != itemId ||
            entry.version != command.expectedVersion ||
            current != command.expectedCurrentVersion ||
            (entry.wholeItem && current != null) ||
            (!entry.wholeItem && current == null)) {
          throw const AccessFailure('recycle_conflict');
        }
      } else if (current != command.expectedVersion) {
        throw const AccessFailure('revision_conflict');
      }
    }
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
    if (lifecycleReceipt != null) {
      _lifecycleReceipts[lifecycleReceipt.command.operationId] =
          lifecycleReceipt;
    }
    _reconcileInformationFiles(
      (facts.lastOrNull?.at ??
              item?.modifiedAt ??
              previous?.replacedAt ??
              DateTime.now())
          .toUtc(),
    );
  }

  final _directories = <String, InformationDirectory>{};
  final _tags = <String, InformationTag>{};
  @override
  List<InformationDirectory> get directories =>
      List.unmodifiable(_directories.values);
  @override
  List<InformationTag> get tags => List.unmodifiable(_tags.values);
  @override
  Future<void> saveDirectory(InformationDirectory directory) async =>
      _directories[directory.id] = directory;
  @override
  Future<void> saveTag(InformationTag tag) async => _tags[tag.id] = tag;
  @override
  Future<void> commitOrganizationRemoval({
    String? directoryId,
    String? tagId,
    List<InformationItem> items = const [],
    List<InformationRevision> previous = const [],
    required void Function() validate,
  }) async {
    validate();
    if (directoryId != null) _directories.remove(directoryId);
    if (tagId != null) _tags.remove(tagId);
    for (final item in items) {
      _items[item.id] = item;
    }
    _revisions.addAll(previous);
  }

  final _templates = <String, InformationTemplate>{};
  final _proposals = <String, ImportProposal>{};
  final _updates = <String, UpdateProposal>{};
  final _revisions = <InformationRevision>[];
  final _revisionPurges = <RevisionPurgeFact>[];
  @override
  List<RevisionPurgeFact> get revisionPurgeFacts =>
      List.unmodifiable(_revisionPurges);
  @override
  Future<void> pruneInformationRevisions(
    DateTime cutoff,
    DateTime purgedAt,
  ) async {
    for (final revision in _revisions.where(
      (r) => !r.replacedAt.isAfter(cutoff),
    )) {
      _revisionPurges.add(
        RevisionPurgeFact(revision.item.id, revision.item.version, purgedAt),
      );
    }
    _revisions.removeWhere((r) => !r.replacedAt.isAfter(cutoff));
    _reconcileInformationFiles(purgedAt.toUtc());
  }

  @override
  List<UpdateProposal> get updateProposals =>
      List.unmodifiable(_updates.values);
  @override
  List<InformationRevision> get informationRevisions =>
      List.unmodifiable(_revisions);
  @override
  Future<void> saveUpdateProposal(UpdateProposal proposal) async {
    _claimFileChanges(proposal.sessionBinding, proposal.input.attachments);
    _updates[proposal.id] = proposal;
    _reconcileImportOriginals();
  }

  @override
  Future<void> saveInformationRevision(
    InformationItem item,
    InformationRevision previous,
  ) async {
    _items[item.id] = item;
    _revisions.add(previous);
    _reconcileInformationFiles(
      (item.modifiedAt ?? previous.replacedAt).toUtc(),
    );
  }

  @override
  List<ImportProposal> get importProposals =>
      List.unmodifiable(_proposals.values);
  @override
  Future<void> saveImportProposal(ImportProposal proposal) async {
    _claimImportOriginals(proposal);
    _proposals[proposal.id] = proposal;
    _reconcileImportOriginals();
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
    final importedFiles = await _prepareImportedOriginals(
      filePromotions,
      proposals,
      updates,
    );
    _informationFiles.addAll(importedFiles);
    _credentials.addAll(credentialRecords);
    _materials.addAll(credentialMaterials);
    for (final directory in newDirectories) {
      _directories[directory.id] = directory;
    }
    for (final tag in newTags) {
      _tags[tag.id] = tag;
    }
    for (final item in items) {
      _items[item.id] = item;
    }
    for (final proposal in proposals) {
      _proposals[proposal.id] = proposal;
    }
    for (final update in updates) {
      final item = update.item;
      if (item != null) _items[item.id] = item;
      if (update.previous case final previous?) _revisions.add(previous);
      for (final entry in update.recycled) {
        _recycle[entry.id] = entry;
      }
      _recycleFacts.addAll(update.facts);
      _updates[update.proposal.id] = update.proposal;
    }
    _reconcileImportOriginals();
    for (final update in updates) {
      if (update.item case final item?) {
        _reconcileInformationFiles(
          (item.modifiedAt ?? update.previous!.replacedAt).toUtc(),
        );
      }
    }
  }

  @override
  List<InformationTemplate> get templates =>
      List.unmodifiable(_templates.values);
  @override
  Future<void> saveTemplate(InformationTemplate template) async {
    _templates[template.id] = template;
  }

  @override
  Future<void> deleteTemplate(String id) async {
    _templates.remove(id);
  }

  @override
  List<InformationItem> get items => List.unmodifiable(_items.values);
  @override
  Future<void> save(InformationItem item) async {
    _items[item.id] = item;
    _reconcileInformationFiles((item.modifiedAt ?? DateTime.now()).toUtc());
  }

  @override
  int? readSetting(String key) => _settings[key];
  @override
  Future<void> writeSetting(String key, int value) async {
    _settings[key] = value;
  }
}
