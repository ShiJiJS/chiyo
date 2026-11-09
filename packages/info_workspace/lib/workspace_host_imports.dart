/// Owner-selected public host-key material, represented by an opaque lease.
class WorkspaceHostFile {
  const WorkspaceHostFile(this.selectionId, this.name, this.byteLength);
  final String selectionId, name;
  final int byteLength;
}

typedef WorkspaceHostFilePicker = Future<WorkspaceHostFile?> Function();

class WorkspaceHostFileEntry {
  const WorkspaceHostFileEntry(
    this.pattern,
    this.keyType,
    this.fingerprint,
    this.marker,
  );
  final String pattern, keyType, fingerprint;
  final String? marker;
}

class WorkspaceHostImportStatus {
  const WorkspaceHostImportStatus({
    required this.name,
    required this.digest,
    required this.entryCount,
    required this.version,
  });
  final String name, digest;
  final int entryCount, version;
}

class WorkspaceHostImportPreview {
  WorkspaceHostImportPreview({
    required this.file,
    required this.digest,
    required this.version,
    required this.pluginVersion,
    required Iterable<WorkspaceHostFileEntry> entries,
    this.previous,
  }) : entries = List.unmodifiable(entries);
  final WorkspaceHostFile file;
  final String digest;
  final int version, pluginVersion;
  final List<WorkspaceHostFileEntry> entries;
  final WorkspaceHostImportStatus? previous;
}

class WorkspaceHostImportChange {
  const WorkspaceHostImportChange(this.operationId, this.preview);
  final String operationId;
  final WorkspaceHostImportPreview preview;
}

/// A content-free fact about this exact import, never an SSH execution grant.
class WorkspaceHostImportReceipt {
  const WorkspaceHostImportReceipt({
    required this.operationId,
    required this.selectionId,
    required this.expectedVersion,
    required this.expectedPluginVersion,
    required this.result,
  });
  final String operationId, selectionId;
  final int expectedVersion, expectedPluginVersion;
  final WorkspaceHostImportStatus result;
  bool matches(WorkspaceHostImportChange c) =>
      operationId == c.operationId &&
      selectionId == c.preview.file.selectionId &&
      expectedVersion == c.preview.version &&
      expectedPluginVersion == c.preview.pluginVersion &&
      result.version > expectedVersion &&
      result.name == c.preview.file.name &&
      result.digest == c.preview.digest &&
      result.entryCount == c.preview.entries.length;
}
