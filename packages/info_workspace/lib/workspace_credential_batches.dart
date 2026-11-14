import 'dart:convert';

import 'package:info_core/info_core.dart' as core;

/// Content-free owner view of a real batch operation. It never carries a
/// material proof, password, private process handle or command output.
class WorkspaceCredentialBatchOperation {
  WorkspaceCredentialBatchOperation({
    required this.requestId,
    required this.operationId,
    required this.revision,
    required Iterable<String> itemIds,
    required this.state,
    required this.createdAt,
    required this.observedAt,
    this.finishedAt,
    this.errorCode,
    this.attentionAcknowledgedAt,
    this.attentionOperationId,
    this.fromBackup = false,
    this.sshContext,
    Map<String, String> itemResults = const {},
  }) : itemIds = List.unmodifiable(itemIds),
       itemResults = Map.unmodifiable(itemResults);
  final String requestId, operationId, state;
  final int revision;
  final List<String> itemIds;
  final Map<String, String> itemResults;
  final DateTime createdAt, observedAt;
  final DateTime? finishedAt, attentionAcknowledgedAt;
  final String? errorCode, attentionOperationId;
  final bool fromBackup;
  final core.SshSessionOperationContext? sshContext;
  String get operationLabel => switch (sshContext?.kind) {
    'open' => '使用凭据登录服务器',
    'run' => '发送远程命令',
    'input' => '发送交互输入',
    'credential' => '提供 sudo 密码',
    _ => '填写凭据',
  };
  static const states = {
    'checking',
    'dispatched',
    'filled',
    'refused',
    'partial',
    'failed',
    'unknown',
  };
  static const results = {
    'filled',
    'sent',
    'refused',
    'failed',
    'unknown',
    'not_attempted',
  };
  bool get needsAttention =>
      !fromBackup &&
      attentionAcknowledgedAt == null &&
      {'partial', 'unknown'}.contains(state);
  static String resultLabel(String state) => switch (state) {
    'checking' => '正在核对目标',
    'dispatched' => '已发送填写，结果待确认',
    'sent' => '已向所选控件送入密码',
    'filled' => '已填写',
    'refused' || 'not_attempted' => '未填写',
    'partial' => '部分完成',
    'failed' => '填写失败',
    _ => '填写结果未知',
  };
  String itemResultLabel(String result) {
    if (sshContext == null) return resultLabel(result);
    return switch (result) {
      'checking' => '正在检查许可',
      'dispatched' => '正在处理，结果待确认',
      'sent' || 'filled' => switch (sshContext!.kind) {
        'open' => '凭据已交给连接程序',
        'credential' => '密码已发送',
        'input' => '输入已发送',
        _ => '命令已发送',
      },
      'refused' || 'not_attempted' => '未发送',
      'failed' => '操作失败',
      'partial' => '部分完成',
      _ => '操作结果尚未确认',
    };
  }

  String get summaryLabel => sshContext != null
      ? itemResultLabel(state)
      : state == 'filled' &&
            itemResults.isNotEmpty &&
            itemResults.values.any((result) => result == 'sent')
      ? resultLabel('sent')
      : resultLabel(state);
  String? get errorLabel => sshContext != null
      ? switch (errorCode) {
          null => null,
          'grant_revoked' => '许可已撤销，不能继续发送。',
          'grant_expired' => '使用期限已到。',
          'credential_version_changed' => '凭据已更新，需要重新申请。',
          'credential_disabled' || 'credential_deleted' => '凭据已不可用。',
          'session_lost' || 'session_closed' => 'SSH 连接已断开或关闭。',
          'stale_run' || 'stale_receiver' => '原命令或密码接收程序已结束，未继续发送。',
          'execution_unknown' => '尚不能确认原操作的结果，请刷新状态。',
          _ => '本次操作未能确认完成，请查看原连接的状态。',
        }
      : switch (errorCode) {
          null => null,
          'target_unavailable' ||
          'application_changed' ||
          'destination_changed' ||
          'form_changed' ||
          'focus_changed' => '填写目标已变化。',
          'grant_revoked' ||
          'credential_disabled' ||
          'credential_deleted' => '许可或凭据已失效。',
          'grant_expired' => '使用期限已到。',
          'credential_version_changed' => '凭据已更新，需要重新申请。',
          'permission_required' => '这台电脑尚未允许此填写方式。',
          'browser_unavailable' || 'unavailable_target' => '浏览器或目标密码框不可用。',
          'unsupported_control' ||
          'unsupported_family' ||
          'unsupported_provider' ||
          'unsupported_target' ||
          'not_password_field' => '此目标不支持密码填写。',
          'ambiguous_form' || 'ambiguous_field' => '无法确定唯一的表单或密码框。',
          'fill_unknown' ||
          'execution_unknown' ||
          'fill_needs_attention' => '结果尚未确认，请核对目标和原操作。',
          _ => '本次填写未能完成。',
        };
  bool get valid =>
      revision > 0 &&
      states.contains(state) &&
      itemIds.isNotEmpty &&
      itemIds.length <= 20 &&
      itemIds.toSet().length == itemIds.length &&
      itemIds.every((id) => RegExp(r'^b(?:[1-9]|1[0-9]|20)$').hasMatch(id)) &&
      itemResults.keys.every(itemIds.contains) &&
      itemResults.values.every(results.contains) &&
      (!{'checking', 'dispatched'}.contains(state) || finishedAt == null) &&
      ({'checking', 'dispatched', 'unknown'}.contains(state) ||
          finishedAt != null) &&
      (state != 'filled' ||
          itemResults.length == itemIds.length &&
              itemResults.values.every((s) => s == 'filled' || s == 'sent')) &&
      !observedAt.isBefore(createdAt) &&
      (finishedAt == null || !finishedAt!.isBefore(createdAt)) &&
      (attentionAcknowledgedAt == null ||
          !attentionAcknowledgedAt!.isBefore(createdAt)) &&
      (attentionAcknowledgedAt == null) == (attentionOperationId == null) &&
      (attentionAcknowledgedAt == null ||
          {'partial', 'unknown'}.contains(state));
  bool updates(WorkspaceCredentialBatchOperation old) =>
      valid &&
      requestId == old.requestId &&
      operationId == old.operationId &&
      createdAt == old.createdAt &&
      fromBackup == old.fromBackup &&
      jsonEncode(sshContext?.toJson()) ==
          jsonEncode(old.sshContext?.toJson()) &&
      itemIds.length == old.itemIds.length &&
      itemIds.every(old.itemIds.contains) &&
      !observedAt.isBefore(old.observedAt) &&
      (old.attentionAcknowledgedAt == null ||
          attentionAcknowledgedAt == old.attentionAcknowledgedAt &&
              attentionOperationId == old.attentionOperationId &&
              state == old.state &&
              finishedAt == old.finishedAt &&
              errorCode == old.errorCode &&
              _sameResults(old)) &&
      (revision > old.revision ||
          revision == old.revision &&
              (state == old.state &&
                      finishedAt == old.finishedAt &&
                      errorCode == old.errorCode &&
                      attentionAcknowledgedAt == old.attentionAcknowledgedAt &&
                      attentionOperationId == old.attentionOperationId &&
                      _sameResults(old) ||
                  {'checking', 'dispatched'}.contains(old.state) &&
                      state == 'unknown' &&
                      errorCode == 'execution_unknown' &&
                      finishedAt == old.finishedAt &&
                      attentionAcknowledgedAt == null &&
                      attentionOperationId == null &&
                      _sameResults(old)));
  bool _sameResults(WorkspaceCredentialBatchOperation old) =>
      itemResults.length == old.itemResults.length &&
      itemResults.entries.every((e) => old.itemResults[e.key] == e.value);
  Map<String, Object?> toJson() => {
    'status': 'ok',
    'requestId': requestId,
    'operationId': operationId,
    'revision': revision,
    'itemIds': itemIds,
    'executionState': state,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'observedAt': observedAt.toUtc().toIso8601String(),
    'finishedAt': finishedAt?.toUtc().toIso8601String(),
    'itemResults': itemResults,
    'errorCode': errorCode,
    'attentionAcknowledgedAt': attentionAcknowledgedAt
        ?.toUtc()
        .toIso8601String(),
    'attentionOperationId': attentionOperationId,
    'fromBackup': fromBackup,
    if (sshContext != null) 'sshContext': sshContext!.toJson(),
  };
  factory WorkspaceCredentialBatchOperation.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json.keys.any(
          (k) => !{
            'status',
            'requestId',
            'operationId',
            'revision',
            'itemIds',
            'executionState',
            'createdAt',
            'observedAt',
            'finishedAt',
            'itemResults',
            'errorCode',
            'attentionAcknowledgedAt',
            'attentionOperationId',
            'fromBackup',
            'sshContext',
          }.contains(k),
        ) ||
        json['status'] != 'ok') {
      throw const FormatException('Invalid batch metadata');
    }
    String id(Object? value) {
      if (value is! String ||
          value.isEmpty ||
          value.length > 200 ||
          value.contains(RegExp(r'[\x00-\x20\x7f]'))) {
        throw const FormatException('Invalid batch id');
      }
      return value;
    }

    final op = id(json['operationId']);
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(op)) {
      throw const FormatException('Invalid operation');
    }
    final result = WorkspaceCredentialBatchOperation(
      requestId: id(json['requestId']),
      operationId: op,
      revision: json['revision'] as int,
      itemIds: (json['itemIds'] as List).cast<String>(),
      state: json['executionState'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      observedAt: DateTime.parse(json['observedAt'] as String).toUtc(),
      finishedAt: json['finishedAt'] == null
          ? null
          : DateTime.parse(json['finishedAt'] as String).toUtc(),
      attentionAcknowledgedAt: json['attentionAcknowledgedAt'] == null
          ? null
          : DateTime.parse(json['attentionAcknowledgedAt'] as String).toUtc(),
      attentionOperationId: json['attentionOperationId'] == null
          ? null
          : id(json['attentionOperationId']),
      errorCode: json['errorCode'] as String?,
      fromBackup: json['fromBackup'] as bool,
      sshContext: json['sshContext'] == null
          ? null
          : core.SshSessionOperationContext.fromJson(
              Map<String, dynamic>.from(json['sshContext'] as Map),
            ),
      itemResults: Map<String, String>.from(json['itemResults'] as Map),
    );
    if (!result.valid ||
        result.errorCode != null &&
            !RegExp(r'^[a-z_]{1,80}$').hasMatch(result.errorCode!)) {
      throw const FormatException('Invalid batch observation');
    }
    return result;
  }
}

class WorkspaceCredentialBatchAcknowledgement {
  const WorkspaceCredentialBatchAcknowledgement({
    required this.requestId,
    required this.operationId,
    required this.ownerOperationId,
    required this.revision,
  });
  final String requestId, operationId, ownerOperationId;
  final int revision;
}

abstract interface class WorkspaceCredentialBatchActions {
  Future<WorkspaceCredentialBatchOperation> batchOperation(
    String requestId,
    String operationId,
  );
  Future<WorkspaceCredentialBatchOperation> acknowledgeBatchOperation(
    WorkspaceCredentialBatchAcknowledgement change,
  );
}
