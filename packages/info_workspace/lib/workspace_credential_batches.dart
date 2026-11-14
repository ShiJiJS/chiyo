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
    'dispatched' || 'sent' => '已发送填写，结果待确认',
    'filled' => '已填写',
    'refused' || 'not_attempted' => '未填写',
    'partial' => '部分完成',
    'failed' => '填写失败',
    _ => '填写结果未知',
  };
  String get summaryLabel =>
      state == 'filled' &&
          itemResults.isNotEmpty &&
          itemResults.values.any((result) => result == 'sent')
      ? resultLabel('sent')
      : resultLabel(state);
  String? get errorLabel => switch (errorCode) {
    null => null,
    'destination_changed' || 'form_changed' || 'focus_changed' => '填写目标已变化。',
    'grant_revoked' ||
    'credential_disabled' ||
    'credential_deleted' => '许可或凭据已失效。',
    'grant_expired' => '使用期限已到。',
    'credential_version_changed' => '凭据已更新，需要重新申请。',
    'permission_required' => '这台电脑尚未允许此填写方式。',
    'browser_unavailable' || 'unavailable_target' => '浏览器或目标密码框不可用。',
    'unsupported_target' || 'not_password_field' => '此目标不支持密码填写。',
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
