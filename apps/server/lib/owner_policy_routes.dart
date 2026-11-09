import 'package:info_core/info_core.dart' as core;
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/server_state.dart';
import 'package:info_workspace/history_transport.dart'
    show historyEnvelope, historyInt, historyText;
import 'package:info_workspace/settings_transport.dart';
import 'package:info_workspace/workspace_source.dart';

/// Shared policy uses the original Owner preference transaction and history
/// cleanup plan. This host neither reads nor changes a device's desktop choices.
final class OwnerPolicyRoutes {
  OwnerPolicyRoutes(this.owner, this.state, {Duration Function()? elapsed})
    : _elapsed = elapsed ?? _clock();
  final core.OwnerAccess owner;
  final ServerStateRepository state;
  final Duration Function() _elapsed;
  final _plans =
      <String, ({core.DesktopRetentionPlan value, Duration until})>{};
  static Duration Function() _clock() {
    final timer = Stopwatch()..start();
    return () => timer.elapsed;
  }

  void dispose() => _plans.clear();
  Future<ServerStateSnapshot> _snapshot() => state.openServerState();
  // A public comparison marker, not the private runtime generation itself.
  String _scope(ServerStateSnapshot s) => base64Url
      .encode(
        sha256.convert(utf8.encode('owner-policy-v1\n${s.generation}')).bytes,
      )
      .replaceAll('=', '');
  Map<String, Object?> _absences(ServerStateSnapshot s) {
    final raw = s.payload['ownerPolicyAbsences'];
    if (raw == null && !s.payload.containsKey('ownerPolicyAbsences')) return {};
    if (raw is! Map ||
        raw.length > 10000 ||
        raw.entries.any(
          (e) =>
              e.key is! String ||
              !RegExp(
                r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$',
              ).hasMatch(e.key as String) ||
              e.value != true,
        )) {
      throw const core.AccessFailure('invalid_policy_state');
    }
    return Map<String, Object?>.from(raw);
  }

  void _generation(ServerStateSnapshot s, String expected) {
    if (_scope(s) != expected)
      throw const WorkspaceFailure('library_changed', '资料库已替换，请重新读取设置。');
  }

  WorkspaceServerPolicy _policy(String generation, core.DesktopPreferences p) =>
      WorkspaceServerPolicy(
        generation: generation,
        version: p.version,
        requestMinutes: p.requestMinutes,
        retentionDays: p.retentionDays,
      );
  WorkspaceServerPolicyReceipt _receipt(
    String generation,
    core.DesktopPreferencesReceipt r,
  ) => WorkspaceServerPolicyReceipt(
    operationId: r.operationId,
    commandDigest: r.commandDigest,
    expectedVersion: r.expectedVersion,
    policy: _policy(generation, r.preferences),
  );

  Future<WorkspaceServerPolicyReceipt?> _query(
    String generation,
    String id,
  ) async {
    final s = await _snapshot();
    _generation(s, generation);
    final previous = await owner.desktopPreferencesReceipt(id);
    if (previous != null) return _receipt(generation, previous);
    // Settle absence before acknowledging it. A delayed old command cannot
    // arrive after this query and save settings that the user already abandoned.
    for (var attempt = 0; attempt < 8; attempt++) {
      final current = await _snapshot();
      _generation(current, generation);
      final absent = _absences(current);
      if (absent.containsKey(id)) return null;
      if (absent.length >= 10000)
        throw const WorkspaceFailure('capacity', '设置操作记录已满，无法确认未提交。');
      try {
        await state.commitServerState(current, {
          ...current.payload,
          'ownerPolicyAbsences': {...absent, id: true},
        });
        return null;
      } on core.AccessFailure catch (e) {
        if (e.status != 'server_state_changed' || attempt == 7) rethrow;
      }
    }
    throw const core.AccessFailure('server_state_changed');
  }

  Future<WorkspaceServerPolicyReceipt> _change(
    WorkspaceServerPolicyChange c,
  ) async {
    final s = await _snapshot();
    _generation(s, c.generation);
    if (_absences(s).containsKey(c.operationId))
      throw const WorkspaceFailure('not_submitted', '此原操作已确认未提交，请重新核对后明确保存。');
    final previous = await owner.desktopPreferencesReceipt(c.operationId);
    if (previous != null) {
      final r = _receipt(_scope(s), previous);
      if (!r.matches(c))
        throw const WorkspaceFailure('operation_conflict', '原操作不能保存另一份设置。');
      return r;
    }
    final current = owner.desktopPreferences;
    final plan = c.retentionToken == null
        ? null
        : _plans[c.retentionToken]?.value;
    if (c.retentionToken != null && plan == null)
      throw const WorkspaceFailure('retention_changed', '清理预览已失效，请重新核对。');
    final r = await owner.saveDesktopPreferences(
      operationId: c.operationId,
      commandDigest: c.commandDigest,
      expectedVersion: c.expectedVersion,
      desired: core.DesktopPreferences(
        version: c.expectedVersion + 1,
        dark: current.dark,
        notifications: current.notifications,
        background: current.background,
        requestMinutes: c.requestMinutes,
        retentionDays: c.retentionDays,
      ),
      retention: plan,
    );
    if (c.retentionToken != null) _plans.remove(c.retentionToken);
    return _receipt(_scope(s), r);
  }

  Future<(int, Object)> dispatch(
    String method,
    List<String> path,
    Map<String, dynamic>? body,
  ) async {
    _plans.removeWhere((_, p) => p.until <= _elapsed());
    final tail = path.skip(3).toList();
    if (method == 'GET' && tail.isEmpty)
      return (
        200,
        _policy(_scope(await _snapshot()), owner.desktopPreferences).json,
      );
    if (method == 'POST' && tail.length == 1 && tail.single == 'changes') {
      return (
        200,
        (await _change(WorkspaceServerPolicyChange.fromJson(body))).json,
      );
    }
    if (method == 'GET' && tail.length == 3 && tail.first == 'operations') {
      final r = await _query(historyText(tail[1]), policyOperationId(tail[2]));
      return r == null
          ? (404, {'error': 'operation_not_found'})
          : (200, r.json);
    }
    if (method == 'POST' &&
        tail.length == 1 &&
        tail.single == 'retention-preview') {
      final b = historyEnvelope(body, ['generation', 'days']);
      _generation(await _snapshot(), historyText(b['generation']));
      if (_plans.length >= 16)
        throw const WorkspaceFailure('capacity', '待核对的清理预览过多，请稍后重试。');
      final p = await owner.previewDesktopRetention(
        historyInt(b['days'], min: 1),
      );
      _plans[p.token] = (
        value: p,
        until: _elapsed() + const Duration(minutes: 30),
      );
      return (
        200,
        retentionPreviewToJson(
          WorkspaceRetentionPreview(
            token: p.token,
            days: p.days,
            cutoff: p.cutoff,
            requests: p.cleanup.requests,
            grants: p.cleanup.grants,
            operations: p.cleanup.operations,
            preserved: p.preserved,
          ),
        ),
      );
    }
    if (method == 'GET' &&
        tail.length == 1 &&
        tail.single == 'notification-preview') {
      final request = owner
          .queryInbox(filter: core.InboxFilter.pending)
          .entries
          .firstOrNull;
      return (
        200,
        {
          'wireVersion': 1,
          'requestId': request?.id,
          'title': request == null ? '暂无待处理申请' : '有新的访问请求',
          'description': request == null
              ? '收到新申请后，可在访问审批中查看。'
              : '打开访问审批查看用途与申请范围。',
        },
      );
    }
    return (404, {'error': 'not_found'});
  }
}
