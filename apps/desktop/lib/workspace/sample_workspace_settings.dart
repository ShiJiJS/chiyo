import 'workspace_source.dart';

/// Session-only preferences. No platform, file, hooks or notification calls.
class SampleWorkspaceSettings implements WorkspaceSettingsSource {
  SampleWorkspaceSettings({
    required this.readable,
    required this.epoch,
    required this.beforeWrite,
    required this.changed,
    required this.approvals,
  });
  final Future<void> Function() readable;
  final int Function() epoch;
  final void Function() beforeWrite, changed;
  final WorkspaceApprovalSource approvals;
  WorkspacePreferences _value = const WorkspacePreferences();
  final _receipts = <String, WorkspaceSettingsReceipt>{};
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
    if (d.retentionDays < _value.retentionDays) {
      throw const WorkspaceFailure('review_required', '缩短记录保留期限需要先核对清理范围。');
    }
    beforeWrite();
    final receipt = WorkspaceSettingsReceipt(
      operationId: c.operationId,
      expectedVersion: c.expectedVersion,
      commandDigest: c.digest,
      preferences: d.copyWith(version: _value.version + 1),
    );
    _value = receipt.preferences;
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
