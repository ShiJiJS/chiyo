import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
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
    this.available = true,
    this.label = '',
    this.sourceNote = '',
  });
  final WorkspaceFileRef ref;
  final String filename, mediaType;
  final int byteLength;
  final DateTime createdAt;
  final bool available;
  final String label, sourceNote;

  bool get isMarkdown =>
      mediaType == 'text/markdown' ||
      (mediaType == 'text/plain' &&
          RegExp(r'\.(md|markdown)$', caseSensitive: false).hasMatch(filename));
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
    this.pixelWidth,
    this.pixelHeight,
    Uint8List? image,
  }) : image = image == null
           ? null
           : Uint8List.fromList(image).asUnmodifiableView() {
    if (kind == WorkspaceFilePreviewKind.image &&
        (image == null || (pixelWidth ?? 0) < 1 || (pixelHeight ?? 0) < 1)) {
      throw ArgumentError(
        'Image previews require pixels and positive dimensions.',
      );
    }
  }
  final WorkspaceFileVersion file;
  final WorkspaceFilePreviewKind kind;
  final int page, pageCount;
  final int? pixelWidth, pixelHeight;
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
  String get digest => crypto.sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'action': kind.name,
            'record': record.key,
            'field': fieldKey,
            'recordVersion': expectedRecordVersion,
            'fileVersion': expectedFileVersion,
            'selection': selectionId,
            'restoreVersion': restoreVersion,
          }),
        ),
      )
      .toString();
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
  String get digest => crypto.sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'action': 'import',
            'selection': selectionId,
            'name': name,
            'description': description,
            'directory': directoryId,
            'tags': tagIds.toList()..sort(),
          }),
        ),
      )
      .toString();
}

enum WorkspaceFileAction { saveAs, open }

class WorkspaceFileActionResult {
  const WorkspaceFileActionResult({
    required this.completed,
    required this.filename,
    this.cleanupPending = false,
  });
  final bool cleanupPending;
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
    this.openCopyHeld,
    this.commandDigest,
    this.cleanupPending = false,
  });
  final WorkspaceRecordRef record;
  final WorkspaceFileRef? file;
  final bool? actionCompleted, openCopyHeld;
  final bool cleanupPending;
  final String? commandDigest;
}

/// Optional owner staging cleanup for a closed file form.
abstract interface class WorkspaceFileSelectionReleaser {
  Future<void> releaseFileSelection(String selectionId);
}

/// Canonical identity of the page's original action. Paths are never commands.
String workspaceFileActionDigest(
  WorkspaceRecordRef record,
  String fieldKey,
  int version,
  WorkspaceFileAction action,
) => crypto.sha256
    .convert(
      utf8.encode(
        jsonEncode({
          'action': action.name,
          'record': record.key,
          'field': fieldKey,
          'version': version,
        }),
      ),
    )
    .toString();

class WorkspacePendingFileAction {
  const WorkspacePendingFileAction(
    this.operationId,
    this.digest,
    this.file, {
    this.action = WorkspaceFileAction.saveAs,
  });
  final String operationId, digest;
  final WorkspaceFileRef file;
  final WorkspaceFileAction action;
}

class WorkspaceFileActionState {
  const WorkspaceFileActionState({
    this.pending,
    this.cleanupPending = 0,
    this.openCopies = 0,
    this.openCleanupPending = 0,
  });
  final WorkspacePendingFileAction? pending;
  final int cleanupPending, openCopies, openCleanupPending;
}

abstract interface class WorkspaceFileActionRecovery {
  Future<WorkspaceFileActionState> fileActionState(
    WorkspaceRecordRef record,
    String fieldKey,
  );
  Future<void> recoverFileActionAccess(String operationId);
  Future<void> cleanupFileActions(WorkspaceRecordRef record, String fieldKey);
}

abstract interface class WorkspaceFileOpenRecovery {
  Future<void> finishFileOpen(String operationId);
  Future<void> closeOpenFileCopies(WorkspaceRecordRef record, String fieldKey);
}
