import 'package:info_core/info_core.dart' as core;
import '../desktop_runtime.dart';
import 'workspace_source.dart';

class OwnerWorkspaceSettings implements WorkspaceSettingsSource {
  OwnerWorkspaceSettings({
    required this.owner,
    required this.runtime,
    required this.changed,
  }) : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final DesktopRuntime runtime;
  final void Function() changed;
  final core.OwnerLibraryScope _scope;
  core.DesktopRetentionPlan? _retention;
  Future<T> _run<T>(Future<T> Function() action) async {
    try {
      return await owner.inLibraryScope(_scope, action);
    } on core.AccessFailure catch (e) {
      throw WorkspaceFailure(e.status, switch (e.status) {
        'library_changed' => '资料库已替换，请重新读取设置。',
        'conflict' => '设置已变化，请核对后再保存。',
        'retention_changed' => '清理范围已变化，请重新预览并确认。',
        'operation_conflict' => '原操作不能提交不同设置。',
        _ => '设置暂时无法保存或读取，请重试。',
      });
    }
  }

  WorkspacePreferences _preferences(core.DesktopPreferences p) =>
      WorkspacePreferences(
        version: p.version,
        theme: p.dark ? WorkspaceTheme.dark : WorkspaceTheme.light,
        notifications: p.notifications,
        requestMinutes: p.requestMinutes,
        retentionDays: p.retentionDays,
        background: p.background,
      );
  WorkspaceSettingsReceipt _receipt(core.DesktopPreferencesReceipt r) =>
      WorkspaceSettingsReceipt(
        operationId: r.operationId,
        expectedVersion: r.expectedVersion,
        commandDigest: r.commandDigest,
        preferences: _preferences(r.preferences),
      );
  @override
  Future<WorkspacePreferences> read() =>
      _run(() async => _preferences(owner.desktopPreferences));
  @override
  Future<WorkspaceSettingsReceipt> change(
    WorkspaceSettingsChange c,
  ) => _run(() async {
    final previous = await owner.desktopPreferencesReceipt(c.operationId);
    if (previous != null) {
      if (previous.commandDigest != c.digest) {
        throw const WorkspaceFailure('operation_conflict', '原操作不能提交不同设置。');
      }
      return _receipt(previous);
    }
    if (c.desired.version != c.expectedVersion ||
        c.retentionToken != null && c.retentionToken != _retention?.token) {
      throw const WorkspaceFailure('review_required', '请重新核对设置及清理范围。');
    }
    final wasEnabled = owner.notificationsEnabled;
    final d = c.desired;
    final r = await owner.saveDesktopPreferences(
      operationId: c.operationId,
      commandDigest: c.digest,
      expectedVersion: c.expectedVersion,
      desired: core.DesktopPreferences(
        version: c.expectedVersion + 1,
        dark: d.theme == WorkspaceTheme.dark,
        notifications: d.notifications,
        requestMinutes: d.requestMinutes,
        retentionDays: d.retentionDays,
        background: d.background,
      ),
      retention: c.retentionToken == null ? null : _retention,
    );
    _retention = null;
    changed();
    // This is the owner's real preference. OS notification permission remains
    // a separate system decision; failure never rolls back a committed setting.
    if (!wasEnabled &&
        r.preferences.notifications &&
        runtime.availability.notifications ==
            NotificationAvailability.notEnabled) {
      await runtime.enableNotifications();
    }
    return _receipt(r);
  });
  @override
  Future<WorkspaceSettingsReceipt?> receipt(String id) => _run(() async {
    final r = await owner.desktopPreferencesReceipt(id);
    return r == null ? null : _receipt(r);
  });
  @override
  Future<WorkspaceRetentionPreview> previewRetention(int days) =>
      _run(() async {
        final p = await owner.previewDesktopRetention(days);
        _retention = p;
        return WorkspaceRetentionPreview(
          token: p.token,
          days: p.days,
          cutoff: p.cutoff,
          requests: p.cleanup.requests,
          grants: p.cleanup.grants,
          operations: p.cleanup.operations,
          preserved: p.preserved,
        );
      });
  @override
  Future<WorkspaceNotificationPreview> notificationPreview() => _run(() async {
    final requests = owner.queryInbox(filter: core.InboxFilter.pending).entries;
    final r = requests.firstOrNull;
    if (r == null) {
      final batch = owner.credentialBatches
          .where((r) => owner.credentialBatchState(r) == 'pending')
          .firstOrNull;
      if (batch != null) {
        return WorkspaceNotificationPreview(
          requestId: batch.id,
          title: '有新的访问请求',
          description: '打开访问审批查看用途与申请范围。',
        );
      }
    }
    return r == null
        ? const WorkspaceNotificationPreview()
        : WorkspaceNotificationPreview(
            requestId: r.id,
            title: '有新的访问请求',
            description: '打开访问审批查看用途与申请范围。',
          );
  });
}
