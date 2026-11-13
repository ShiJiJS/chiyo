import 'package:info_core/info_core.dart' as core;

/// Public program description only. Reuses the same strict, portable plan
/// parser as the CLI; no filesystem probe, material or process handle is kept.
class WorkspaceCredentialProgramPlan {
  const WorkspaceCredentialProgramPlan._(this._plan);
  final core.CredentialProgramPlan _plan;
  factory WorkspaceCredentialProgramPlan.fromJson(Map<String, dynamic> value) =>
      WorkspaceCredentialProgramPlan._(
        core.CredentialProgramPlan.fromPreparedJson(value),
      );
  Map<String, Object?> toJson() => _plan.toJson();
  String get fingerprint => _plan.planHash;
  String get executable => _plan.path;
  String get workingDirectory => _plan.cwd;
  int get bindingCount => _plan.bindings.length;
  bool get requiresManagedFiles => _plan.bindings.any((b) => b.via == 'file');
  String _value(core.CredentialProgramValue value, Map<String, String> names) =>
      value.kind == core.CredentialProgramValueKind.literal
      ? value.literal!
      : '${value.kind == core.CredentialProgramValueKind.file ? '文件：' : ''}${names[value.reference!.credentialId] ?? '凭据'}（第${value.reference!.version}版）';
  List<String> arguments(Map<String, String> names) =>
      _plan.argv.map((value) => _value(value, names)).toList();
  Map<String, String> environment(Map<String, String> names) => {
    for (final entry in _plan.env.entries)
      entry.key: _value(entry.value, names),
  };
  String? standardInput(Map<String, String> names) =>
      _plan.stdin == null ? null : _value(_plan.stdin!, names);

  bool matchesScope(String itemId, String credentialId, int version) {
    final index = int.tryParse(itemId.replaceFirst('b', ''));
    if (index == null || index < 1 || index > bindingCount) return false;
    final reference = _plan.bindings[index - 1].reference;
    return reference.credentialId == credentialId &&
        reference.version == version;
  }

  bool accepts(WorkspaceCredentialProgramPlan other, List<String> itemIds) {
    try {
      other._plan.requireApprovedScope(_plan);
    } on core.CredentialUseFailure {
      return false;
    }
    if (itemIds.length != other.bindingCount) return false;
    for (var i = 0; i < itemIds.length; i++) {
      final index = int.tryParse(itemIds[i].replaceFirst('b', ''));
      if (index == null ||
          index < 1 ||
          index > bindingCount ||
          _plan.bindings[index - 1].fingerprint !=
              other._plan.bindings[i].fingerprint) {
        return false;
      }
    }
    return true;
  }
}

/// One real launch using several fixed receivers. Output, internal execution
/// proof, PID, job and managed paths intentionally do not cross into the App.
class WorkspaceCredentialProgramOperation {
  WorkspaceCredentialProgramOperation({
    required this.requestId,
    required this.operationId,
    required this.revision,
    required this.plan,
    required Iterable<String> itemIds,
    required this.state,
    required this.createdAt,
    required this.observedAt,
    required this.processStarted,
    required this.cleanup,
    this.startedAt,
    this.finishedAt,
    this.exitCode,
    this.errorCode,
    this.fromBackup = false,
  }) : itemIds = List.unmodifiable(itemIds);
  final String requestId, operationId, state, cleanup;
  final int revision;
  final WorkspaceCredentialProgramPlan plan;
  final List<String> itemIds;
  final DateTime createdAt, observedAt;
  final DateTime? startedAt, finishedAt;
  final bool processStarted, fromBackup;
  final int? exitCode;
  final String? errorCode;
  static const states = {
    'preparing',
    'running',
    'exited',
    'prepare_failed',
    'start_failed',
    'unknown',
  };
  static String stateLabel(String state, [int? exitCode]) => switch (state) {
    'preparing' => '准备中',
    'running' => '运行中',
    'exited' => '已结束 · 退出码 ${exitCode ?? '未知'}',
    'prepare_failed' => '准备失败，未启动',
    'start_failed' => '未能启动',
    _ => '执行结果未知',
  };
  String get resultLabel => stateLabel(state, exitCode);
  String get processLabel => processStarted
      ? state == 'exited' || cleanup == 'complete'
            ? '程序已结束'
            : '程序已启动'
      : state == 'unknown'
      ? '是否启动尚未确认'
      : '程序未启动';
  String get cleanupLabel => switch (cleanup) {
    'not_needed' => '无受管文件',
    'complete' => '受管文件已清理',
    'failed' => '受管文件清理失败',
    _ => '受管文件待清理',
  };
  String? get errorLabel => switch (errorCode) {
    null => null,
    'execution_unknown' => '尚不能确认原程序的结果，请查询原操作，不要重跑。',
    'executable_changed' => '程序文件已变化，本次未启动。',
    'grant_revoked' ||
    'credential_disabled' ||
    'credential_deleted' => '许可或凭据已失效。',
    'grant_expired' => '使用期限已到。',
    'credential_version_changed' => '凭据已更新，需要重新申请。',
    'material_prepare_failed' => '凭据材料未准备成功，本次未启动。',
    'process_start_failed' => '程序未能启动。',
    _ => '执行或结果记录未能完成，请核对原操作。',
  };
  bool get valid =>
      revision > 0 &&
      states.contains(state) &&
      {'not_needed', 'pending', 'complete', 'failed'}.contains(cleanup) &&
      itemIds.isNotEmpty &&
      itemIds.length == plan.bindingCount &&
      itemIds.toSet().length == itemIds.length &&
      itemIds.every((id) => RegExp(r'^b(?:[1-9]|1[0-9]|20)$').hasMatch(id)) &&
      !observedAt.isBefore(createdAt) &&
      (startedAt == null || !startedAt!.isBefore(createdAt)) &&
      (finishedAt == null || !finishedAt!.isBefore(startedAt ?? createdAt)) &&
      (processStarted == (startedAt != null)) &&
      (state != 'preparing' || !processStarted && finishedAt == null) &&
      (state != 'running' || processStarted && finishedAt == null) &&
      (!{'running', 'preparing'}.contains(state) || cleanup != 'complete') &&
      (!{'prepare_failed', 'start_failed'}.contains(state) ||
          !processStarted && finishedAt != null) &&
      (state == 'exited'
          ? processStarted && finishedAt != null && exitCode != null
          : exitCode == null) &&
      (errorCode == null || RegExp(r'^[a-z_]{1,80}$').hasMatch(errorCode!));
  bool _sameProgress(WorkspaceCredentialProgramOperation old) =>
      processStarted == old.processStarted &&
      startedAt == old.startedAt &&
      finishedAt == old.finishedAt &&
      exitCode == old.exitCode &&
      cleanup == old.cleanup;
  bool updates(WorkspaceCredentialProgramOperation old) =>
      valid &&
      requestId == old.requestId &&
      operationId == old.operationId &&
      createdAt == old.createdAt &&
      fromBackup == old.fromBackup &&
      plan.fingerprint == old.plan.fingerprint &&
      itemIds.join(',') == old.itemIds.join(',') &&
      !observedAt.isBefore(old.observedAt) &&
      (revision > old.revision &&
              (!old.processStarted ||
                  processStarted && startedAt == old.startedAt) &&
              (!{
                    'exited',
                    'prepare_failed',
                    'start_failed',
                  }.contains(old.state) ||
                  state == old.state &&
                      finishedAt == old.finishedAt &&
                      exitCode == old.exitCode &&
                      errorCode == old.errorCode) &&
              (old.cleanup != 'complete' || cleanup == 'complete') ||
          revision == old.revision &&
              _sameProgress(old) &&
              (state == old.state && errorCode == old.errorCode ||
                  old.state == 'preparing' &&
                      state == 'unknown' &&
                      errorCode == 'execution_unknown' &&
                      !observedAt.isBefore(
                        createdAt.add(const Duration(seconds: 30)),
                      )));
  Map<String, Object?> toJson() => {
    'kind': 'program',
    'requestId': requestId,
    'operationId': operationId,
    'revision': revision,
    'programPlan': plan.toJson(),
    'itemIds': itemIds,
    'executionState': state,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'observedAt': observedAt.toUtc().toIso8601String(),
    'startedAt': startedAt?.toUtc().toIso8601String(),
    'finishedAt': finishedAt?.toUtc().toIso8601String(),
    'processStarted': processStarted,
    'cleanupState': cleanup,
    'exitCode': exitCode,
    'errorCode': errorCode,
    'fromBackup': fromBackup,
  };
  factory WorkspaceCredentialProgramOperation.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json.length != 16 ||
        json['kind'] != 'program' ||
        json.keys.any(
          (key) => !{
            'kind',
            'requestId',
            'operationId',
            'revision',
            'programPlan',
            'itemIds',
            'executionState',
            'createdAt',
            'observedAt',
            'startedAt',
            'finishedAt',
            'processStarted',
            'cleanupState',
            'exitCode',
            'errorCode',
            'fromBackup',
          }.contains(key),
        )) {
      throw const FormatException('Invalid program metadata');
    }
    String id(String key) {
      final value = json[key];
      if (value is! String ||
          value.isEmpty ||
          value.length > 200 ||
          value.contains(RegExp(r'[\x00-\x20\x7f]'))) {
        throw const FormatException('Invalid program id');
      }
      return value;
    }

    DateTime? date(String key) =>
        json[key] == null ? null : DateTime.parse(json[key] as String).toUtc();
    final result = WorkspaceCredentialProgramOperation(
      requestId: id('requestId'),
      operationId: id('operationId'),
      revision: json['revision'] as int,
      plan: WorkspaceCredentialProgramPlan.fromJson(
        Map<String, dynamic>.from(json['programPlan'] as Map),
      ),
      itemIds: (json['itemIds'] as List).cast<String>(),
      state: json['executionState'] as String,
      createdAt: date('createdAt')!,
      observedAt: date('observedAt')!,
      startedAt: date('startedAt'),
      finishedAt: date('finishedAt'),
      processStarted: json['processStarted'] as bool,
      cleanup: json['cleanupState'] as String,
      exitCode: json['exitCode'] as int?,
      errorCode: json['errorCode'] as String?,
      fromBackup: json['fromBackup'] as bool,
    );
    if (!result.valid ||
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
        ).hasMatch(result.operationId)) {
      throw const FormatException('Invalid program observation');
    }
    return result;
  }
}

abstract interface class WorkspaceCredentialProgramActions {
  Future<WorkspaceCredentialProgramOperation> programOperation(
    String requestId,
    String operationId,
  );
}
