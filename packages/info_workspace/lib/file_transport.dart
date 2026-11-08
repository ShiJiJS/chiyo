import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:info_core/info_core.dart' as core;
import 'owner_workspace_file_reads.dart';
import 'workspace_source.dart';
import 'workspace_transport.dart';

Map<String, Object?> fileCandidateToJson(WorkspaceFileCandidate c) => {
  'selectionId': c.selectionId,
  'filename': c.filename,
  'mediaType': c.mediaType,
  'byteLength': c.byteLength,
};
WorkspaceFileCandidate fileCandidateFromJson(Object? value) =>
    decodeWorkspace(() {
      final v = workspaceObject(value);
      return WorkspaceFileCandidate(
        v['selectionId'] as String,
        v['filename'] as String,
        v['mediaType'] as String,
        v['byteLength'] as int,
      );
    });
Map<String, Object?> fileVersionToJson(WorkspaceFileVersion v) => {
  'ref': v.ref.toJson(),
  'filename': v.filename,
  'mediaType': v.mediaType,
  'byteLength': v.byteLength,
  'createdAt': v.createdAt.toIso8601String(),
  'available': v.available,
  'label': v.label,
  'sourceNote': v.sourceNote,
};
WorkspaceFileVersion fileVersionFromJson(Object? value) => decodeWorkspace(() {
  final v = workspaceObject(value);
  return WorkspaceFileVersion(
    ref: WorkspaceFileRef.fromJson(v['ref']),
    filename: v['filename'] as String,
    mediaType: v['mediaType'] as String,
    byteLength: v['byteLength'] as int,
    createdAt: DateTime.parse(v['createdAt'] as String),
    available: v['available'] as bool,
    label: v['label'] as String,
    sourceNote: v['sourceNote'] as String,
  );
});
Map<String, Object?> fileHistoryToJson(WorkspaceFileHistory h) => {
  'wireVersion': 1,
  'recordVersion': h.recordVersion,
  'current': fileVersionToJson(h.current),
  'versions': h.versions.map(fileVersionToJson).toList(),
};
WorkspaceFileHistory fileHistoryFromJson(Object? value) => decodeWorkspace(() {
  final h = workspaceObject(value);
  if (h['wireVersion'] != 1) throw const FormatException();
  return WorkspaceFileHistory(
    recordVersion: h['recordVersion'] as int,
    current: fileVersionFromJson(h['current']),
    versions: (h['versions'] as List).map(fileVersionFromJson),
  );
});
Map<String, Object?> fileOriginalToJson(
  core.OwnerInformationAttachment content,
) => {
  'wireVersion': 1,
  'file': fileVersionToJson(workspaceFileVersion(content.version)),
  'sha256': content.version.sha256,
  'bytes': base64Encode(content.bytes),
};

/// Verified owner originals travel only through dedicated authenticated routes.
/// Views receive the renderer's pixels/text; no server path is meaningful here.
class WorkspaceFileOriginal {
  WorkspaceFileOriginal._(this.file, this.sha256, this.bytes);
  factory WorkspaceFileOriginal.verified(
    WorkspaceFileVersion file,
    String digest,
    Uint8List bytes,
  ) {
    if (!file.available ||
        file.byteLength != bytes.length ||
        bytes.length > core.informationFileByteLimit ||
        crypto.sha256.convert(bytes).toString() != digest) {
      throw const FormatException('Invalid original');
    }
    return WorkspaceFileOriginal._(
      file,
      digest,
      Uint8List.fromList(bytes).asUnmodifiableView(),
    );
  }
  final WorkspaceFileVersion file;
  final String sha256;
  final Uint8List bytes;
}

Map<String, Object?> originalContentToJson(WorkspaceFileOriginal content) => {
  'wireVersion': 1,
  'file': fileVersionToJson(content.file),
  'sha256': content.sha256,
  'bytes': base64Encode(content.bytes),
};

WorkspaceFileOriginal fileOriginalFromJson(Object? value) =>
    decodeWorkspace(() {
      final v = workspaceObject(value);
      if (v['wireVersion'] != 1 || v.length != 4) throw const FormatException();
      final file = fileVersionFromJson(v['file']);
      final encoded = v['bytes'] as String, digest = v['sha256'] as String;
      if (!file.available ||
          file.byteLength < 0 ||
          file.byteLength > core.informationFileByteLimit ||
          encoded.length > ((core.informationFileByteLimit + 2) ~/ 3) * 4 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
        throw const FormatException();
      }
      final bytes = base64Decode(encoded);
      if (bytes.length != file.byteLength ||
          crypto.sha256.convert(bytes).toString() != digest) {
        throw const FormatException();
      }
      return WorkspaceFileOriginal._(file, digest, bytes.asUnmodifiableView());
    });
Map<String, Object?> fileImportToJson(WorkspaceFileImport c) => {
  'operationId': c.operationId,
  'selectionId': c.selectionId,
  'name': c.name,
  'description': c.description,
  'directoryId': c.directoryId,
  'tagIds': c.tagIds,
};
WorkspaceFileImport fileImportFromJson(Map<String, dynamic> c) =>
    decodeWorkspace(() {
      if (c.keys.any(
        (k) => !const {
          'operationId',
          'selectionId',
          'name',
          'description',
          'directoryId',
          'tagIds',
        }.contains(k),
      )) {
        throw const FormatException();
      }
      return WorkspaceFileImport(
        operationId: c['operationId'] as String,
        selectionId: c['selectionId'] as String,
        name: c['name'] as String,
        description: c['description'] as String,
        directoryId: c['directoryId'] as String?,
        tagIds: (c['tagIds'] as List).cast<String>(),
      );
    });
Map<String, Object?> fileChangeToJson(WorkspaceFileChange c) => {
  'operationId': c.operationId,
  'record': recordRefToJson(c.record),
  'fieldKey': c.fieldKey,
  'expectedRecordVersion': c.expectedRecordVersion,
  'expectedFileVersion': c.expectedFileVersion,
  'kind': c.kind.name,
  'selectionId': c.selectionId,
  'restoreVersion': c.restoreVersion,
};
WorkspaceFileChange fileChangeFromJson(Map<String, dynamic> c) =>
    decodeWorkspace(() {
      if (c.keys.any(
        (k) => !const {
          'operationId',
          'record',
          'fieldKey',
          'expectedRecordVersion',
          'expectedFileVersion',
          'kind',
          'selectionId',
          'restoreVersion',
        }.contains(k),
      )) {
        throw const FormatException();
      }
      return WorkspaceFileChange(
        operationId: c['operationId'] as String,
        record: recordRefFromJson(c['record']),
        fieldKey: c['fieldKey'] as String,
        expectedRecordVersion: c['expectedRecordVersion'] as int,
        expectedFileVersion: c['expectedFileVersion'] as int,
        kind: WorkspaceFileChangeKind.values.byName(c['kind'] as String),
        selectionId: c['selectionId'] as String?,
        restoreVersion: c['restoreVersion'] as int?,
      );
    });
Map<String, Object?> fileReceiptToJson(WorkspaceFileOperationReceipt r) => {
  'record': recordRefToJson(r.record),
  'file': r.file?.toJson(),
  'commandDigest': r.commandDigest,
  'actionCompleted': r.actionCompleted,
  'openCopyHeld': r.openCopyHeld,
  'cleanupPending': r.cleanupPending,
};
WorkspaceFileOperationReceipt fileReceiptFromJson(Object? value) =>
    decodeWorkspace(() {
      final r = workspaceObject(value);
      return WorkspaceFileOperationReceipt(
        recordRefFromJson(r['record']),
        r['file'] == null ? null : WorkspaceFileRef.fromJson(r['file']),
        commandDigest: r['commandDigest'] as String?,
        actionCompleted: r['actionCompleted'] as bool?,
        openCopyHeld: r['openCopyHeld'] as bool?,
        cleanupPending: r['cleanupPending'] as bool,
      );
    });
