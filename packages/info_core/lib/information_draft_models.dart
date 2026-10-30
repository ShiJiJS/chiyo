part of 'info_core.dart';

/// Complete owner form content. A file is either an unchanged version reference
/// or a stage owned by this form, never a source/delivery path or Base64 string.
final class InformationDraftField {
  const InformationDraftField.text(
    this.name,
    this.description,
    this.text, {
    this.fieldId,
    this.kind = FieldKind.structured,
    this.replaceIdentity = false,
  }) : stageId = null,
       attachment = null;
  const InformationDraftField.stagedFile(
    this.name,
    this.description,
    this.stageId, {
    this.fieldId,
    this.replaceIdentity = false,
  }) : kind = FieldKind.file,
       text = null,
       attachment = null;
  const InformationDraftField.retainedFile(
    this.name,
    this.description,
    this.attachment, {
    required this.fieldId,
    this.replaceIdentity = false,
  }) : kind = FieldKind.file,
       text = null,
       stageId = null;
  final String name, description;
  final String? fieldId, text, stageId;
  final InformationAttachmentRef? attachment;
  final FieldKind kind;
  final bool replaceIdentity;
  Map<String, Object?> toPrivateJson() => {
    'fieldId': fieldId,
    'name': name,
    'description': description,
    'kind': kind.name,
    'replaceIdentity': replaceIdentity,
    if (kind != FieldKind.file) 'text': text,
    if (stageId != null) 'stageId': stageId,
    if (attachment != null) 'attachment': attachment!.toJson(),
  };
}

final class InformationDraftInput {
  InformationDraftInput({
    required this.name,
    required this.description,
    required Iterable<InformationDraftField> fields,
    this.itemId,
    this.baseVersion,
    this.directoryId,
    this.layout,
    this.command,
    Iterable<String> tagIds = const [],
  }) : fields = List.unmodifiable(fields),
       tagIds = List.unmodifiable(tagIds);
  final String name, description;
  final InformationDraftLayout? layout;
  final InformationRecordCommand? command;
  final String? itemId, directoryId;
  final int? baseVersion;
  final List<InformationDraftField> fields;
  final List<String> tagIds;
  Map<String, Object?> toPrivateJson() => {
    'itemId': itemId,
    'baseVersion': baseVersion,
    'name': name,
    'description': description,
    'directoryId': directoryId,
    'tagIds': (tagIds.toSet().toList()..sort()),
    'fields': [for (final f in fields) f.toPrivateJson()],
    if (layout != null) 'layout': layout!.toJson(),
    if (command != null) 'command': command!.toJson(),
  };
}

final class InformationAttachmentPromotion {
  const InformationAttachmentPromotion(this.stageId, this.version);
  final String stageId;
  final InformationAttachmentVersion version;
}

final class InformationDraftReceipt {
  const InformationDraftReceipt(this.inputHash, this.item);
  final String inputHash;
  final InformationItem item;
  Map<String, Object?> toPrivateJson() => {
    'inputHash': inputHash,
    'item': informationToJson(item),
  };
  factory InformationDraftReceipt.fromPrivateJson(Map<String, dynamic> json) {
    if (json.length != 2 ||
        json['inputHash'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(json['inputHash'] as String) ||
        json['item'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid owner draft receipt');
    }
    return InformationDraftReceipt(
      json['inputHash'] as String,
      informationFromJson(json['item'] as Map<String, dynamic>),
    );
  }
}

/// The trusted repository must atomically promote stages, save the whole item,
/// revision/recycle facts and the idempotency receipt. Failure retains stages.
final class InformationDraftChange {
  InformationDraftChange({
    required this.draftId,
    required this.operationId,
    required this.receipt,
    required this.promotions,
    this.previous,
    required this.entries,
    required this.facts,
    required this.validate,
    this.operationReceipt,
  });
  final String draftId, operationId;
  final InformationDraftReceipt receipt;
  final List<InformationAttachmentPromotion> promotions;
  final InformationRevision? previous;
  final List<RecycleEntry> entries;
  final List<RecycleFact> facts;
  final void Function() validate;
  final InformationRecordReceipt? operationReceipt;
}

abstract interface class InformationAttachmentRepository
    implements InformationFileStagingRepository {
  Future<InformationAttachmentUsage> informationAttachmentUsage();
  Future<InformationFileStage> informationStage(String draftId, String stageId);
  Future<List<InformationAttachmentVersion>> informationAttachmentVersions(
    String attachmentId,
  );
  Future<Uint8List> readInformationAttachmentChunk(
    InformationAttachmentRef ref,
    int offset,
    int length,
  );

  /// The callback's complete read shares one fixed original. No body is
  /// attached to ordinary information snapshots or returned before approval.
  Future<T> withInformationAttachment<T>(
    InformationAttachmentRef ref,
    Future<T> Function(
      InformationAttachmentVersion version,
      Stream<Uint8List> chunks,
    )
    action,
  );
  Future<void> reconcileInformationAttachments(DateTime now);
  Future<InformationDraftReceipt?> informationDraftReceipt(
    String draftId,
    String operationId,
  );
  Future<InformationDraftReceipt> commitInformationDraft(
    InformationDraftChange change,
  );
}

/// Slot keys are paired with the submitted field order, then bound to identities
/// allocated by the core. UI keys never become authorization field identities.
final class InformationDraftLayout {
  InformationDraftLayout(this.layout, Iterable<String?> fieldKeys)
    : fieldKeys = List.unmodifiable(fieldKeys) {
    final keys = this.fieldKeys.whereType<String>().toList();
    if (this.fieldKeys.length > 200 ||
        keys.toSet().length != keys.length ||
        keys.any((k) => k.trim().isEmpty || k.length > 512)) {
      throw const FormatException('Invalid draft layout');
    }
  }
  final InformationLayout layout;
  final List<String?> fieldKeys;
  Map<String, Object?> toJson() => {
    'layout': layout.toJson(),
    'fieldKeys': fieldKeys,
  };
  InformationLayout bind(List<InformationField> fields) {
    if (fields.length != fieldKeys.length) {
      throw const AccessFailure('invalid_information');
    }
    return layout.withFieldIds({
      ...layout.fieldIds,
      for (var i = 0; i < fields.length; i++)
        if (fieldKeys[i] != null) fieldKeys[i]!: fields[i].id,
    });
  }
}
