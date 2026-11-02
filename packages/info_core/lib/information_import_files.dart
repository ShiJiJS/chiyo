import 'dart:typed_data';
import 'information_files.dart';

bool _identity(String value) =>
    value.isNotEmpty &&
    value.length <= 200 &&
    value.codeUnits.every((c) => c >= 33 && c <= 126);

String ordinaryImportMediaType(String path) => switch (path
    .split(RegExp(r'[/\\]'))
    .last
    .split('.')
    .last
    .toLowerCase()) {
  'pdf' => 'application/pdf',
  'docx' =>
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'doc' => 'application/msword',
  'txt' || 'md' => 'text/plain',
  'png' => 'image/png',
  'webp' => 'image/webp',
  'jpg' || 'jpeg' => 'image/jpeg',
  _ => 'application/octet-stream',
};

/// A private, unapproved ordinary original. Never a formal attachment, grant,
/// filesystem path or response carrying the original bytes.
final class InformationImportUpload {
  InformationImportUpload({
    required this.id,
    required this.sessionBinding,
    required this.operationId,
    required this.originalName,
    required this.mediaType,
    required this.byteLength,
    required this.sha256,
    required this.createdAt,
    this.consumed = false,
  }) {
    if (!_identity(id) ||
        !_identity(sessionBinding) ||
        !_identity(operationId) ||
        originalName.isEmpty ||
        originalName.length > 1024 ||
        {'.', '..'}.contains(originalName) ||
        originalName.contains(RegExp(r'[/\\\x00-\x1f\x7f]')) ||
        mediaType.length > 200 ||
        !RegExp(
          r'^[a-z0-9!#$&^_.+\-]+/[a-z0-9!#$&^_.+\-]+$',
        ).hasMatch(mediaType) ||
        byteLength < 0 ||
        byteLength > informationFileByteLimit ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        !createdAt.isUtc ||
        createdAt.year < 1970 ||
        createdAt.year > 9999) {
      throw const FormatException('Invalid ordinary file upload');
    }
  }
  final String id, sessionBinding, operationId, originalName, mediaType, sha256;
  final int byteLength;
  final DateTime createdAt;
  final bool consumed;
  InformationImportUpload asConsumed() => InformationImportUpload(
    id: id,
    sessionBinding: sessionBinding,
    operationId: operationId,
    originalName: originalName,
    mediaType: mediaType,
    byteLength: byteLength,
    sha256: sha256,
    createdAt: createdAt,
    consumed: true,
  );
  Map<String, Object?> get metadata => {
    'uploadId': id,
    'originalName': originalName,
    'mediaType': mediaType,
    'byteLength': byteLength,
    'sha256': sha256,
    'consumed': consumed,
  };
  Map<String, Object?> toPrivateJson() => {
    ...metadata,
    'sessionBinding': sessionBinding,
    'operationId': operationId,
    'createdAt': createdAt.toIso8601String(),
  };
  factory InformationImportUpload.fromPrivateJson(Map<String, dynamic> json) {
    if (json.length != 9) {
      throw const FormatException('Invalid ordinary file upload');
    }
    return InformationImportUpload(
      id: json['uploadId'] as String,
      sessionBinding: json['sessionBinding'] as String,
      operationId: json['operationId'] as String,
      originalName: json['originalName'] as String,
      mediaType: json['mediaType'] as String,
      byteLength: json['byteLength'] as int,
      sha256: json['sha256'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      consumed: json['consumed'] as bool,
    );
  }
}

final class ImportAttachmentVersionInput {
  ImportAttachmentVersionInput(
    this.uploadId, {
    this.label = '',
    this.sourceNote = '',
    this.upload,
  }) {
    if (!_identity(uploadId) ||
        label.length > 200 ||
        sourceNote.length > 2000 ||
        upload != null && upload!.id != uploadId) {
      throw const FormatException('Invalid proposed file version');
    }
  }
  final String uploadId, label, sourceNote;
  final InformationImportUpload? upload;
  ImportAttachmentVersionInput resolved(InformationImportUpload value) =>
      ImportAttachmentVersionInput(
        uploadId,
        label: label,
        sourceNote: sourceNote,
        upload: value,
      );
  Map<String, Object?> get submissionJson => {
    'uploadId': uploadId,
    'label': label,
    'sourceNote': sourceNote,
  };
  Map<String, Object?> toPrivateJson() => {
    ...submissionJson,
    if (upload != null) 'upload': upload!.toPrivateJson(),
  };
  factory ImportAttachmentVersionInput.fromJson(
    Map<String, dynamic> json, {
    bool private = false,
  }) {
    if (json.keys.any(
      (k) => !{
        'uploadId',
        'label',
        'sourceNote',
        if (private) 'upload',
      }.contains(k),
    )) {
      throw const FormatException('Invalid proposed file version');
    }
    return ImportAttachmentVersionInput(
      json['uploadId'] as String,
      label: json['label'] as String? ?? '',
      sourceNote: json['sourceNote'] as String? ?? '',
      upload: private && json['upload'] != null
          ? InformationImportUpload.fromPrivateJson(
              Map<String, dynamic>.from(json['upload'] as Map),
            )
          : null,
    );
  }
}

/// One independent attachment with ordered software versions. Labels and
/// source notes explain source chronology; upload order alone proves none.
final class ImportAttachmentInput {
  ImportAttachmentInput({
    required this.key,
    required this.name,
    this.description = '',
    this.templateField,
    this.fieldId,
    required Iterable<ImportAttachmentVersionInput> versions,
    required this.currentVersion,
  }) : versions = List.unmodifiable(versions) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(key) ||
        name.trim().isEmpty ||
        name.length > 200 ||
        description.length > 2000 ||
        templateField != null && !_identity(templateField!) ||
        fieldId != null && !_identity(fieldId!) ||
        this.versions.isEmpty ||
        this.versions.length > 20 ||
        this.versions.map((v) => v.uploadId).toSet().length !=
            this.versions.length ||
        currentVersion == null && fieldId == null ||
        currentVersion != null &&
            (currentVersion! < 1 || currentVersion! > this.versions.length)) {
      throw const FormatException('Invalid proposed attachment');
    }
  }
  final String key, name, description;
  final String? templateField, fieldId;
  final List<ImportAttachmentVersionInput> versions;
  // One-based among the proposed originals. Null keeps an existing current
  // selection when adding history; it never guesses which source is newest.
  final int? currentVersion;
  ImportAttachmentInput resolved(
    Iterable<ImportAttachmentVersionInput> values,
  ) => ImportAttachmentInput(
    key: key,
    name: name,
    description: description,
    templateField: templateField,
    fieldId: fieldId,
    versions: values,
    currentVersion: currentVersion,
  );
  Map<String, Object?> get submissionJson => {
    'key': key,
    'name': name,
    'description': description,
    if (templateField != null) 'templateField': templateField,
    if (fieldId != null) 'fieldId': fieldId,
    'versions': [for (final v in versions) v.submissionJson],
    'currentVersion': currentVersion,
  };
  Map<String, Object?> toPrivateJson() => {
    ...submissionJson,
    'versions': [for (final v in versions) v.toPrivateJson()],
  };
  factory ImportAttachmentInput.fromJson(
    Map<String, dynamic> json, {
    bool private = false,
  }) {
    if (json.keys.any(
          (k) => !{
            'key',
            'name',
            'description',
            'templateField',
            'fieldId',
            'versions',
            'currentVersion',
          }.contains(k),
        ) ||
        !json.containsKey('currentVersion') ||
        json['versions'] is! List) {
      throw const FormatException('Invalid proposed attachment');
    }
    return ImportAttachmentInput(
      key: json['key'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      templateField: json['templateField'] as String?,
      fieldId: json['fieldId'] as String?,
      versions: (json['versions'] as List).map(
        (v) => ImportAttachmentVersionInput.fromJson(
          Map<String, dynamic>.from(v as Map),
          private: private,
        ),
      ),
      currentVersion: json['currentVersion'] as int?,
    );
  }
}

/// Trusted persistence boundary. Agent APIs expose metadata and upload only;
/// only the Owner review/admission boundary can consume original streams.
abstract interface class InformationImportFileRepository {
  Future<InformationImportUpload?> importFileUpload(String id);
  Future<InformationImportUpload?> importFileOperation(
    String binding,
    String operationId,
  );
  Future<void> stageImportFile(InformationImportUpload upload, Uint8List bytes);
  Future<T> withImportFile<T>(
    String id,
    Future<T> Function(InformationImportUpload, Stream<Uint8List>) action,
  );
  Future<void> pruneImportFiles(DateTime cutoff, Set<String> retained);
}

/// Admission commits source originals and their chosen identities in the same
/// transaction as information, related proposals and the owner's receipt.
final class InformationImportFilePromotion {
  const InformationImportFilePromotion(this.upload, this.version);
  final InformationImportUpload upload;
  final InformationAttachmentVersion version;
  Map<String, Object?> toPrivateJson() => {
    'upload': upload.toPrivateJson(),
    'version': version.toPrivateJson(),
  };
  factory InformationImportFilePromotion.fromPrivateJson(
    Map<String, dynamic> json,
  ) => InformationImportFilePromotion(
    InformationImportUpload.fromPrivateJson(
      Map<String, dynamic>.from(json['upload'] as Map),
    ),
    InformationAttachmentVersion.fromPrivateJson(
      Map<String, dynamic>.from(json['version'] as Map),
    ),
  );
}
