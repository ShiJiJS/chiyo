import 'dart:typed_data';
import 'dart:math';
import 'workspace_records.dart';

final _operationRandom = Random.secure();

/// Fresh across processes; keep the same value while reconciling one outcome.
String workspaceFileOperationId() =>
    'file-${List.generate(16, (_) => _operationRandom.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

class WorkspaceFileRef {
  const WorkspaceFileRef(this.id, this.version);
  factory WorkspaceFileRef.fromJson(Object? value) {
    if (value is! Map ||
        value['attachmentId'] is! String ||
        value['version'] is! int ||
        (value['version'] as int) < 1) {
      throw const WorkspaceFailure('not_found', '文件引用不可用。');
    }
    return WorkspaceFileRef(
      value['attachmentId'] as String,
      value['version'] as int,
    );
  }
  final String id;
  final int version;
  Map<String, Object?> toJson() => {'attachmentId': id, 'version': version};
  @override
  bool operator ==(Object other) =>
      other is WorkspaceFileRef && id == other.id && version == other.version;
  @override
  int get hashCode => Object.hash(id, version);
}

/// An opaque selection issued by the injected host picker. No path or bytes.
class WorkspaceFileCandidate {
  const WorkspaceFileCandidate(
    this.selectionId,
    this.filename,
    this.mediaType,
    this.byteLength,
  );
  final String selectionId, filename, mediaType;
  final int byteLength;
}

class WorkspaceFileVersion {
  const WorkspaceFileVersion({
    required this.ref,
    required this.filename,
    required this.mediaType,
    required this.byteLength,
    required this.createdAt,
  });
  final WorkspaceFileRef ref;
  final String filename, mediaType;
  final int byteLength;
  final DateTime createdAt;
}

class WorkspaceFileHistory {
  WorkspaceFileHistory({
    required this.recordVersion,
    required this.current,
    required Iterable<WorkspaceFileVersion> versions,
  }) : versions = List.unmodifiable(versions);
  final int recordVersion;
  final WorkspaceFileVersion current;
  final List<WorkspaceFileVersion> versions;
}

enum WorkspaceFilePreviewKind { image, text, unsupported }

/// Owner preview pixels/text. This is not an attachment delivery endpoint.
class WorkspaceFilePreview {
  WorkspaceFilePreview({
    required this.file,
    required this.kind,
    this.page = 0,
    this.pageCount = 1,
    this.text = '',
    Uint8List? image,
  }) : image = image == null
           ? null
           : Uint8List.fromList(image).asUnmodifiableView();
  final WorkspaceFileVersion file;
  final WorkspaceFilePreviewKind kind;
  final int page, pageCount;
  final String text;
  final Uint8List? image;
}

enum WorkspaceFileChangeKind { replace, restore }

class WorkspaceFileChange {
  const WorkspaceFileChange({
    required this.operationId,
    required this.record,
    required this.fieldKey,
    required this.expectedRecordVersion,
    required this.expectedFileVersion,
    required this.kind,
    this.selectionId,
    this.restoreVersion,
  });
  final String operationId, fieldKey;
  final WorkspaceRecordRef record;
  final int expectedRecordVersion, expectedFileVersion;
  final WorkspaceFileChangeKind kind;
  final String? selectionId;
  final int? restoreVersion;
}

class WorkspaceFileImport {
  WorkspaceFileImport({
    required this.operationId,
    required this.selectionId,
    required this.name,
    this.description = '',
    this.directoryId,
    Iterable<String> tagIds = const [],
  }) : tagIds = List.unmodifiable(tagIds);
  final String operationId, selectionId, name, description;
  final String? directoryId;
  final List<String> tagIds;
}

enum WorkspaceFileAction { saveAs, open }

class WorkspaceFileActionResult {
  const WorkspaceFileActionResult({
    required this.completed,
    required this.filename,
  });
  final bool completed;
  final String filename;
}

/// The view invokes a host picker; only the isolated composition knows samples.
typedef WorkspaceFilePicker = Future<WorkspaceFileCandidate?> Function();

/// A committed operation fact. Query failure must throw; null means the host
/// positively confirms this operation was not committed, not "unknown".
class WorkspaceFileOperationReceipt {
  const WorkspaceFileOperationReceipt(
    this.record,
    this.file, {
    this.actionCompleted,
  });
  final WorkspaceRecordRef record;
  final WorkspaceFileRef? file;
  final bool? actionCompleted;
}
