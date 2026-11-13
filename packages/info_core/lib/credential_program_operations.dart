part of 'info_core.dart';

/// One real program launch, not a series of independent single-credential
/// launches. The existing process progress schema is composed as metadata;
/// this record is never admitted to the old single-credential request store.
class CredentialProgramOperation {
  CredentialProgramOperation({
    required this.sessionBinding,
    required this.deviceId,
    required this.plan,
    required this.progress,
    required Iterable<String> itemIds,
    this.revision = 1,
    this.archived = false,
  }) : itemIds = List.unmodifiable(itemIds);
  final String sessionBinding, deviceId;
  final CredentialProgramPlan plan;
  final CredentialExecution progress;
  final List<String> itemIds;
  final int revision;
  final bool archived;
  String get id => progress.id;
  String get requestId => progress.requestId;
  String get operationId => progress.operationId!;
  String get fingerprint => progress.operationFingerprint!;
  String get immutableFingerprint => _useFingerprint({
    'sessionBinding': sessionBinding,
    'deviceId': deviceId,
    'id': id,
    'requestId': requestId,
    'operationId': operationId,
    'fingerprint': fingerprint,
    'createdAt': _useTimestamp(progress.createdAt),
    'jobName': progress.jobName,
    'plan': plan.toJson(),
    'itemIds': itemIds,
  });
  Map<String, Object?> toPublicJson() => {
    ...progress.toJson(),
    'protocolVersion': 3,
    'kind': 'program',
    'revision': revision,
    'itemIds': itemIds,
    'fromBackup': archived,
  };
  Map<String, Object?> toStorageJson() => {
    'version': 1,
    'sessionBinding': sessionBinding,
    'deviceId': deviceId,
    'revision': revision,
    'archived': archived,
    'plan': plan.toJson(),
    'itemIds': itemIds,
    'progress': progress.toStorageJson(),
  };
  CredentialProgramOperation withProgress(CredentialExecution value) =>
      CredentialProgramOperation.fromStorageJson({
        ...toStorageJson(),
        'revision': revision + 1,
        'progress': value.toStorageJson(),
      });
  CredentialProgramOperation withReport(CredentialExecutionReport report) {
    if (archived) throw const CredentialUseFailure('scope_not_approved');
    final changes = _credentialExecutionReportChanges(progress, report);
    return changes == null ? this : withProgress(progress.changed(changes));
  }

  Map<String, Object?> toArchiveJson() => {
    ...toStorageJson(),
    'archived': true,
    'progress': {
      ...progress.toArchiveJson(),
      if ({'preparing', 'running'}.contains(progress.state)) ...{
        'executionState': 'unknown',
        'errorCode': 'execution_unknown',
      },
    },
  };

  factory CredentialProgramOperation.fromStorageJson(
    Map<String, dynamic> json,
  ) {
    _useShape(json, {
      'version',
      'sessionBinding',
      'deviceId',
      'revision',
      'plan',
      'itemIds',
      'progress',
      'archived',
    });
    if (json['version'] != 1 ||
        json['archived'] is! bool ||
        json['revision'] is! int ||
        (json['revision'] as int) < 1 ||
        json['itemIds'] is! List ||
        json['plan'] is! Map<String, dynamic> ||
        json['progress'] is! Map<String, dynamic> ||
        !RegExp(
          r'^[A-Za-z0-9_-]{22}$',
        ).hasMatch(json['deviceId'] as String? ?? '')) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final raw = json['progress'] as Map<String, dynamic>;
    _batchDate(raw['createdAt']);
    for (final key in ['startedAt', 'finishedAt']) {
      _batchDate(raw[key], optional: true);
    }
    if (raw.keys.any(
      (k) => !{
        'protocolVersion',
        'operationId',
        'createdAt',
        'status',
        'executionId',
        'requestId',
        'executionState',
        'operationClaimed',
        'processStarted',
        'exitCode',
        'errorCode',
        'startedAt',
        'finishedAt',
        'cleanupState',
        'outputAvailable',
        'outputTruncated',
        'operationFingerprint',
        'pid',
        'processCreatedAt',
        'materialLease',
        'jobName',
        'supervisorPid',
        'supervisorCreatedAt',
        'workerPid',
        'workerCreatedAt',
      }.contains(k),
    )) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final plan = CredentialProgramPlan.fromPreparedJson(
      json['plan'] as Map<String, dynamic>,
    );
    final p = CredentialExecution.fromJson(raw);
    final ids = (json['itemIds'] as List).cast<String>();
    final started = p.processStarted;
    final archived = json['archived'] as bool;
    if (p.protocolVersion != 2 ||
        p.createdAt == null ||
        p.operationPlan != null ||
        p.restoredAt != null ||
        !RegExp(
          r'^sha256:[0-9a-f]{64}$',
        ).hasMatch(p.operationFingerprint ?? '') ||
        (!archived &&
            (p.jobName == null ||
                !_DeviceCredentialExecution.validJob(p.jobName!))) ||
        archived &&
            (p.jobName != null ||
                p.materialLease != null ||
                p.pid != null ||
                p.processCreatedAt != null ||
                p.workerPid != null ||
                p.supervisorPid != null ||
                {'preparing', 'running'}.contains(p.state)) ||
        !{
          'preparing',
          'running',
          'exited',
          'prepare_failed',
          'start_failed',
          'unknown',
        }.contains(p.state) ||
        !{
          'not_needed',
          'pending',
          'complete',
          'failed',
          'busy',
        }.contains(p.cleanupState) ||
        plan.bindings.any((b) => b.reference.version == null) ||
        ids.isEmpty ||
        ids.length != plan.bindings.length ||
        ids.toSet().length != ids.length ||
        ids.any((id) => !RegExp(r'^b(?:[1-9]|1[0-9]|20)$').hasMatch(id)) ||
        (archived
            ? started != (p.startedAt != null)
            : started
            ? p.pid == null ||
                  p.pid! < 1 ||
                  p.processCreatedAt == null ||
                  p.processCreatedAt!.isEmpty ||
                  p.startedAt == null
            : p.pid != null ||
                  p.processCreatedAt != null ||
                  p.startedAt != null) ||
        (p.workerPid == null) != (p.workerCreatedAt == null) ||
        (p.supervisorPid == null) != (p.supervisorCreatedAt == null) ||
        {'running', 'exited'}.contains(p.state) && !started ||
        {'preparing', 'prepare_failed', 'start_failed'}.contains(p.state) &&
            started ||
        {'preparing', 'running'}.contains(p.state) && p.finishedAt != null ||
        {'exited', 'prepare_failed', 'start_failed'}.contains(p.state) &&
            p.finishedAt == null ||
        (p.state == 'exited') != (p.exitCode != null) ||
        p.startedAt != null && p.startedAt!.isBefore(p.createdAt!) ||
        p.finishedAt != null &&
            p.finishedAt!.isBefore(p.startedAt ?? p.createdAt!) ||
        p.errorCode != null &&
            !{
              'material_prepare_failed',
              'material_claim_failed',
              'executable_changed',
              'process_start_failed',
              'execution_unknown',
              'audit_unavailable',
            }.contains(p.errorCode)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    _useId(p.id, 'executionId');
    _useId(p.requestId, 'requestId');
    _batchOperationId(p.operationId);
    return CredentialProgramOperation(
      sessionBinding: _useId(json['sessionBinding'], 'sessionBinding'),
      deviceId: json['deviceId'] as String,
      plan: plan,
      progress: p,
      itemIds: ids,
      revision: json['revision'] as int,
      archived: archived,
    );
  }
}

abstract interface class CredentialProgramRepository {
  List<CredentialProgramOperation> get credentialProgramOperations;
  Future<void> commitCredentialProgramOperation(
    CredentialProgramOperation operation, {
    required int expectedRevision,
    required int requestRevision,
    required void Function() validate,
  });
}

void validateCredentialProgramCommit(
  CredentialUseBatch request,
  CredentialProgramOperation next,
  CredentialProgramOperation? previous,
  int expectedRevision,
) {
  CredentialProgramOperation.fromStorageJson(
    Map<String, dynamic>.from(next.toStorageJson()),
  );
  if (request.programPlan == null ||
      next.archived ||
      request.archived ||
      request.id != next.requestId ||
      request.sessionBinding != next.sessionBinding ||
      request.deviceId != next.deviceId ||
      (previous?.revision ?? 0) != expectedRevision) {
    throw const CredentialUseFailure('operation_conflict');
  }
  next.plan.requireApprovedScope(request.programPlan!);
  final selected = request.items
      .where((i) => next.itemIds.contains(i.id))
      .toList();
  if (selected.length != next.itemIds.length ||
      _useFingerprint(
            selected
                .map((i) => i.destination.program!.binding.fingerprint)
                .toList()
              ..sort(),
          ) !=
          _useFingerprint(
            next.plan.bindings.map((b) => b.fingerprint).toList()..sort(),
          )) {
    throw const CredentialUseFailure('invalid_reference');
  }
  if (previous == null) {
    if (next.revision != 1 ||
        next.progress.state != 'preparing' ||
        next.progress.materialLease != null) {
      throw const CredentialUseFailure('invalid_plan');
    }
  } else if (previous.immutableFingerprint != next.immutableFingerprint ||
      next.revision != previous.revision + 1 ||
      previous.progress.state == next.progress.state &&
          !_sameProgramResult(previous.progress, next.progress) ||
      !(next.progress.state == previous.progress.state ||
          previous.progress.state == 'preparing' &&
              {
                'running',
                'prepare_failed',
                'start_failed',
                'unknown',
              }.contains(next.progress.state) ||
          previous.progress.state == 'running' &&
              {'exited', 'unknown'}.contains(next.progress.state)) ||
      previous.progress.materialLease != null &&
          _useFingerprint(previous.progress.materialLease!.toPrivateJson()) !=
              _useFingerprint(next.progress.materialLease?.toPrivateJson()) ||
      previous.progress.processStarted &&
          (!next.progress.processStarted ||
              next.progress.pid != previous.progress.pid ||
              next.progress.processCreatedAt !=
                  previous.progress.processCreatedAt ||
              next.progress.startedAt != previous.progress.startedAt) ||
      previous.progress.finishedAt != null &&
          (previous.progress.finishedAt != next.progress.finishedAt ||
              previous.progress.exitCode != next.progress.exitCode ||
              previous.progress.errorCode != next.progress.errorCode)) {
    throw const CredentialUseFailure('operation_conflict');
  }
}

bool _sameProgramResult(CredentialExecution a, CredentialExecution b) =>
    a.state == b.state &&
    a.processStarted == b.processStarted &&
    a.pid == b.pid &&
    a.processCreatedAt == b.processCreatedAt &&
    a.startedAt == b.startedAt &&
    a.finishedAt == b.finishedAt &&
    a.exitCode == b.exitCode &&
    a.errorCode == b.errorCode;
