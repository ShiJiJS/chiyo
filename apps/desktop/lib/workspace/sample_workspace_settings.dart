import 'workspace_source.dart';

class SampleRetentionScope {
  SampleRetentionScope({
    required Iterable<String> ids,
    required this.digest,
    required this.requests,
    required this.grants,
    required this.operations,
    required this.preserved,
  }) : ids = Set.unmodifiable(ids);
  final Set<String> ids;
  final String digest;
  final int requests, grants, operations, preserved;
}

/// Session-only preferences. No platform, file, hooks or notification calls.
class SampleWorkspaceSettings implements WorkspaceSettingsSource {
  SampleWorkspaceSettings({
    required this.readable,
    required this.epoch,
    required this.beforeWrite,
    required this.changed,
    required this.approvals,
    required this.now,
    required this.retentionScope,
    required this.pruneRetention,
  });
  final Future<void> Function() readable;
  final int Function() epoch;
  final void Function() beforeWrite, changed;
  final WorkspaceApprovalSource approvals;
  final DateTime Function() now;
  final SampleRetentionScope Function(DateTime cutoff) retentionScope;
  final void Function(Set<String> ids) pruneRetention;
  WorkspacePreferences _value = const WorkspacePreferences();
  final _receipts = <String, WorkspaceSettingsReceipt>{};
  final _plans =
      <
        String,
        ({
          int epoch,
          int version,
          SampleRetentionScope scope,
          WorkspaceRetentionPreview preview,
        })
      >{};
  int _nextPlan = 0;
  int get requestMinutes => _value.requestMinutes;
  WorkspacePreferences get portablePreferences => _value;
  void installPortable(WorkspacePreferences value) {
    _value = value.copyWith(version: _value.version + 1);
    _plans.clear();
  }

  bool loseNextReply = false;
  Future<void> _ready() async {
    final generation = epoch();
    await readable();
    if (generation != epoch()) {
      throw const WorkspaceFailure('cancelled', '预览来源已变化，请重新核对设置。');
    }
  }

  @override
  Future<WorkspacePreferences> read() async {
    await _ready();
    return _value;
  }

  @override
  Future<WorkspaceSettingsReceipt> change(WorkspaceSettingsChange c) async {
    await _ready();
    if (c.operationId.isEmpty || c.operationId.length > 200) {
      throw const WorkspaceFailure('validation', '操作身份无效。');
    }
    if (_receipts[c.operationId] case final previous?) {
      if (previous.commandDigest != c.digest) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能保存不同设置。');
      }
      return previous;
    }
    if (c.expectedVersion != _value.version ||
        c.desired.version != c.expectedVersion) {
      throw const WorkspaceFailure('conflict', '设置已在别处变化，原选择保留，请先核对。');
    }
    final d = c.desired;
    if (![5, 15, 30, 60, 120].contains(d.requestMinutes) ||
        ![30, 90, 180, 365].contains(d.retentionDays)) {
      throw const WorkspaceFailure('validation', '请核对等待时间和记录保留期限。');
    }
    final plan = c.retentionToken == null ? null : _plans[c.retentionToken];
    if (c.retentionToken != null && d.retentionDays >= _value.retentionDays) {
      throw const WorkspaceFailure('validation', '清理确认不能用于其他设置操作。');
    }
    if (d.retentionDays < _value.retentionDays &&
        (plan == null ||
            plan.preview.days != d.retentionDays ||
            plan.version != _value.version ||
            plan.epoch != epoch())) {
      throw const WorkspaceFailure('review_required', '缩短记录保留期限需要先核对清理范围。');
    }
    if (plan != null &&
        retentionScope(plan.preview.cutoff).digest != plan.scope.digest) {
      throw const WorkspaceFailure(
        'retention_changed',
        '记录范围已变化，请重新预览并确认，尚未清理。',
      );
    }
    beforeWrite();
    final receipt = WorkspaceSettingsReceipt(
      operationId: c.operationId,
      expectedVersion: c.expectedVersion,
      commandDigest: c.digest,
      preferences: d.copyWith(version: _value.version + 1),
    );
    // No await between the checked scope, pruning and preference/receipt commit.
    // A production adapter must provide one durable transaction for this seam.
    if (plan != null) pruneRetention(plan.scope.ids);
    _value = receipt.preferences;
    _plans.clear();
    _receipts[c.operationId] = receipt;
    changed();
    if (loseNextReply) {
      loseNextReply = false;
      throw const WorkspaceFailure(
        'unknown_outcome',
        '设置保存结果未知，请核对原操作，不要重复保存。',
      );
    }
    return receipt;
  }

  @override
  Future<WorkspaceSettingsReceipt?> receipt(String id) async {
    await _ready();
    return _receipts[id];
  }

  @override
  Future<WorkspaceRetentionPreview> previewRetention(int days) async {
    await _ready();
    if (![30, 90, 180, 365].contains(days) || days >= _value.retentionDays) {
      throw const WorkspaceFailure('validation', '请选择更短的记录保留期限再核对。');
    }
    final cutoff = now().subtract(Duration(days: days));
    final scope = retentionScope(cutoff);
    final token = 'retention:${epoch()}:${_value.version}:${++_nextPlan}';
    final preview = WorkspaceRetentionPreview(
      token: token,
      days: days,
      cutoff: cutoff,
      requests: scope.requests,
      grants: scope.grants,
      operations: scope.operations,
      preserved: scope.preserved,
    );
    _plans.clear();
    _plans[token] = (
      epoch: epoch(),
      version: _value.version,
      scope: scope,
      preview: preview,
    );
    return preview;
  }

  @override
  Future<WorkspaceNotificationPreview> notificationPreview() async {
    final generation = epoch();
    await _ready();
    final result = await approvals.query(
      const WorkspaceApprovalQuery(limit: 1),
    );
    if (generation != epoch()) {
      throw const WorkspaceFailure('cancelled', '申请来源已变化，请重试。');
    }
    final row = result.items.firstOrNull;
    return row == null
        ? const WorkspaceNotificationPreview()
        : WorkspaceNotificationPreview(
            requestId: row.id,
            title: '有新的访问请求',
            description: '${row.agentClaim}：${row.title}',
          );
  }
}
