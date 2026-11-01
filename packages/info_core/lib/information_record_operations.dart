part of 'info_core.dart';

/// Original owner command identity, independent of later edits or deletion.
/// Only a type identifier and a digest are retained, never form content.
final class InformationRecordCommand {
  InformationRecordCommand({required this.typeId, required this.digest}) {
    if (typeId.trim().isEmpty ||
        typeId.length > 512 ||
        typeId.codeUnits.any((c) => c < 32) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('Invalid information record command');
    }
  }
  final String typeId, digest;
  Map<String, Object?> toJson() => {'typeId': typeId, 'digest': digest};
  factory InformationRecordCommand.fromJson(Map<String, dynamic> json) {
    if (json.length != 2 ||
        json['typeId'] is! String ||
        json['digest'] is! String) {
      throw const FormatException('Invalid information record command');
    }
    return InformationRecordCommand(
      typeId: json['typeId'] as String,
      digest: json['digest'] as String,
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

extension OwnerInformationRecords on OwnerAccess {
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

  /// A stable operation ID survives the UI/form/process lifetime. This entry
  /// handles text and unchanged attachments; new file bytes use staged forms.
  Future<InformationRecordReceipt> saveInformationRecord(
    String operationId,
    InformationDraftInput input,
  ) => _serialize(() async {
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
