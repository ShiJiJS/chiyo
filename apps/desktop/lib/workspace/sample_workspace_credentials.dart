import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_credentials.dart';
import 'workspace_operation.dart';
import 'workspace_records.dart';

const sampleCredentialDefinition = <String, Object?>{
  'fields': <Object?>[],
  'sections': <Object?>[],
  'relations': [
    {'key': 'related', 'label': '关联资料', 'targetTemplates': <String>[]},
  ],
};

const _candidates = [
  WorkspaceCredentialCandidate(
    id: 'string-env',
    label: 'Token 字符串',
    form: WorkspaceCredentialForm.string,
    format: 'Token 字符串',
    delivery: WorkspaceCredentialDelivery.environment,
    binding: 'API_TOKEN',
  ),
  WorkspaceCredentialCandidate(
    id: 'ssh-file',
    label: 'SSH 凭据文件',
    form: WorkspaceCredentialForm.file,
    format: 'OpenSSH',
    delivery: WorkspaceCredentialDelivery.file,
    filename: 'beichen_ed25519',
    binding: 'SSH_KEY_FILE',
  ),
  WorkspaceCredentialCandidate(
    id: 'string-focus',
    label: '本机填充字符串',
    form: WorkspaceCredentialForm.string,
    format: '密码字符串',
    delivery: WorkspaceCredentialDelivery.focus,
  ),
  WorkspaceCredentialCandidate(
    id: 'session-file',
    label: '会话文件（仅保管）',
    form: WorkspaceCredentialForm.file,
    format: 'SQLite / .session',
    delivery: WorkspaceCredentialDelivery.storage,
    filename: 'beichen-client.session',
  ),
];
const _sessions = [
  WorkspaceCredentialSession('session-maintenance', '服务器维护会话', '维护 Agent（自述）'),
  WorkspaceCredentialSession('session-notes', '笔记整理会话', '资料整理 Agent（自述）'),
];

class _CredentialState {
  const _CredentialState(
    this.candidate, {
    required this.binding,
    this.note = '',
    this.version = 1,
    this.generation = 1,
    this.enabled = true,
  });
  final WorkspaceCredentialCandidate candidate;
  final String binding, note;
  final int version, generation;
  final bool enabled;
}

typedef PrepareCredentialRecord =
    WorkspaceDetail Function(
      WorkspaceRecordRef ref,
      WorkspaceCredentialWrite? write,
    );

/// Independent fictional credential state. It never stores or reads secret
/// bytes, files, database handles, process handles or system fill capabilities.
class SampleWorkspaceCredentials implements WorkspaceCredentialSource {
  SampleWorkspaceCredentials({
    required this.readable,
    required this.current,
    required this.prepareRecord,
    required this.commitRecord,
    required this.beforeWrite,
    required this.changed,
    required this.now,
  });
  final Future<void> Function() readable;
  final WorkspaceDetail Function(WorkspaceRecordRef) current;
  final PrepareCredentialRecord prepareRecord;
  final void Function(WorkspaceDetail) commitRecord;
  final void Function() beforeWrite;
  final void Function(WorkspaceRecordRef) changed;
  final DateTime Function() now;
  final _states = <WorkspaceRecordRef, _CredentialState>{},
      _initial = <WorkspaceRecordRef, _CredentialState>{};
  final _history = <WorkspaceRecordRef, List<WorkspaceCredentialUseHistory>>{};
  final _requests = <String, WorkspaceCredentialUseRequest>{};
  final _operations =
      <String, ({String fingerprint, WorkspaceCredentialReceipt receipt})>{};
  WorkspaceFailure? nextReadFailure;
  int get pendingCount => _requests.values
      .where((r) => r.state == WorkspaceCredentialRequestState.pending)
      .length;

  void seed(WorkspaceRecordRef ref, Map<String, dynamic> row) {
    final form = row['filename'] is String
        ? WorkspaceCredentialForm.file
        : WorkspaceCredentialForm.string;
    final format =
        row['format'] as String? ??
        (form == WorkspaceCredentialForm.file ? '文件' : '字符串');
    final delivery = row['delivery'] == 'focus'
        ? WorkspaceCredentialDelivery.focus
        : format.contains('SQLite')
        ? WorkspaceCredentialDelivery.storage
        : form == WorkspaceCredentialForm.file
        ? WorkspaceCredentialDelivery.file
        : WorkspaceCredentialDelivery.environment;
    final rawBinding = row['binding'] as String? ?? '';
    final binding =
        RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$').hasMatch(rawBinding)
        ? rawBinding
        : '';
    final candidate = WorkspaceCredentialCandidate(
      id: 'seed:${ref.id}',
      label: format,
      form: form,
      format: format,
      delivery: delivery,
      filename: row['filename'] as String?,
      binding: binding,
    );
    _states[ref] = _initial[ref] = _CredentialState(
      candidate,
      binding: binding,
    );
    if ([
      WorkspaceCredentialDelivery.environment,
      WorkspaceCredentialDelivery.file,
    ].contains(delivery)) {
      _history[ref] = [
        WorkspaceCredentialUseHistory(
          grantId: 'sample-grant:${ref.id}',
          credentialName: row['name'] as String,
          materialVersion: 1,
          delivery: delivery,
          session: _sessions.first,
          purpose: '维护与核对服务状态',
          expiresAt: DateTime.utc(2026, 10, 25, 10, 30),
          state: '已到期',
          operations: [
            WorkspaceCredentialUseOperation(
              'sample-use:${ref.id}:1',
              DateTime.utc(2026, 10, 25, 10, 4),
              '核对连接状态',
              '已结束',
            ),
            WorkspaceCredentialUseOperation(
              'sample-use:${ref.id}:2',
              DateTime.utc(2026, 10, 25, 10, 8),
              '查询后续服务状态',
              '失败',
            ),
          ],
        ),
      ];
    }
  }

  void clearCurrent() {
    _states.clear();
    _requests.clear();
    _operations.clear();
  }

  void clear() {
    clearCurrent();
    _initial.clear();
    _history.clear();
    nextReadFailure = null;
  }

  void reset() {
    clearCurrent();
    _states.addAll(_initial);
    nextReadFailure = null;
  }

  (_CredentialState, WorkspaceDetail) _get(WorkspaceRecordRef ref) {
    if (ref.kind != WorkspaceRecordKind.credential) {
      throw const WorkspaceFailure('unsupported', '此入口只管理托管凭据。');
    }
    final record = current(ref), state = _states[ref];
    if (state == null) throw const WorkspaceFailure('not_found', '凭据已不可用。');
    return (state, record);
  }

  WorkspaceCredentialDetail _detail(WorkspaceRecordRef ref) {
    final (state, record) = _get(ref);
    return WorkspaceCredentialDetail(
      record: record.record,
      recordVersion: record.version,
      materialVersion: state.version,
      useGeneration: state.generation,
      enabled: state.enabled,
      useSupported: [
        WorkspaceCredentialDelivery.environment,
        WorkspaceCredentialDelivery.file,
      ].contains(state.candidate.delivery),
      useUnavailableReason:
          state.candidate.delivery == WorkspaceCredentialDelivery.focus
          ? 'Mac本机焦点填充尚未启用。'
          : null,
      form: state.candidate.form,
      format: state.candidate.format,
      delivery: state.candidate.delivery,
      filename: state.candidate.filename,
      binding: state.binding,
      privateNote: state.note,
      linkedInformation: record.relations['related'] ?? [],
    );
  }

  @override
  Future<WorkspaceCredentialDetail> read(WorkspaceRecordRef ref) async {
    await readable();
    if (nextReadFailure case final failure?) {
      nextReadFailure = null;
      throw failure;
    }
    return _detail(ref);
  }

  @override
  Future<List<WorkspaceCredentialCandidate>> candidates() async {
    await readable();
    return List.unmodifiable(_candidates);
  }

  @override
  Future<void> releaseCandidate(String candidateId) async {
    // Fixed metadata-only fixtures own no secret buffer or temporary file.
  }

  String _fingerprint(Object input) =>
      sha256.convert(utf8.encode(jsonEncode(input))).toString();
  WorkspaceCredentialReceipt? _replay(String id, String fingerprint) {
    if (id.isEmpty) {
      throw const WorkspaceFailure('invalid_request', '操作身份不可为空。');
    }
    final old = _operations[id];
    if (old == null) return null;
    if (old.fingerprint != fingerprint) {
      throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同内容。');
    }
    return old.receipt;
  }

  void _expect(WorkspaceCredentialDetail detail, int? record, int? material) {
    if (detail.recordVersion != record || detail.materialVersion != material) {
      throw const WorkspaceFailure('conflict', '凭据已变化，请重新读取并核对。');
    }
  }

  void _invalidate(
    WorkspaceRecordRef ref,
    WorkspaceCredentialRequestState reason,
  ) {
    for (final e in _requests.entries.toList()) {
      if (e.value.ref == ref &&
          e.value.state == WorkspaceCredentialRequestState.pending) {
        _requests[e.key] = e.value.withState(reason);
      }
    }
  }

  @override
  Future<WorkspaceCredentialReceipt> save(
    WorkspaceCredentialWrite write,
  ) async {
    await readable();
    final fingerprint = _fingerprint({
      'kind': 'save',
      'ref': write.ref?.key,
      'record': write.expectedRecordVersion,
      'version': write.expectedMaterialVersion,
      'name': write.name,
      'purpose': write.purpose,
      'note': write.privateNote,
      'binding': write.binding,
      'candidate': write.candidateId,
      'directory': write.directoryId,
      'tags': write.tagIds,
      'links': write.linkedInformation?.map((r) => r.key).toList(),
    });
    if (_replay(write.operationId, fingerprint) case final receipt?) {
      return receipt;
    }
    final errors = <String, String>{};
    if (write.name.trim().isEmpty ||
        write.name.length > 60 ||
        write.name.contains('\u0000')) {
      errors['name'] = '请输入1–60字的名称。';
    }
    if (write.purpose.length > 2000 || write.purpose.contains('\u0000')) {
      errors['purpose'] = '用途不能超过2000字或包含空字符。';
    }
    if (write.privateNote.length > 4000 ||
        write.privateNote.contains('\u0000')) {
      errors['privateNote'] = '私有备注不能超过4000字或包含空字符。';
    }
    if (write.binding.isNotEmpty &&
        !RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$').hasMatch(write.binding)) {
      errors['binding'] = '引用名需为1–64位字母、数字或下划线，不能以数字开头。';
    }
    if (write.linkedInformation case final links?) {
      if (links.length > 200 ||
          links.toSet().length != links.length ||
          links.any((r) => r.kind != WorkspaceRecordKind.information)) {
        errors['related'] = '请选择最多200份不重复的普通资料。';
      }
    }
    if (errors.isNotEmpty) {
      throw WorkspaceFailure('validation', '请检查凭据资料。', fieldErrors: errors);
    }
    final before = write.ref == null ? null : _detail(write.ref!);
    if (before != null) {
      _expect(
        before,
        write.expectedRecordVersion,
        write.expectedMaterialVersion,
      );
    } else if (write.expectedRecordVersion != null ||
        write.expectedMaterialVersion != null) {
      throw const WorkspaceFailure('invalid_request', '新建凭据不能带已有版本。');
    }
    final candidate = write.candidateId == null
        ? null
        : _candidates.where((c) => c.id == write.candidateId).firstOrNull;
    if (write.candidateId != null && candidate == null ||
        before == null && candidate == null) {
      throw const WorkspaceFailure(
        'validation',
        '请重新选择凭据资料。',
        fieldErrors: {'candidate': '请选择可用材料。'},
      );
    }
    if (before != null && candidate != null && before.form != candidate.form) {
      throw const WorkspaceFailure('form_mismatch', '更换材料必须保持字符串或文件的原形态。');
    }
    final ref =
        write.ref ??
        WorkspaceRecordRef(
          WorkspaceRecordKind.credential,
          workspaceOperationId(),
        );
    final prepared = prepareRecord(ref, write);
    beforeWrite();
    final old = before == null ? null : _states[ref]!;
    final state = _CredentialState(
      candidate ?? old!.candidate,
      binding: write.binding,
      note: write.privateNote,
      version: before == null ? 1 : old!.version + (candidate == null ? 0 : 1),
      generation: before == null
          ? 1
          : old!.generation + (candidate == null ? 0 : 1),
      enabled: old?.enabled ?? true,
    );
    commitRecord(prepared);
    _states[ref] = state;
    if (candidate != null && before != null) {
      _invalidate(ref, WorkspaceCredentialRequestState.superseded);
    }
    final receipt = WorkspaceCredentialReceipt(
      ref,
      prepared.version,
      state.version,
    );
    _operations[write.operationId] = (
      fingerprint: fingerprint,
      receipt: receipt,
    );
    changed(ref);
    return receipt;
  }

  @override
  Future<WorkspaceCredentialReceipt> setEnabled(
    WorkspaceCredentialToggle change,
  ) async {
    await readable();
    final fingerprint = _fingerprint({
      'kind': 'enabled',
      'ref': change.ref.key,
      'record': change.expectedRecordVersion,
      'version': change.expectedMaterialVersion,
      'enabled': change.enabled,
    });
    if (_replay(change.operationId, fingerprint) case final receipt?) {
      return receipt;
    }
    final before = _detail(change.ref);
    _expect(
      before,
      change.expectedRecordVersion,
      change.expectedMaterialVersion,
    );
    final prepared = prepareRecord(change.ref, null);
    beforeWrite();
    final old = _states[change.ref]!;
    commitRecord(prepared);
    _states[change.ref] = _CredentialState(
      old.candidate,
      binding: old.binding,
      note: old.note,
      version: old.version,
      generation: old.generation + 1,
      enabled: change.enabled,
    );
    _invalidate(change.ref, WorkspaceCredentialRequestState.disabled);
    final receipt = WorkspaceCredentialReceipt(
      change.ref,
      prepared.version,
      old.version,
    );
    _operations[change.operationId] = (
      fingerprint: fingerprint,
      receipt: receipt,
    );
    changed(change.ref);
    return receipt;
  }

  @override
  Future<WorkspaceCredentialReceipt?> receipt(String operationId) async {
    await readable();
    return _operations[operationId]?.receipt;
  }

  @override
  Future<List<WorkspaceCredentialSession>> sessions() async {
    await readable();
    return List.unmodifiable(_sessions);
  }

  List<WorkspaceCredentialReceiver> _receivers(
    WorkspaceCredentialDetail detail,
  ) => !detail.canRequestUse
      ? []
      : [
          if (detail.delivery == WorkspaceCredentialDelivery.file)
            WorkspaceCredentialReceiver(
              id: 'ssh',
              label: 'SSH 维护',
              executable: '/usr/bin/ssh',
              workingDirectory: '/example/maintenance',
              arguments: [
                '-i',
                '{{${detail.binding.isEmpty ? 'SSH_KEY_FILE' : detail.binding}}}',
                '-p',
                '2222',
                'developer@tokyo.beichen.example',
              ],
              binding: detail.binding.isEmpty ? 'SSH_KEY_FILE' : detail.binding,
            )
          else
            WorkspaceCredentialReceiver(
              id: 'python',
              label: 'Python 服务工具',
              executable: '/usr/bin/python3',
              workingDirectory: '/example/service-tools',
              arguments: ['-m', 'beichen_service', 'status'],
              binding: detail.binding.isEmpty ? 'API_TOKEN' : detail.binding,
            ),
        ];
  @override
  Future<List<WorkspaceCredentialReceiver>> receivers(
    WorkspaceRecordRef ref,
  ) async {
    await readable();
    return List.unmodifiable(_receivers(_detail(ref)));
  }

  @override
  Future<WorkspaceCredentialReceipt> requestUse(
    WorkspaceCredentialUseDraft draft,
  ) async {
    await readable();
    final fingerprint = _fingerprint({
      'kind': 'request',
      'ref': draft.ref.key,
      'record': draft.expectedRecordVersion,
      'version': draft.expectedMaterialVersion,
      'generation': draft.useGeneration,
      'purpose': draft.purpose,
      'receiver': draft.receiverId,
      'session': draft.sessionId,
      'minutes': draft.minutes,
    });
    if (_replay(draft.operationId, fingerprint) case final receipt?) {
      return receipt;
    }
    final detail = _detail(draft.ref);
    _expect(detail, draft.expectedRecordVersion, draft.expectedMaterialVersion);
    if (detail.useGeneration != draft.useGeneration) {
      throw const WorkspaceFailure('conflict', '凭据使用配置已变化，请重新核对。');
    }
    if (!detail.canRequestUse) {
      throw WorkspaceFailure('unsupported', detail.unavailableReason!);
    }
    final receiver = _receivers(
      detail,
    ).where((r) => r.id == draft.receiverId).firstOrNull;
    final session = _sessions.where((s) => s.id == draft.sessionId).firstOrNull;
    if (receiver == null ||
        session == null ||
        ![15, 30].contains(draft.minutes) ||
        draft.purpose.trim().isEmpty ||
        draft.purpose.length > 2000 ||
        draft.purpose.contains('\u0000')) {
      throw const WorkspaceFailure('validation', '请核对申请会话、用途、接收器和期限。');
    }
    beforeWrite();
    final id = workspaceOperationId();
    _requests[id] = WorkspaceCredentialUseRequest(
      id: id,
      ref: draft.ref,
      credentialName: detail.record.name,
      materialVersion: detail.materialVersion,
      useGeneration: detail.useGeneration,
      delivery: detail.delivery,
      receiver: receiver,
      session: session,
      purpose: draft.purpose.trim(),
      minutes: draft.minutes,
      submittedAt: now(),
    );
    final receipt = WorkspaceCredentialReceipt(
      draft.ref,
      detail.recordVersion,
      detail.materialVersion,
      requestId: id,
    );
    _operations[draft.operationId] = (
      fingerprint: fingerprint,
      receipt: receipt,
    );
    changed(draft.ref);
    return receipt;
  }

  @override
  Future<List<WorkspaceCredentialUseRequest>> requests({
    WorkspaceRecordRef? ref,
  }) async {
    await readable();
    if (ref != null) _get(ref);
    return List.unmodifiable(
      _requests.values
          .where((r) => ref == null || r.ref == ref)
          .toList()
          .reversed,
    );
  }

  @override
  Future<List<WorkspaceCredentialUseHistory>> history(
    WorkspaceRecordRef ref,
  ) async {
    await readable();
    _get(ref);
    return List.unmodifiable(_history[ref] ?? []);
  }
}
