part of 'info_core.dart';

/// Original owner command identity, independent of later edits or deletion.
/// Only a type identifier and a digest are retained, never form content.
final class InformationRecordCommand {
  InformationRecordCommand({
    required this.typeId,
    required this.digest,
    this.legacyTemplateId,
    this.legacyTemplateVersion,
    this.adoptionPlanId,
    this.templateCatalogVersion,
  }) {
    bool validId(String? s) =>
        s == null ||
        (s.isNotEmpty && s.length <= 512 && !s.codeUnits.any((c) => c < 32));
    if (!validId(typeId) ||
        typeId.isEmpty ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        !validId(legacyTemplateId) ||
        !validId(adoptionPlanId) ||
        (legacyTemplateId == null) != (legacyTemplateVersion == null) ||
        (adoptionPlanId == null) != (templateCatalogVersion == null) ||
        (legacyTemplateVersion != null && legacyTemplateVersion! < 1) ||
        (templateCatalogVersion != null && templateCatalogVersion! < 1) ||
        legacyTemplateId != null && adoptionPlanId != null) {
      throw const FormatException('Invalid information record command');
    }
  }
  final String typeId, digest;
  final String? legacyTemplateId, adoptionPlanId;
  final int? legacyTemplateVersion, templateCatalogVersion;
  Map<String, Object?> toJson() => {
    'typeId': typeId,
    'digest': digest,
    if (legacyTemplateId != null) ...{
      'legacyTemplateId': legacyTemplateId,
      'legacyTemplateVersion': legacyTemplateVersion,
    },
    if (adoptionPlanId != null) ...{
      'adoptionPlanId': adoptionPlanId,
      'templateCatalogVersion': templateCatalogVersion,
    },
  };
  factory InformationRecordCommand.fromJson(Map<String, dynamic> json) {
    if (json.keys.toSet().difference({
          'typeId',
          'digest',
          'legacyTemplateId',
          'legacyTemplateVersion',
          'adoptionPlanId',
          'templateCatalogVersion',
        }).isNotEmpty ||
        json['typeId'] is! String ||
        json['digest'] is! String) {
      throw const FormatException('Invalid information record command');
    }
    return InformationRecordCommand(
      typeId: json['typeId'] as String,
      digest: json['digest'] as String,
      legacyTemplateId: json['legacyTemplateId'] as String?,
      legacyTemplateVersion: json['legacyTemplateVersion'] as int?,
      adoptionPlanId: json['adoptionPlanId'] as String?,
      templateCatalogVersion: json['templateCatalogVersion'] as int?,
    );
  }
}

/// Owner-only proof of a committed save. Contains neither field values nor a
/// retained item snapshot, so purging content does not leave a second copy here.
final class InformationRecordReceipt {
  const InformationRecordReceipt({
    required this.operationId,
    required this.inputHash,
    required this.itemId,
    required this.version,
    required this.baseVersion,
    this.command,
    this.file,
  });
  final String operationId, inputHash, itemId;
  final int version;
  final int? baseVersion;
  final InformationRecordCommand? command;
  final InformationFileReceipt? file;
  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'inputHash': inputHash,
    'itemId': itemId,
    'version': version,
    'baseVersion': baseVersion,
    if (command != null) 'command': command!.toJson(),
    if (file != null) 'file': file!.toJson(),
  };

  factory InformationRecordReceipt.fromJson(Map<String, dynamic> json) {
    if (json.length !=
            5 +
                (json.containsKey('command') ? 1 : 0) +
                (json.containsKey('file') ? 1 : 0) ||
        (json.containsKey('command') &&
            json['command'] is! Map<String, dynamic>) ||
        json['operationId'] is! String ||
        json['itemId'] is! String ||
        (json['itemId'] as String).isEmpty ||
        (json['itemId'] as String).length > 200 ||
        (json['operationId'] as String).isEmpty ||
        (json['operationId'] as String).length > 200 ||
        (json['operationId'] as String).codeUnits.any(
          (c) => c < 33 || c > 126,
        ) ||
        json['inputHash'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(json['inputHash'] as String) ||
        json['version'] is! int ||
        (json['version'] as int) < 1 ||
        (json['baseVersion'] != null &&
            (json['baseVersion'] is! int ||
                (json['baseVersion'] as int) < 1)) ||
        json['version'] != (json['baseVersion'] as int? ?? 0) + 1) {
      throw const FormatException('Invalid information operation receipt');
    }
    return InformationRecordReceipt(
      operationId: json['operationId'] as String,
      inputHash: json['inputHash'] as String,
      itemId: json['itemId'] as String,
      version: json['version'] as int,
      baseVersion: json['baseVersion'] as int?,
      file: json.containsKey('file')
          ? InformationFileReceipt.fromJson(
              json['file'] as Map<String, dynamic>,
            )
          : null,
      command: json.containsKey('command')
          ? InformationRecordCommand.fromJson(
              json['command'] as Map<String, dynamic>,
            )
          : null,
    );
  }
}

/// Implementations commit this receipt in the same transaction as the draft.
abstract interface class InformationRecordOperationRepository {
  Future<InformationRecordReceipt?> informationRecordReceipt(
    String operationId,
  );
}

/// Moving an existing original does not copy bytes or lose its version series.
/// Both records, history and the retry receipt must commit together.
abstract interface class InformationAttachmentSeparationRepository {
  Future<void> commitAttachmentSeparation({
    required InformationItem source,
    required InformationRevision previous,
    required InformationItem file,
    required InformationRecordReceipt receipt,
    required void Function() validate,
  });
}

extension OwnerInformationRecords on OwnerAccess {
  Future<InformationRecordReceipt> separateInformationAttachment({
    required String operationId,
    required String itemId,
    required int expectedVersion,
    required String fieldId,
    required String name,
    required String templateId,
  }) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    final generation = _service._libraryGeneration;
    _validateRecordOperationId(operationId);
    _checkOrganizationName(name);
    final hash = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'separate-attachment',
              itemId,
              expectedVersion,
              fieldId,
              name,
              templateId,
            ]),
          ),
        )
        .toString();
    final old = await _recordOperations.informationRecordReceipt(operationId);
    if (old != null) {
      if (old.inputHash != hash) {
        throw const AccessFailure('operation_conflict');
      }
      return old;
    }
    if (await _lifecycleOperations.informationLifecycleReceipt(operationId) !=
        null) {
      throw const AccessFailure('operation_conflict');
    }
    final repository = _service._repository;
    if (repository is! InformationAttachmentSeparationRepository) {
      throw const AccessFailure('unsupported_capability');
    }
    final before = information.where((i) => i.id == itemId).firstOrNull;
    if (before == null || before.version != expectedVersion) {
      throw const AccessFailure('version_conflict');
    }
    final field = before.fields.where((f) => f.id == fieldId).firstOrNull;
    if (field == null ||
        field.kind != FieldKind.file ||
        before.fields.length < 2) {
      throw const AccessFailure('invalid_information');
    }
    for (final f
        in (before.layout?.snapshot['definition'] as Map?)?['fields']
                as List? ??
            []) {
      if (before.layout?.fieldIds[jsonEncode(['field', (f as Map)['key']])] ==
          fieldId) {
        throw const AccessFailure('invalid_information');
      }
    }
    final template = _service.agent
        ._currentInformationTemplates()
        .templates
        .where(
          (t) =>
              t.id == templateId && t.enabled && t.recordKind == 'information',
        )
        .firstOrNull;
    final descriptors = (template?.definition['fields'] as List? ?? [])
        .cast<Map>();
    final files = descriptors.where((f) => f['type'] == 'file').toList();
    if (template == null ||
        !template.hasGuidance ||
        files.length != 1 ||
        descriptors.length != 1) {
      throw const AccessFailure('template_unavailable');
    }
    final versions = await _attachments.informationAttachmentVersions(
      field.attachment!.attachmentId,
    );
    if (!versions.any((v) => v.reference == field.attachment && v.available)) {
      throw const AccessFailure('attachment_missing');
    }
    final now = _service._clock().toUtc(), id = _service._secret();
    final newField = InformationField.file(
      _service._secret(),
      field.name,
      field.description,
      field.attachment!,
      1,
    );
    final fileKey = files.single['key'] as String;
    final related = (template.definition['relations'] as List? ?? [])
        .cast<Map>()
        .where((r) => r['key'] == 'related')
        .firstOrNull;
    final allowed = related?['targetTemplates'] as List?;
    if (related == null ||
        allowed != null &&
            allowed.isNotEmpty &&
            !allowed.contains(before.layout?.typeId ?? 'generic')) {
      throw const AccessFailure('template_unavailable');
    }
    final file = InformationItem(
      id,
      name.trim(),
      field.description,
      1,
      [newField],
      directoryId: before.directoryId,
      tagIds: before.tagIds,
      createdAt: now,
      modifiedAt: now,
      layout: InformationLayout(
        typeId: template.id,
        snapshot: {
          'codec': 'workspace-information-v1',
          'type': {
            'name': template.name,
            'icon': template.definition['icon'] ?? 'file',
          },
          'definition': template.definition,
          'retainedFields': <Object?>[],
          'retainedRelations': <Object?>[],
          'fieldOverrides': <String, Object?>{},
          'entries': <String, Object?>{},
        },
        fieldIds: {
          jsonEncode(['field', fileKey]): newField.id,
        },
        relations: {
          'related': [InformationRelationRef('information', before.id)],
        },
      ),
    );
    final removedKeys =
        before.layout?.fieldIds.entries
            .where((e) => e.value == fieldId)
            .map((e) => e.key)
            .toSet() ??
        <String>{};
    for (final key in removedKeys.toList()) {
      try {
        final slot = jsonDecode(key);
        if (slot is List && slot.length == 2 && slot.first == 'field') {
          removedKeys.add(slot.last as String);
        }
      } on FormatException {
        /* Legacy keys can be plain identities. */
      }
    }
    final source = InformationItem(
      before.id,
      before.name,
      before.description,
      before.version + 1,
      before.fields.where((f) => f.id != fieldId).toList(),
      directoryId: before.directoryId,
      tagIds: before.tagIds,
      createdAt: before.createdAt,
      modifiedAt: now,
      layout: before.layout == null
          ? null
          : InformationLayout(
              typeId: before.layout!.typeId,
              snapshot: {
                ...before.layout!.snapshot,
                'fieldOverrides': <String, Object?>{
                  for (final e
                      in (before.layout!.snapshot['fieldOverrides'] as Map? ??
                              {})
                          .entries)
                    if (!removedKeys.contains(e.key)) e.key as String: e.value,
                },
                'retainedFields': [
                  for (final f
                      in before.layout!.snapshot['retainedFields'] as List? ??
                          [])
                    if (!removedKeys.contains((f as Map)['key'])) f,
                ],
              },
              fieldIds: {
                for (final e in before.layout!.fieldIds.entries)
                  if (e.value != fieldId) e.key: e.value,
              },
              relations: before.layout!.relations,
            ),
    );
    final receipt = InformationRecordReceipt(
      operationId: operationId,
      inputHash: hash,
      itemId: id,
      version: 1,
      baseVersion: null,
      command: InformationRecordCommand(typeId: templateId, digest: hash),
    );
    void validate() {
      if (!serviceAvailable || generation != _service._libraryGeneration) {
        throw const AccessFailure('library_changed');
      }
      if (information.where((i) => i.id == itemId).firstOrNull?.version !=
          expectedVersion) {
        throw const AccessFailure('version_conflict');
      }
    }

    await (repository as InformationAttachmentSeparationRepository)
        .commitAttachmentSeparation(
          source: source,
          previous: InformationRevision(before, now),
          file: file,
          receipt: receipt,
          validate: validate,
        );
    _invalidateRemoved(before, source);
    return receipt;
  });

  InformationRecordOperationRepository get _recordOperations {
    if (_service._repository
        case final InformationRecordOperationRepository repository) {
      return repository;
    }
    throw const AccessFailure('unsupported_capability');
  }

  /// null means no committed operation in this library. Storage failures and
  /// operations invalidated by restore must not be converted to null.
  Future<InformationRecordReceipt?> informationRecordReceipt(
    String operationId,
  ) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    _validateRecordOperationId(operationId);
    return _recordOperations.informationRecordReceipt(operationId);
  });

  /// Complete Owner form with ordinary attachments already staged in this
  /// form lifetime. Content, promotions and original intent share one commit.
  Future<InformationRecordReceipt> saveInformationFormRecord(
    InformationFileDraft draft,
    String operationId,
    InformationDraftInput input,
  ) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    _validateRecordOperationId(operationId);
    if (input.command == null || input.fileCommand != null) {
      throw const AccessFailure('invalid_information');
    }
    if (!identical(draft._owner, this) ||
        draft._generation != _service._libraryGeneration) {
      throw const AccessFailure('stage_unavailable');
    }
    final hash = sha256
        .convert(utf8.encode(jsonEncode(input.toPrivateJson())))
        .toString();
    final old = await _recordOperations.informationRecordReceipt(operationId);
    if (await _lifecycleOperations.informationLifecycleReceipt(operationId) !=
        null) {
      throw const AccessFailure('operation_conflict');
    }
    if (old != null) {
      if (old.inputHash != hash || old.command == null) {
        throw const AccessFailure('operation_conflict');
      }
      return old;
    }
    final item = await _commitInformationDraft(
      draft,
      operationId,
      input,
      durableReceipt: true,
    );
    return InformationRecordReceipt(
      operationId: operationId,
      inputHash: hash,
      itemId: item.id,
      version: item.version,
      baseVersion: input.baseVersion,
      command: input.command,
      file: _fileReceipt(input, item),
    );
  });

  /// A stable operation ID survives the UI/form/process lifetime. This entry
  /// handles text and unchanged attachments; new file bytes use staged forms.
  Future<InformationRecordReceipt> saveInformationRecord(
    String operationId,
    InformationDraftInput input, {
    void Function()? validate,
  }) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    _validateRecordOperationId(operationId);
    final generation = _service._libraryGeneration;
    if (input.name.length > 200 ||
        input.description.length > 2000 ||
        (input.itemId == null && input.fields.isEmpty) ||
        input.fields.length > 200 ||
        input.tagIds.length > 100 ||
        input.tagIds.toSet().length != input.tagIds.length ||
        input.fields.any(
          (f) =>
              f.name.length > 200 ||
              f.description.length > 2000 ||
              (f.text?.length ?? 0) > 1000000,
        )) {
      throw const AccessFailure('invalid_information');
    }
    if (input.fileCommand != null ||
        input.fields.any((f) => f.stageId != null)) {
      throw const AccessFailure('stage_unavailable');
    }
    final hash = sha256
        .convert(utf8.encode(jsonEncode(input.toPrivateJson())))
        .toString();
    final old = await _recordOperations.informationRecordReceipt(operationId);
    if (generation != _service._libraryGeneration) {
      throw const AccessFailure('library_changed');
    }
    if (old != null) {
      if (old.inputHash != hash) {
        throw const AccessFailure('operation_conflict');
      }
      return old;
    }
    // No file stages are created, and this handle cannot outlive this write.
    final draft = InformationFileDraft._(
      this,
      _service._libraryGeneration,
      _service._secret(),
    );
    _informationFileDrafts[draft.id] = draft;
    try {
      final item = await _commitInformationDraft(
        draft,
        operationId,
        input,
        durableReceipt: true,
        validateOwner: validate,
      );
      return InformationRecordReceipt(
        operationId: operationId,
        inputHash: hash,
        itemId: item.id,
        version: item.version,
        baseVersion: input.baseVersion,
        command: input.command,
      );
    } finally {
      draft._active = false;
      _informationFileDrafts.remove(draft.id);
    }
  });
}

void _validateRecordOperationId(String value) {
  if (value.isEmpty ||
      value.length > 200 ||
      value.codeUnits.any((c) => c < 33 || c > 126)) {
    throw const AccessFailure('invalid_information');
  }
}
