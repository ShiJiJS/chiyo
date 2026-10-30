import 'dart:convert';
import 'package:info_core/info_core.dart' as core;
import 'package:info_cli/macos_agent_bundle.dart';
import 'owner_workspace_approvals.dart';
import 'workspace_agents.dart';
import 'workspace_approvals.dart';
import 'workspace_records.dart';

/// Read-only service observations. No private association files, transcripts,
/// global configuration or trust stores are searched to infer the active chat.
class OwnerWorkspaceAgents implements WorkspaceAgentsSource {
  OwnerWorkspaceAgents({required this.owner, this.readBundle})
    : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final Future<MacAgentBundleObservation> Function({bool rehash})? readBundle;
  final core.OwnerLibraryScope _scope;
  int _version = 0;
  _Observation? _current;

  Future<T> _read<T>(Future<T> Function() action) async {
    try {
      return await owner.inLibraryScope(_scope, action);
    } on core.AccessFailure catch (e) {
      throw WorkspaceFailure(
        e.status,
        e.status == 'library_changed'
            ? '资料库已替换，请重新打开接入页面。'
            : '会话观察暂时不可用，请重新检测。',
      );
    }
  }

  Future<_Observation> _observe(
    String? selectedId,
    int version, {
    bool rehash = false,
  }) async {
    MacAgentBundleObservation bundle;
    try {
      bundle =
          await readBundle?.call(rehash: rehash) ??
          const MacAgentBundleObservation(status: 'not_observed');
    } on Object {
      bundle = const MacAgentBundleObservation(status: 'not_observed');
    }
    final cliReason = switch (bundle.status) {
      'verified' =>
        'App 主程序及身份文件、配套 CLI、Skill 模板和接入说明与随包清单一致。此核对不执行程序、不验证签名或网络连接，也不代表宿主已安装或信任。',
      'not_packaged' =>
        '当前 App 不在完整交付目录中。请从保留 app、cli 和 manifest.json 的整包启动；单独复制 App 无法核对配套工具。',
      'manifest_missing' => '未找到整包清单。请恢复完整交付目录后重新检测，不要混用另一版本的 CLI。',
      'bundle_invalid' => '配套文件缺失、发生变化或与清单不一致。请恢复完整同版本交付包后重新检测。',
      _ => '尚未取得配套文件观察，无法确认 CLI 是否就绪。',
    };
    final available = owner.serviceAvailable;
    final requests = available
        ? (await owner.informationRequestInbox())
              .map(OwnerWorkspaceApprovals.summaryOf)
              .toList()
        : <WorkspaceApprovalSummary>[];
    // Read live associations after the asynchronous history query, including
    // empty sessions. Historical associations cannot revive old capabilities.
    final live = available ? owner.sessions : <core.OwnerSessionSnapshot>[];
    final ids = {...live.map((s) => s.id), ...requests.map((r) => r.sessionId)};
    final sessions = <WorkspaceAgentSession>[];
    for (final id in ids) {
      final association = live.where((s) => s.id == id).firstOrNull;
      final rows = requests.where((r) => r.sessionId == id).toList();
      final ended = association == null || association.ended;
      sessions.add(
        WorkspaceAgentSession(
          state: ended
              ? WorkspaceAgentSessionState.ended
              : WorkspaceAgentSessionState.linked,
          id: id,
          label: association?.chatLabel ?? rows.first.chatClaim,
          totalRequests: rows.length,
          pendingRequests: ended
              ? 0
              : rows
                    .where((r) => r.state == WorkspaceApprovalState.pending)
                    .length,
          activeGrants: ended
              ? 0
              : rows
                    .where((r) => r.state == WorkspaceApprovalState.approved)
                    .length,
        ),
      );
    }
    sessions.sort((a, b) => a.id!.compareTo(b.id!));
    requests.sort((a, b) {
      final time = b.submittedAt.compareTo(a.submittedAt);
      return time != 0 ? time : a.id.compareTo(b.id);
    });
    final selected =
        sessions.where((s) => s.id == selectedId).firstOrNull ??
        WorkspaceAgentSession(
          state: selectedId == null
              ? WorkspaceAgentSessionState.unselected
              : WorkspaceAgentSessionState.missing,
          totalRequests: 0,
          pendingRequests: 0,
          activeGrants: 0,
        );
    final overview = WorkspaceAgentOverview(
      version: version,
      observedAt: DateTime.now().toUtc(),
      serviceAvailable: available,
      serviceReason: available
          ? '本机资料服务可用；尚未核对 CLI 网络连通性及宿主安装和信任。会话列表仅表示服务端关联，统计仅包含普通资料申请。'
          : '本机资料服务已关闭或正在恢复资料，当前不能接收申请。',
      cli: bundle.verified
          ? WorkspaceAgentCheck.ready
          : WorkspaceAgentCheck.unavailable,
      cliReason: cliReason,
      packageDirectory: bundle.verified ? bundle.directory : null,
      packageCommit: bundle.verified ? bundle.sourceCommit : null,
      packageDigest: bundle.verified ? bundle.manifestDigest : null,
      skill: WorkspaceAgentCheck.unavailable,
      hooks: const [],
      session: selected,
      sessions: sessions,
    );
    final signature = jsonEncode([
      available,
      bundle.status,
      bundle.directory,
      bundle.sourceCommit,
      bundle.manifestDigest,
      selectedId,
      selected.json,
      for (final s in sessions) s.json,
      for (final r in requests)
        [
          r.id,
          r.sessionId,
          r.chatClaim,
          r.purpose,
          r.state.name,
          r.submittedAt.toIso8601String(),
          r.requestExpiresAt.toIso8601String(),
        ],
    ]);
    return _Observation(overview, requests, signature, selectedId);
  }

  @override
  Future<WorkspaceAgentOverview> read({String? sessionId}) => _read(() async {
    final next = await _observe(sessionId, ++_version);
    // Concurrent reads may finish out of order. Never replace a newer result.
    if (next.overview.version == _version) _current = next;
    return next.overview;
  });

  Future<_Observation> _checked(int version, {bool rehash = false}) =>
      _read(() async {
        final expected = _current;
        if (expected == null ||
            _version != version ||
            expected.overview.version != version) {
          throw const WorkspaceFailure('observation_changed', '会话观察已变化，请重新检测。');
        }
        final fresh = await _observe(
          expected.selectedId,
          version,
          rehash: rehash,
        );
        if (_version != version ||
            !identical(expected, _current) ||
            fresh.signature != expected.signature) {
          throw const WorkspaceFailure('observation_changed', '会话状态已变化，请重新检测。');
        }
        return expected;
      });

  @override
  Future<WorkspaceAgentOverview> diagnose(int expectedVersion) async =>
      (await _checked(expectedVersion, rehash: true)).overview;

  @override
  Future<WorkspaceAgentSessionDetail> currentSession(
    int expectedVersion,
  ) async {
    final current = await _checked(expectedVersion);
    return WorkspaceAgentSessionDetail(
      overviewFingerprint: current.overview.fingerprint,
      session: current.overview.session,
      requests: current.requests.where(
        (r) => r.sessionId == current.overview.session.id,
      ),
    );
  }
}

class _Observation {
  _Observation(this.overview, this.requests, this.signature, this.selectedId);
  final WorkspaceAgentOverview overview;
  final List<WorkspaceApprovalSummary> requests;
  final String signature;
  final String? selectedId;
}
