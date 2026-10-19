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
import 'information_files.dart';
import 'info_core.dart'
    show
        AccessFailure,
        CredentialRuntimeRepository,
        CredentialUseRequest,
        CredentialExecution,
        FocusedFillRuntimeRepository,
        FocusedFillOperation,
        SshHostTrustRepository,
        SshHostTrustSnapshot;

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
  int? readSetting(String key);
  Future<void> writeSetting(String key, int value);
  List<InformationTemplate> get templates;
  Future<void> saveTemplate(InformationTemplate template);
  Future<void> deleteTemplate(String id);
  List<ImportProposal> get importProposals;
  Future<void> saveImportProposal(ImportProposal proposal);

  /// Commits the entire batch and its terminal proposal state atomically.
  Future<void> confirmImportProposal(
    ImportProposal proposal,
    List<InformationItem> items, {
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
  Future<void> confirmUpdateProposal(
    UpdateProposal proposal,
    InformationItem item,
    InformationRevision previous, {
    List<RecycleEntry> recycled = const [],
    List<RecycleFact> facts = const [],
  });
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
  });
}

class MemoryInformationRepository
    implements
        InformationRepository,
        CredentialRepository,
        CredentialRuntimeRepository,
        FocusedFillRuntimeRepository,
        InformationFileStagingRepository,
        SshHostTrustRepository {
  final _fileStages = MemoryInformationFileStages();
  @override
  Future<InformationFileStage> stageInformationBytes({
    required String draftId,
    required String stageId,
    required String originalName,
    required String mediaType,
    required Uint8List bytes,
  }) => _fileStages.stageInformationBytes(
    draftId: draftId,
    stageId: stageId,
    originalName: originalName,
    mediaType: mediaType,
    bytes: bytes,
  );
  @override
  Future<InformationFileStagingUsage> informationFileStagingUsage() =>
      _fileStages.informationFileStagingUsage();
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
  }) async {
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
  }

  @override
  List<UpdateProposal> get updateProposals =>
      List.unmodifiable(_updates.values);
  @override
  List<InformationRevision> get informationRevisions =>
      List.unmodifiable(_revisions);
  @override
  Future<void> saveUpdateProposal(UpdateProposal proposal) async {
    _updates[proposal.id] = proposal;
  }

  @override
  Future<void> saveInformationRevision(
    InformationItem item,
    InformationRevision previous,
  ) async {
    _items[item.id] = item;
    _revisions.add(previous);
  }

  @override
  Future<void> confirmUpdateProposal(
    UpdateProposal proposal,
    InformationItem item,
    InformationRevision previous, {
    List<RecycleEntry> recycled = const [],
    List<RecycleFact> facts = const [],
  }) async {
    _items[item.id] = item;
    _revisions.add(previous);
    _updates[proposal.id] = proposal;
    for (final entry in recycled) {
      _recycle[entry.id] = entry;
    }
    _recycleFacts.addAll(facts);
  }

  @override
  List<ImportProposal> get importProposals =>
      List.unmodifiable(_proposals.values);
  @override
  Future<void> saveImportProposal(ImportProposal proposal) async {
    _proposals[proposal.id] = proposal;
  }

  @override
  Future<void> confirmImportProposal(
    ImportProposal proposal,
    List<InformationItem> items, {
    List<InformationDirectory> newDirectories = const [],
    List<InformationTag> newTags = const [],
  }) async {
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
  }

  @override
  int? readSetting(String key) => _settings[key];
  @override
  Future<void> writeSetting(String key, int value) async {
    _settings[key] = value;
  }
}
