import 'dart:convert';
import 'workspace_backups.dart';

Map<String, dynamic> _object(Object? value, Iterable<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      keys.any((k) => !value.containsKey(k))) {
    throw const FormatException('Invalid backup fields');
  }
  return Map<String, dynamic>.from(value);
}

Map<String, dynamic> backupEnvelope(Object? value, Iterable<String> keys) {
  final v = _object(value, ['wireVersion', ...keys]);
  if (v['wireVersion'] != 1) {
    throw const FormatException('Invalid backup version');
  }
  return v;
}

String backupId(Object? v) {
  if (v is! String || !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(v)) {
    throw const FormatException('Invalid backup identity');
  }
  return v;
}

String backupHash(Object? v) {
  if (v is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(v)) {
    throw const FormatException('Invalid backup digest');
  }
  return v;
}

int backupInt(Object? v, {int min = 0, int max = 1 << 53}) {
  if (v is! int || v < min || v > max) {
    throw const FormatException('Invalid backup count');
  }
  return v;
}

String backupName(Object? v) {
  if (v is! String ||
      v.isEmpty ||
      v == '.' ||
      v == '..' ||
      utf8.encode(v).length > 255 ||
      RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(v)) {
    throw const FormatException('Invalid backup name');
  }
  return v;
}

T _enum<T extends Enum>(List<T> values, Object? raw) =>
    values.where((v) => v.name == raw).firstOrNull ??
    (throw const FormatException('Invalid backup kind'));

bool _bool(Object? v) =>
    v is bool ? v : (throw const FormatException('Invalid backup flag'));

WorkspaceBackupResource backupResourceFromJson(Object? raw) {
  final v = _object(raw, ['id', 'name', 'kind', 'version']);
  return WorkspaceBackupResource(
    id: backupId(v['id']),
    name: backupName(v['name']),
    kind: _enum(WorkspaceBackupPick.values, v['kind']),
    version: backupInt(v['version'], min: 1),
  );
}

WorkspaceBackupCounts backupCountsFromJson(Object? raw) {
  if (raw is! Map ||
      WorkspaceBackupCategory.values.any(
        (c) =>
            c != WorkspaceBackupCategory.directoryBatches &&
            !raw.containsKey(c.name),
      ) ||
      raw.keys.any(
        (k) => !WorkspaceBackupCategory.values.any((c) => c.name == k),
      )) {
    throw const FormatException('Invalid backup categories');
  }
  return WorkspaceBackupCounts({
    for (final e in raw.entries)
      _enum(WorkspaceBackupCategory.values, e.key): backupInt(e.value),
  });
}

Map<String, Object?> backupChangeToJson(WorkspaceBackupChange c) => {
  'wireVersion': 1,
  ...c.json,
};

WorkspaceBackupChange backupChangeFromJson(Object? raw) {
  final v = backupEnvelope(raw, [
    'operationId',
    'action',
    'expectedVersion',
    'selection',
    'previewToken',
  ]);
  final c = WorkspaceBackupChange(
    operationId: backupId(v['operationId']),
    action: _enum(WorkspaceBackupAction.values, v['action']),
    expectedVersion: backupInt(v['expectedVersion'], min: 1),
    selection: v['selection'] == null
        ? null
        : backupResourceFromJson(v['selection']),
    previewToken: v['previewToken'] == null
        ? null
        : backupId(v['previewToken']),
  );
  final kind = switch (c.action) {
    WorkspaceBackupAction.saveKey => WorkspaceBackupPick.keyOutput,
    WorkspaceBackupAction.export => WorkspaceBackupPick.archiveOutput,
    WorkspaceBackupAction.restore => WorkspaceBackupPick.archiveInput,
    _ => null,
  };
  if (c.selection?.kind != kind ||
      ((c.action == WorkspaceBackupAction.restore) !=
          (c.previewToken != null))) {
    throw const FormatException('Invalid backup action scope');
  }
  return c;
}

Map<String, Object?> backupReceiptToJson(WorkspaceBackupReceipt r) => {
  'wireVersion': 1,
  'operationId': r.operationId,
  'commandDigest': r.commandDigest,
  'action': r.action.name,
  'expectedVersion': r.expectedVersion,
  'version': r.version,
  'resource': r.resource?.json,
  'counts': r.counts?.json,
};

WorkspaceBackupReceipt backupReceiptFromJson(Object? raw) {
  final v = backupEnvelope(raw, [
    'operationId',
    'commandDigest',
    'action',
    'expectedVersion',
    'version',
    'resource',
    'counts',
  ]);
  final r = WorkspaceBackupReceipt(
    operationId: backupId(v['operationId']),
    commandDigest: backupHash(v['commandDigest']),
    action: _enum(WorkspaceBackupAction.values, v['action']),
    expectedVersion: backupInt(v['expectedVersion'], min: 1),
    version: backupInt(v['version'], min: 2),
    resource: v['resource'] == null
        ? null
        : backupResourceFromJson(v['resource']),
    counts: v['counts'] == null ? null : backupCountsFromJson(v['counts']),
  );
  if (r.version != r.expectedVersion + 1 ||
      switch (r.action) {
        WorkspaceBackupAction.enableKey ||
        WorkspaceBackupAction.cleanup => r.resource != null || r.counts != null,
        WorkspaceBackupAction.saveKey =>
          r.resource?.kind != WorkspaceBackupPick.keyInput || r.counts != null,
        WorkspaceBackupAction.export || WorkspaceBackupAction.restore =>
          r.resource?.kind != WorkspaceBackupPick.archiveInput ||
              r.counts == null,
      }) {
    throw const FormatException('Invalid backup acknowledgement');
  }
  return r;
}

Map<String, Object?> backupPreviewToJson(WorkspaceBackupPreview p) => {
  'wireVersion': 1,
  'token': p.token,
  'archive': p.archive.json,
  'key': p.key.json,
  'counts': p.counts.json,
  'createdAt': p.createdAt.toUtc().toIso8601String(),
  'formatLabel': p.formatLabel,
};

WorkspaceBackupPreview backupPreviewFromJson(Object? raw) {
  final v = backupEnvelope(raw, [
    'token',
    'archive',
    'key',
    'counts',
    'createdAt',
    'formatLabel',
  ]);
  final p = WorkspaceBackupPreview(
    token: backupId(v['token']),
    archive: backupResourceFromJson(v['archive']),
    key: backupResourceFromJson(v['key']),
    counts: backupCountsFromJson(v['counts']),
    createdAt: DateTime.parse(v['createdAt'] as String).toUtc(),
    formatLabel: v['formatLabel'] as String,
  );
  if (p.archive.kind != WorkspaceBackupPick.archiveInput ||
      p.key.kind != WorkspaceBackupPick.keyInput ||
      p.formatLabel.isEmpty ||
      p.formatLabel.length > 200) {
    throw const FormatException('Invalid backup preview');
  }
  return p;
}

Map<String, Object?> backupStatusToJson(WorkspaceBackupStatus s) => {
  'wireVersion': 1,
  'version': s.version,
  'keyCreated': s.keyCreated,
  'keySaved': s.keySaved,
  'recipientEmpty': s.recipientEmpty,
  'blockers': s.blockers,
  'cleanupCount': s.cleanupCount,
  'latestArchive': s.latestArchive?.json,
  'pending': s.pending == null
      ? null
      : {
          'command': backupChangeToJson(s.pending!.command),
          'restoreCounts': s.pending!.restoreCounts?.json,
        },
};

WorkspaceBackupStatus backupStatusFromJson(Object? raw) {
  final v = backupEnvelope(raw, [
    'version',
    'keyCreated',
    'keySaved',
    'recipientEmpty',
    'blockers',
    'cleanupCount',
    'latestArchive',
    'pending',
  ]);
  final blockers = v['blockers'];
  if (blockers is! List ||
      blockers.length > 100 ||
      blockers.any((s) => s is! String || s.length > 2000)) {
    throw const FormatException('Invalid backup blockers');
  }
  final pending = v['pending'] == null
      ? null
      : _object(v['pending'], ['command', 'restoreCounts']);
  return WorkspaceBackupStatus(
    version: backupInt(v['version'], min: 1),
    keyCreated: _bool(v['keyCreated']),
    keySaved: _bool(v['keySaved']),
    recipientEmpty: _bool(v['recipientEmpty']),
    blockers: blockers.cast<String>(),
    cleanupCount: backupInt(v['cleanupCount']),
    latestArchive: v['latestArchive'] == null
        ? null
        : backupResourceFromJson(v['latestArchive']),
    pending: pending == null
        ? null
        : WorkspaceBackupPending(
            backupChangeFromJson(pending['command']),
            restoreCounts: pending['restoreCounts'] == null
                ? null
                : backupCountsFromJson(pending['restoreCounts']),
          ),
  );
}
