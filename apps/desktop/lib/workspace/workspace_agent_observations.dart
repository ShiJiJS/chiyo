import 'dart:convert';
import 'package:info_cli/agent_bundle_observation.dart';
import 'package:info_workspace/agent_sessions.dart';
import 'workspace_agents.dart';
import 'workspace_approvals.dart';
import 'workspace_records.dart';

/// Combines service metadata with observations of this running App's package.
/// Neither source grants access or infers host hook installation/trust.
class WorkspaceAgentObservations implements WorkspaceAgentsSource {
  WorkspaceAgentObservations({
    required this.readSessions,
    this.readBundle,
    this.independentServer = false,
  });
  final Future<WorkspaceAgentSessions> Function() readSessions;
  final Future<AgentBundleObservation> Function({bool rehash})? readBundle;
  final bool independentServer;
  int _version = 0;
  _Observation? _current;

  Future<_Observation> _observe(
    String? selectedId,
    int version, {
    bool rehash = false,
  }) async {
    AgentBundleObservation bundle;
    try {
      bundle =
          await readBundle?.call(rehash: rehash) ??
          const AgentBundleObservation(status: 'not_observed');
    } on Object {
      bundle = const AgentBundleObservation(status: 'not_observed');
    }
    final cliReason = switch (bundle.status) {
      'verified' =>
        bundle.embedded
            ? 'App 内配套 CLI、Skill 模板和接入说明与同源清单一致。此核对不包含 App 外的 CLI 副本，不执行程序、不验证签名或网络连接，也不代表宿主已安装或信任。'
            : 'App 主程序及身份文件、配套 CLI、Skill 模板和接入说明与随包清单一致。此核对不执行程序、不验证签名或网络连接，也不代表宿主已安装或信任。',
      'not_packaged' =>
        '当前 App 不在完整交付目录中。请从保留 app、cli 和 manifest.json 的整包启动；单独复制 App 无法核对配套工具。',
      'manifest_missing' => '未找到整包清单。请恢复完整交付目录后重新检测，不要混用另一版本的 CLI。',
      'bundle_invalid' => '配套文件缺失、发生变化或与清单不一致。请恢复完整同版本交付包后重新检测。',
      _ => '尚未取得配套文件观察，无法确认 CLI 是否就绪。',
    };
    final observed = await readSessions();
    if (!observed.valid) {
      throw const WorkspaceFailure('invalid_observation', '会话观察无法确认，请重新检测。');
    }
    final available = observed.serviceAvailable;
    final sessions = observed.sessions;
    final requests = observed.requests;
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
          ? independentServer
                ? '资料服务器已连接；尚未核对 CLI 的独立连接配置及宿主安装和信任。会话列表来自服务器，统计包含资料、凭据及分类整理申请。'
                : '本机资料服务可用；尚未核对 CLI 网络连通性及宿主安装和信任。会话列表仅表示服务端关联，统计包含资料、凭据及分类整理申请。'
          : independentServer
          ? '资料服务器暂不可用或正在恢复资料，当前不能接收申请。'
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
      observed.revision,
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
  Future<WorkspaceAgentOverview> read({String? sessionId}) async {
    final next = await _observe(sessionId, ++_version);
    // Concurrent reads may finish out of order. Never replace a newer result.
    if (next.overview.version == _version) _current = next;
    return next.overview;
  }

  Future<_Observation> _checked(int version, {bool rehash = false}) async {
    final expected = _current;
    if (expected == null ||
        _version != version ||
        expected.overview.version != version) {
      throw const WorkspaceFailure('observation_changed', '会话观察已变化，请重新检测。');
    }
    final fresh = await _observe(expected.selectedId, version, rehash: rehash);
    if (_version != version ||
        !identical(expected, _current) ||
        fresh.signature != expected.signature) {
      throw const WorkspaceFailure('observation_changed', '会话状态已变化，请重新检测。');
    }
    return expected;
  }

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
