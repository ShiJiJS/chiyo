import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'info_core.dart' show AccessFailure;

// Conservative intake bounds. Final retained-file/backup capacity is measured
// together before the ordinary-attachment capability is advertised (#37).
const informationFileByteLimit = 10 * 1024 * 1024;
const informationFileStagingByteLimit = 100 * 1024 * 1024;
const informationFileStageLimit = 200;

/// Private owner metadata. This is neither a field value nor an Agent grant.
final class InformationFileStage {
  InformationFileStage({
    required this.id,
    required this.draftId,
    required this.originalName,
    required this.mediaType,
    required this.byteLength,
    required this.sha256,
  }) {
    if (!_validId(id) ||
        !_validId(draftId) ||
        originalName.isEmpty ||
        originalName.length > 1024 ||
        {'.', '..'}.contains(originalName) ||
        originalName.contains(RegExp(r'[/\\\x00-\x1f\x7f]')) ||
        mediaType.length > 200 ||
        mediaType.codeUnits.any((c) => c < 33 || c > 126) ||
        !RegExp(
          r'^[a-z0-9!#$&^_.+\-]+/[a-z0-9!#$&^_.+\-]+$',
        ).hasMatch(mediaType) ||
        byteLength < 0 ||
        byteLength > informationFileByteLimit ||
        sha256.length != 64 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const AccessFailure('invalid_information_file');
    }
  }

  factory InformationFileStage.forBytes({
    required String id,
    required String draftId,
    required String originalName,
    required String mediaType,
    required Uint8List bytes,
  }) {
    if (bytes.length > informationFileByteLimit) {
      throw const AccessFailure('attachment_too_large');
    }
    return InformationFileStage(
      id: id,
      draftId: draftId,
      originalName: originalName,
      mediaType: mediaType,
      byteLength: bytes.length,
      sha256: crypto.sha256.convert(bytes).toString(),
    );
  }

  final String id, draftId, originalName, mediaType, sha256;
  final int byteLength;

  static bool _validId(String id) =>
      id.isNotEmpty &&
      id.length <= 200 &&
      id.codeUnits.every((c) => c >= 33 && c <= 126);

  Map<String, Object> toPrivateJson() => {
    'id': id,
    'draftId': draftId,
    'originalName': originalName,
    'mediaType': mediaType,
    'byteLength': byteLength,
    'sha256': sha256,
  };

  factory InformationFileStage.fromPrivateJson(Map<String, dynamic> json) {
    if (json.length != 6 ||
        json['id'] is! String ||
        json['draftId'] is! String ||
        json['originalName'] is! String ||
        json['mediaType'] is! String ||
        json['byteLength'] is! int ||
        json['sha256'] is! String) {
      throw const AccessFailure('invalid_information_file');
    }
    return InformationFileStage(
      id: json['id'] as String,
      draftId: json['draftId'] as String,
      originalName: json['originalName'] as String,
      mediaType: json['mediaType'] as String,
      byteLength: json['byteLength'] as int,
      sha256: json['sha256'] as String,
    );
  }

  bool sameAs(InformationFileStage other) =>
      id == other.id &&
      draftId == other.draftId &&
      originalName == other.originalName &&
      mediaType == other.mediaType &&
      byteLength == other.byteLength &&
      sha256 == other.sha256;
}

final class InformationFileStagingUsage {
  const InformationFileStagingUsage(this.files, this.bytes);
  final int files, bytes;
}

/// Owner-only encrypted intake seam. No stage data is in items/catalog/read.
/// Committed attachments and their backup/delivery use a separate next step.
abstract interface class InformationFileStagingRepository {
  Future<InformationFileStage> stageInformationBytes({
    required String draftId,
    required String stageId,
    required String originalName,
    required String mediaType,
    required Uint8List bytes,
  });
  Future<InformationFileStagingUsage> informationFileStagingUsage();
  Future<void> releaseInformationStage(String draftId, String stageId);
  Future<void> releaseInformationDraft(String draftId);
}

/// Byte-owning implementation for synthetic core/desktop fixtures only.
final class MemoryInformationFileStages
    implements InformationFileStagingRepository {
  final _stages = <String, (InformationFileStage, Uint8List)>{};

  @override
  Future<InformationFileStage> stageInformationBytes({
    required String draftId,
    required String stageId,
    required String originalName,
    required String mediaType,
    required Uint8List bytes,
  }) async {
    final stage = InformationFileStage.forBytes(
      id: stageId,
      draftId: draftId,
      originalName: originalName,
      mediaType: mediaType,
      bytes: bytes,
    );
    final previous = _stages[stageId];
    if (previous != null) {
      if (!previous.$1.sameAs(stage)) {
        throw const AccessFailure('operation_conflict');
      }
      return previous.$1;
    }
    final used = _stages.values.fold<int>(0, (n, s) => n + s.$1.byteLength);
    if (_stages.length >= informationFileStageLimit ||
        used + bytes.length > informationFileStagingByteLimit) {
      throw const AccessFailure('attachment_capacity_exceeded');
    }
    _stages[stageId] = (stage, Uint8List.fromList(bytes));
    return stage;
  }

  @override
  Future<InformationFileStagingUsage> informationFileStagingUsage() async =>
      InformationFileStagingUsage(
        _stages.length,
        _stages.values.fold<int>(0, (n, s) => n + s.$1.byteLength),
      );

  @override
  Future<void> releaseInformationStage(String draftId, String stageId) async {
    if (_stages[stageId]?.$1.draftId == draftId) _stages.remove(stageId);
  }

  @override
  Future<void> releaseInformationDraft(String draftId) async {
    _stages.removeWhere((_, s) => s.$1.draftId == draftId);
  }
}
