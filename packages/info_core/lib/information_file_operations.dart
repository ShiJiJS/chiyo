part of 'info_core.dart';

/// Owner command identity; contains no path, bytes or field values.
final class InformationFileCommand {
  InformationFileCommand({
    required this.action,
    required this.digest,
    this.fieldId,
    this.expected,
  }) {
    if (!{'import', 'replace', 'restore'}.contains(action) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        (action == 'import'
            ? fieldId != null || expected != null
            : fieldId == null || fieldId!.isEmpty || expected == null)) {
      throw const FormatException('Invalid file command');
    }
  }
  final String action, digest;
  final String? fieldId;
  final InformationAttachmentRef? expected;
  Map<String, Object?> toJson() => {
    'action': action,
    'digest': digest,
    'fieldId': fieldId,
    'expected': expected?.toJson(),
  };
  factory InformationFileCommand.fromJson(Map<String, dynamic> value) {
    if (value.length != 4) throw const FormatException('Invalid file command');
    return InformationFileCommand(
      action: value['action'] as String,
      digest: value['digest'] as String,
      fieldId: value['fieldId'] as String?,
      expected: value['expected'] == null
          ? null
          : InformationAttachmentRef.fromJson(
              value['expected'] as Map<String, dynamic>,
            ),
    );
  }
}

final class InformationFileReceipt {
  InformationFileReceipt(this.command, this.fieldId, this.reference) {
    if (fieldId.isEmpty ||
        fieldId.length > 200 ||
        fieldId.codeUnits.any((c) => c < 33) ||
        command.fieldId != null && command.fieldId != fieldId ||
        command.expected != null &&
            (reference.attachmentId != command.expected!.attachmentId ||
                reference.attachmentVersion <=
                    command.expected!.attachmentVersion)) {
      throw const FormatException('Invalid file receipt');
    }
  }
  final InformationFileCommand command;
  final String fieldId;
  final InformationAttachmentRef reference;
  Map<String, Object?> toJson() => {
    'command': command.toJson(),
    'fieldId': fieldId,
    'reference': reference.toJson(),
  };
  factory InformationFileReceipt.fromJson(Map<String, dynamic> value) {
    if (value.length != 3) throw const FormatException('Invalid file receipt');
    return InformationFileReceipt(
      InformationFileCommand.fromJson(value['command'] as Map<String, dynamic>),
      value['fieldId'] as String,
      InformationAttachmentRef.fromJson(
        value['reference'] as Map<String, dynamic>,
      ),
    );
  }
}

InformationFileReceipt? _fileReceipt(
  InformationDraftInput input,
  InformationItem item,
) {
  final command = input.fileCommand;
  if (command == null) return null;
  final index = input.fields.indexWhere((f) => f.stageId != null);
  final field = item.fields[index];
  return InformationFileReceipt(command, field.id, field.attachment!);
}

extension OwnerInformationFileRecords on OwnerAccess {
  Future<InformationRecordReceipt> saveInformationFileRecord(
    InformationFileDraft draft,
    String operationId,
    InformationDraftInput input,
  ) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    _validateRecordOperationId(operationId);
    if (input.fileCommand == null) {
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
      if (old.inputHash != hash || old.file == null) {
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

  /// Restore copies an authenticated retained original into encrypted staging;
  /// committing it creates a NEW version, never rewinds the old identity.
  Future<InformationFileStage> stageRetainedInformationFile(
    InformationFileDraft draft,
    InformationAttachmentRef ref,
  ) => _serialize(() async {
    _checkInformationFileDraft(draft);
    final original = await _readInformationAttachment(ref);
    _checkInformationFileDraft(draft);
    final stage = await _fileStages.stageInformationBytes(
      draftId: draft.id,
      stageId: _service._secret(),
      originalName: original.version.originalName,
      mediaType: original.version.mediaType,
      bytes: original.bytes,
    );
    _checkInformationFileDraft(draft);
    return stage;
  });
}
