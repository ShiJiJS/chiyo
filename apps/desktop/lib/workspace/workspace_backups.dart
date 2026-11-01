import 'dart:convert';
import 'package:crypto/crypto.dart';

enum WorkspaceBackupPick { keyOutput, archiveOutput, archiveInput, keyInput }

enum WorkspaceBackupAction { enableKey, saveKey, export, restore, cleanup }

enum WorkspaceBackupCategory {
  information('信息'),
  credentials('凭据对象'),
  materials('凭据版本'),
  files('普通附件版本'),
  fileBytes('附件字节'),
  directories('目录'),
  tags('标签'),
  templates('类型定义'),
  plugins('模板插件'),
  legacyTemplates('旧版模板'),
  revisions('资料修订'),
  recycled('回收对象'),
  grants('授权历史'),
  operations('操作事实'),
  hosts('主机信任');

  const WorkspaceBackupCategory(this.label);
  final String label;
}

class WorkspaceBackupCounts {
  WorkspaceBackupCounts(Map<WorkspaceBackupCategory, int> values)
    : values = Map.unmodifiable(values);
  final Map<WorkspaceBackupCategory, int> values;
  int operator [](WorkspaceBackupCategory kind) => values[kind] ?? 0;
  bool get valid => values.values.every((n) => n >= 0);
  Map<String, int> get json => {
    for (final e in values.entries) e.key.name: e.value,
  };
  bool same(WorkspaceBackupCounts other) =>
      WorkspaceBackupCategory.values.every((kind) => this[kind] == other[kind]);
}

/// Picker-produced identity, never a raw path, plaintext key or database handle.
class WorkspaceBackupResource {
  const WorkspaceBackupResource({
    required this.id,
    required this.name,
    required this.kind,
    this.version = 1,
  });
  final String id, name;
  final WorkspaceBackupPick kind;
  final int version;
  Map<String, Object?> get json => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'version': version,
  };
  bool same(WorkspaceBackupResource other) =>
      jsonEncode(json) == jsonEncode(other.json);
}

typedef WorkspaceBackupPicker =
    Future<WorkspaceBackupResource?> Function(WorkspaceBackupPick kind);

class WorkspaceBackupStatus {
  WorkspaceBackupStatus({
    required this.version,
    required this.keyCreated,
    required this.keySaved,
    required this.recipientEmpty,
    required Iterable<String> blockers,
    required this.cleanupCount,
    this.latestArchive,
    this.pending,
  }) : blockers = List.unmodifiable(blockers);
  final int version, cleanupCount;
  final bool keyCreated, keySaved, recipientEmpty;
  final List<String> blockers;
  final WorkspaceBackupResource? latestArchive;
  final WorkspaceBackupPending? pending;
}

class WorkspaceBackupPending {
  const WorkspaceBackupPending(this.command, {this.restoreCounts});
  final WorkspaceBackupChange command;
  final WorkspaceBackupCounts? restoreCounts;
}

class WorkspaceBackupPreview {
  const WorkspaceBackupPreview({
    required this.token,
    required this.archive,
    required this.key,
    required this.counts,
    required this.createdAt,
    required this.formatLabel,
  });
  final String token, formatLabel;
  final WorkspaceBackupResource archive, key;
  final WorkspaceBackupCounts counts;
  final DateTime createdAt;
}

class WorkspaceBackupChange {
  const WorkspaceBackupChange({
    required this.operationId,
    required this.action,
    required this.expectedVersion,
    this.selection,
    this.previewToken,
  });
  final String operationId;
  final WorkspaceBackupAction action;
  final int expectedVersion;
  final WorkspaceBackupResource? selection;
  final String? previewToken;
  Map<String, Object?> get json => {
    'operationId': operationId,
    'action': action.name,
    'expectedVersion': expectedVersion,
    'selection': selection?.json,
    'previewToken': previewToken,
  };
  String get digest => sha256.convert(utf8.encode(jsonEncode(json))).toString();
}

class WorkspaceBackupReceipt {
  const WorkspaceBackupReceipt({
    required this.operationId,
    required this.commandDigest,
    required this.action,
    required this.expectedVersion,
    required this.version,
    this.resource,
    this.counts,
  });
  final String operationId, commandDigest;
  final WorkspaceBackupAction action;
  final int expectedVersion, version;
  final WorkspaceBackupResource? resource;
  final WorkspaceBackupCounts? counts;
  bool matches(WorkspaceBackupChange c) =>
      operationId == c.operationId &&
      commandDigest == c.digest &&
      action == c.action &&
      expectedVersion == c.expectedVersion &&
      version > expectedVersion &&
      (counts == null || counts!.valid) &&
      switch (action) {
        WorkspaceBackupAction.enableKey ||
        WorkspaceBackupAction.cleanup => resource == null,
        WorkspaceBackupAction.saveKey =>
          resource?.kind == WorkspaceBackupPick.keyInput &&
              resource?.name == c.selection?.name,
        WorkspaceBackupAction.export =>
          resource?.kind == WorkspaceBackupPick.archiveInput &&
              resource?.name == c.selection?.name &&
              counts != null,
        WorkspaceBackupAction.restore =>
          resource != null &&
              c.selection != null &&
              resource!.same(c.selection!) &&
              counts != null,
      };
}

abstract interface class WorkspaceBackupSource {
  Future<WorkspaceBackupStatus> status();
  Future<String> revealRecoveryKey();
  Future<WorkspaceBackupPreview> inspect(
    WorkspaceBackupResource archive,
    WorkspaceBackupResource key,
  );
  Future<void> releasePreview(String token);
  Future<WorkspaceBackupReceipt> change(WorkspaceBackupChange change);

  /// Null is definitive non-submission, not a lookup failure or missing artifact.
  Future<WorkspaceBackupReceipt?> receipt(String operationId);
}

/// Optional Owner capability. No private file path or bookmark reaches a page.
abstract interface class WorkspaceBackupAccessRecovery {
  Future<bool> requestRecoveryAccess(String operationId);
}
