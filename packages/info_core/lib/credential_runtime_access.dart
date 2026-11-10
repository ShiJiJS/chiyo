part of 'info_core.dart';

extension _CredentialRuntimeService on InformationService {
  CredentialRuntimeRepository get _runtimeRepository {
    if (_closed || _backupBusy || _repository is! CredentialRuntimeRepository) {
      throw const CredentialUseFailure('service_unavailable');
    }
    return _repository as CredentialRuntimeRepository;
  }

  CredentialUseRequest _useRequest(String id) =>
      _runtimeRepository.credentialUseRequests
          .where((r) => r.id == id)
          .firstOrNull ??
      (throw const CredentialUseFailure('session_mismatch'));
  CredentialUseRequest _sessionUseRequest(
    String session,
    String id, {
    bool allowEnded = false,
  }) {
    if (!_sessions.containsKey(session) ||
        !allowEnded && !_sessionActive(session)) {
      throw const CredentialUseFailure('session_required');
    }
    if (_credentialUseSessions[id] != session) {
      throw const CredentialUseFailure('session_mismatch');
    }
    return _useRequest(id);
  }

  ManagedCredential _useEligible(CredentialUseRequest r) {
    if (_inactiveCredentialApprovals.contains(r.id) ||
        _onlineCredentialDecisionPending(r.id)) {
      throw const CredentialUseFailure('grant_revoked');
    }
    final credential = _guardUseEligibility(
      r.credentialId,
      r.version,
      generation: r.useGeneration,
      requireMaterial: !r.isFocusedFill,
    );
    if (r.isFocusedFill && credential.form != CredentialForm.string) {
      throw const CredentialUseFailure('invalid_reference');
    }
    if (!r.isFocusedFill &&
        r.plan.receiver == 'ssh_identity' &&
        (r.plan.sshTrustSnapshotId == null ||
            r.plan.sshTrustSnapshotId != _sshHostTrust?.id ||
            r.plan.internalMaterialHashes['ssh_known_hosts'] !=
                _sshHostTrust?.sha256)) {
      throw const CredentialUseFailure('receiver_not_ready');
    }
    return credential;
  }

  ManagedCredential _guardUseEligibility(
    String id,
    int version, {
    int? generation,
    bool requireMaterial = true,
  }) {
    try {
      return _eligibleCredential(
        id,
        version,
        useGeneration: generation,
        requireMaterial: requireMaterial,
      );
    } on AccessFailure catch (e) {
      throw CredentialUseFailure(
        e.status == 'credential_material_purged'
            ? 'material_prepare_failed'
            : e.status,
      );
    }
  }

  Future<void> _saveUse({
    CredentialUseRequest? request,
    CredentialExecution? execution,
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    void Function()? validate,
  }) => _serializeRuntimeWrite(() async {
    final repo = _runtimeRepository;
    try {
      await repo.commitCredentialRuntime(
        [
          for (final r in repo.credentialUseRequests)
            if (r.id != request?.id) r,
          ?request,
        ],
        [
          for (final e in repo.credentialExecutions)
            if (e.id != execution?.id) e,
          ?execution,
        ],
        fieldGrant: fieldGrant,
        fieldRequest: fieldRequest,
        validate: validate,
      );
    } on CredentialUseFailure {
      rethrow;
    } on Object {
      throw const CredentialUseFailure('audit_unavailable');
    }
  });

  String _useState(CredentialUseRequest r) {
    if (r.state != 'pending') return r.state;
    final session = _credentialUseSessions[r.id];
    if (session == null || !_sessionActive(session)) return 'cancelled';
    if (!_clock().isBefore(r.requestExpiresAt)) return 'expired';
    return 'pending';
  }

  String _useGrantState(CredentialUseRequest r) {
    if (_inactiveCredentialApprovals.contains(r.id) ||
        _onlineCredentialDecisionPending(r.id)) {
      return 'revoked';
    }
    if (r.attemptConsumed) return 'consumed';
    if (!r.credentialApproved) return 'not_approved';
    if (r.invalidatedCode != null) {
      return r.invalidatedCode == 'grant_expired' ? 'expired' : 'revoked';
    }
    if (r.credentialGrantExpired(_clock())) return 'expired';
    final session = _credentialUseSessions[r.id];
    if (session == null || !_sessionActive(session)) return 'revoked';
    try {
      _useEligible(r);
    } on CredentialUseFailure catch (e) {
      return e.code == 'credential_expired' ? 'expired' : 'version_invalidated';
    }
    return 'available';
  }

  void _requireReusableUseGrant(CredentialUseRequest r, String? session) {
    if (session == null || !_sessionActive(session)) {
      throw const CredentialUseFailure('grant_revoked');
    }
    if (_useState(r) == 'pending') {
      throw const CredentialUseFailure('request_pending');
    }
    if (r.state == 'denied') {
      throw const CredentialUseFailure('request_denied');
    }
    if (r.invalidatedCode != null) {
      throw CredentialUseFailure(r.invalidatedCode!);
    }
    if (!r.credentialApproved) {
      throw const CredentialUseFailure('scope_not_approved');
    }
    if (r.credentialGrantExpired(_clock())) {
      throw const CredentialUseFailure('grant_expired');
    }
    _useEligible(r);
  }
}

extension CredentialRuntimeAgentAccess on AgentAccess {
  CredentialOperationClaim? credentialUseOperationStatus(
    String session,
    CredentialOperationInput input,
  ) {
    final r = _service._sessionUseRequest(session, input.requestId);
    if (r.isFocusedFill) throw const CredentialUseFailure('scope_not_approved');
    _service._rejectFocusedOperationCollision(session, input.operationId);
    if (r.protocolVersion != 2) {
      throw const CredentialUseFailure('unsupported_protocol');
    }
    final existing = _service._runtimeRepository.credentialExecutions
        .where(
          (e) =>
              e.protocolVersion == 2 &&
              e.operationId == input.operationId &&
              _service._credentialUseSessions[e.requestId] == session,
        )
        .firstOrNull;
    if (existing == null) return null;
    if (existing.operationFingerprint != input.fingerprint) {
      throw const CredentialUseFailure('operation_conflict');
    }
    return CredentialOperationClaim(
      _service._executionForDisplay(existing),
      grantState: _service._useGrantState(r),
    );
  }

  Future<CredentialOperationClaim> beginCredentialUseOperation(
    String session,
    CredentialOperationInput input, {
    int? supervisorPid,
    String? supervisorCreatedAt,
  }) => _service.owner._serialize(() async {
    if (_service._deviceCredentialRequests.containsKey(input.requestId)) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    final r = _service._sessionUseRequest(session, input.requestId);
    if (r.protocolVersion != 2) {
      throw const CredentialUseFailure('unsupported_protocol');
    }
    final existing = credentialUseOperationStatus(session, input);
    if (existing != null) {
      // Replays are metadata queries, including after expiry/revocation.
      // They must never reissue material or start a second process.
      return existing;
    }
    void validate() => _service._requireReusableUseGrant(r, session);

    validate();
    if (input.launch.receiver != r.plan.receiver) {
      throw const CredentialUseFailure('scope_not_approved');
    }
    if (supervisorPid != null || supervisorCreatedAt != null) {
      if (supervisorPid == null ||
          supervisorCreatedAt == null ||
          CredentialProcessIdentity.isActive(
                supervisorPid,
                supervisorCreatedAt,
              ) !=
              true) {
        throw const CredentialUseFailure('invalid_plan');
      }
    }
    final credential = _service._useEligible(r);
    final plan = await _resolveCredentialPlan(
      CredentialUseInput._(
        r.purpose,
        r.alias,
        r.credentialId,
        r.version,
        input.launch,
        r.fields,
        2,
      ),
      credential,
    );
    validate();
    final operationTime = DateTime.fromMillisecondsSinceEpoch(
      _service._clock().millisecondsSinceEpoch,
      isUtc: true,
    );
    final execution = CredentialExecution(
      id: _service._secret(),
      requestId: r.id,
      protocolVersion: 2,
      operationId: input.operationId,
      operationFingerprint: input.fingerprint,
      operationPlan: plan,
      createdAt: operationTime,
      supervisorPid: supervisorPid,
      supervisorCreatedAt: supervisorCreatedAt,
      jobName: supervisorPid == null
          ? null
          : CredentialProcessJob.nameFor(_service._secret().substring(0, 32)),
    );
    await _service._saveUse(
      request: r.changed({
        'executionId': execution.id,
        'attemptedAt': _useTimestamp(operationTime),
      }),
      execution: execution,
      validate: validate,
    );
    final material = await _claimUseExecutionMaterial(
      r,
      credential,
      execution,
      plan,
      validate,
    );
    final recorded = _service._runtimeRepository.credentialExecutions
        .firstWhere((e) => e.id == execution.id);
    return CredentialOperationClaim(
      recorded,
      material: material,
      grantState: _service._useGrantState(r),
    );
  });

  Future<void> registerCredentialWorker(
    String id,
    String capability,
    int workerPid,
    String workerCreatedAt,
  ) => _service.owner._serialize(() async {
    final record = _service._runtimeRepository.credentialExecutions
        .where((e) => e.id == id)
        .firstOrNull;
    if (_service._executionCapabilities[id] != capability || record == null) {
      throw const CredentialUseFailure('session_mismatch');
    }
    _service._requireSettledExecutionReceipt(id);
    if (record.state != 'preparing' ||
        record.jobName == null ||
        record.supervisorPid == null ||
        record.supervisorCreatedAt == null ||
        record.workerPid != null &&
            (record.workerPid != workerPid ||
                record.workerCreatedAt != workerCreatedAt)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    void validate() {
      if (record.protocolVersion == 2) {
        _service._requireReusableUseGrant(
          _service._useRequest(record.requestId),
          _service._credentialUseSessions[record.requestId],
        );
      }
      if (CredentialProcessIdentity.isActive(
                record.supervisorPid!,
                record.supervisorCreatedAt!,
              ) !=
              true ||
          CredentialProcessIdentity.isActive(workerPid, workerCreatedAt) !=
              true) {
        throw const CredentialUseFailure('invalid_plan');
      }
      try {
        CredentialProcessJob.observe(record.jobName!, workerPid).close();
      } on Object {
        throw const CredentialUseFailure('invalid_plan');
      }
    }

    validate();
    await _service._saveUse(
      execution: record.changed({
        'workerPid': workerPid,
        'workerCreatedAt': workerCreatedAt,
      }),
      validate: validate,
    );
  });
  CredentialExecution credentialExecutionStatus(String session, String id) {
    final e = _service._runtimeRepository.credentialExecutions
        .where((e) => e.id == id)
        .firstOrNull;
    if (e == null) throw const CredentialUseFailure('session_mismatch');
    _service._sessionUseRequest(session, e.requestId, allowEnded: true);
    return _service._executionForDisplay(e);
  }

  Future<CredentialExecution> reportCredentialExecution(
    CredentialExecutionReport report,
  ) {
    if (_service._deviceCredentialExecutions.containsKey(report.executionId)) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    return _reportCredentialExecution(report);
  }

  Future<CredentialExecution> _reportCredentialExecution(
    CredentialExecutionReport report, {
    bool verifyLocalProcess = true,
  }) => _service.owner._serialize(() async {
    if (_service._executionCapabilities[report.executionId] !=
        report.executionCapability) {
      throw const CredentialUseFailure('session_mismatch');
    }
    final old = _service._runtimeRepository.credentialExecutions
        .where((e) => e.id == report.executionId)
        .firstOrNull;
    if (old == null) throw const CredentialUseFailure('session_mismatch');
    // A later fallback/duplicate must not replace the first validated terminal
    // receipt while its durable write is waiting for storage recovery.
    _service._requireSettledExecutionReceipt(old.id);
    final next = report.state;
    if (old.jobName != null && old.jobName != report.jobName) {
      throw const CredentialUseFailure('invalid_plan');
    }
    // An HTTP response can be lost after commit. Replaying the exact metadata
    // is harmless; changing any existing fact is still rejected below.
    if (old.state == next &&
        old.pid == report.pid &&
        old.processCreatedAt == report.processCreatedAt &&
        old.startedAt == report.startedAt &&
        old.finishedAt == report.finishedAt &&
        old.jobName == report.jobName &&
        old.exitCode == report.exitCode &&
        old.errorCode == report.errorCode) {
      return old;
    }
    if (!(old.state == 'preparing' &&
            {
              'running',
              'prepare_failed',
              'start_failed',
              'unknown',
            }.contains(next) ||
        old.state == 'running' && {'exited', 'unknown'}.contains(next))) {
      throw const CredentialUseFailure('invalid_plan');
    }
    if (next == 'running' &&
            (report.pid == null ||
                report.pid! < 1 ||
                report.processCreatedAt == null ||
                report.startedAt == null) ||
        next == 'exited' &&
            (report.exitCode == null || report.finishedAt == null) ||
        old.processStarted &&
            (report.pid != old.pid ||
                report.processCreatedAt != old.processCreatedAt)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    if (report.errorCode != null &&
        !{
          'material_prepare_failed',
          'material_claim_failed',
          'executable_changed',
          'process_start_failed',
          'execution_unknown',
          'audit_unavailable',
        }.contains(report.errorCode)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    if (next == 'running' && verifyLocalProcess) {
      if (old.supervisorPid != null && old.workerPid == null) {
        throw const CredentialUseFailure('invalid_plan');
      }
      if (report.jobName != null &&
          !CredentialProcessJob.validName(report.jobName!)) {
        throw const CredentialUseFailure('invalid_plan');
      }
      if (report.jobName != null) {
        try {
          CredentialProcessJob.observe(
            report.jobName!,
            report.pid!,
            workerPid: old.workerPid,
          ).close();
        } on Object {
          throw const CredentialUseFailure('invalid_plan');
        }
      }
      final identity = CredentialProcessIdentity.capture(report.pid!);
      try {
        if (identity == null || identity.value != report.processCreatedAt) {
          throw const CredentialUseFailure('invalid_plan');
        }
      } finally {
        identity?.close();
      }
    }
    final facts = <String, Object?>{
      'executionState': next,
      'processStarted': old.processStarted || next == 'running',
      'pid': report.pid ?? old.pid,
      'processCreatedAt': report.processCreatedAt ?? old.processCreatedAt,
      'startedAt': _useTimestamp(report.startedAt ?? old.startedAt),
      'finishedAt': _useTimestamp(report.finishedAt),
      'exitCode': report.exitCode,
      'errorCode': report.errorCode,
      'jobName': report.jobName ?? old.jobName,
    };
    final changed = old.changed(facts);
    try {
      await _service._saveUse(execution: changed);
    } on CredentialUseFailure catch (e) {
      if (e.code == 'audit_unavailable' && next != 'running') {
        _service._queueExecutionReceipt(old.id, facts);
      }
      rethrow;
    }
    return changed;
  });
  Future<CredentialLaunchPlan> _resolveCredentialPlan(
    CredentialUseInput input,
    ManagedCredential credential,
  ) async {
    final launch = _validateCredentialReceiver(input, credential);
    final identity = await _service.credentialExecutableInspector(
      input.launch.path,
      input.launch.receiver,
    );
    String cwd;
    try {
      cwd = await Directory(input.launch.cwd).resolveSymbolicLinks();
    } on Object {
      throw const CredentialUseFailure('invalid_plan', fieldPath: 'launch.cwd');
    }
    if (!await Directory(cwd).exists()) {
      throw const CredentialUseFailure('invalid_plan', fieldPath: 'launch.cwd');
    }
    return launch.resolved(identity, cwd);
  }

  CredentialLaunchPlan _validateCredentialReceiver(
    CredentialUseInput input,
    ManagedCredential credential,
  ) {
    final CredentialLaunchPlan launch;
    if (input.launch.receiver == 'aws_shared_credentials') {
      launch = _service._validateAwsReceiver(input, credential);
    } else if (input.launch.receiver == 'ssh_identity') {
      launch = _service._validateSshReceiver(input, credential);
    } else {
      _validateTokenReceiver(input, credential);
      launch = input.launch;
    }
    return launch;
  }

  Future<CredentialUseRequest> requestCredentialUse(
    String session,
    CredentialUseInput input,
  ) {
    if (_service._deviceFileDelivery) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    return _requestCredentialUse(session, input, _resolveCredentialPlan);
  }

  Future<CredentialUseRequest> _requestCredentialUse(
    String session,
    CredentialUseInput input,
    FutureOr<CredentialLaunchPlan> Function(
      CredentialUseInput,
      ManagedCredential,
    )
    resolve,
  ) => _service.owner._serialize(() async {
    if (!_service._sessionActive(session)) {
      throw const CredentialUseFailure('session_required');
    }
    final c = _service._guardUseEligibility(input.credentialId, input.version);
    if (!c.discoverable) {
      throw const CredentialUseFailure(
        'invalid_reference',
        fieldPath: 'credentials[0].credentialId',
      );
    }
    if (input.readFields.any((f) => _service._field(f) == null)) {
      throw const CredentialUseFailure(
        'invalid_reference',
        fieldPath: 'readFields',
      );
    }
    final launch = await resolve(input, c);
    if (!_service._sessionActive(session)) {
      throw const CredentialUseFailure('session_required');
    }
    _service._guardUseEligibility(
      input.credentialId,
      input.version,
      generation: c.useGeneration,
    );
    final now = _service._clock().toUtc();
    final request = CredentialUseRequest(
      protocolVersion: input.protocolVersion,
      id: _service._secret(),
      chatLabel: _service._sessions[session]!,
      agentName: input.agentName,
      externalChatId: input.externalChatId,
      purpose: input.purpose,
      alias: input.alias,
      credentialId: c.id,
      credentialName: c.name,
      version: c.version,
      useGeneration: c.useGeneration,
      plan: launch,
      requestedPlan: input.launch.resolved(launch.executable, launch.cwd),
      createdAt: now,
      requestExpiresAt: now.add(_service._requestLifetime),
      fields: input.readFields,
    );
    await _service._saveUse(request: request);
    _service._credentialUseSessions[request.id] = session;
    _service._submitted.add(request.id);
    return request;
  });

  void _validateTokenReceiver(CredentialUseInput input, ManagedCredential c) {
    final plan = input.launch;
    if (plan.receiver != 'gh_token') {
      throw const CredentialUseFailure('unsupported_receiver');
    }
    if (c.form != CredentialForm.string) {
      throw const CredentialUseFailure('invalid_reference');
    }
    final token = plan.env['GH_TOKEN'];
    if (token == null ||
        token.kind != LaunchValueKind.secret ||
        token.value != input.alias) {
      throw const CredentialUseFailure(
        'invalid_reference',
        fieldPath: 'launch.env.GH_TOKEN',
      );
    }
    final raw = _service._currentCredentialMaterial(c);
    if (raw.bytes.isEmpty || utf8.decode(raw.bytes).isEmpty) {
      throw const CredentialUseFailure('material_prepare_failed');
    }
    for (final entry in plan.env.entries) {
      if (entry.key == 'GH_TOKEN') continue;
      if (entry.value.kind != LaunchValueKind.literal ||
          !{'GH_HOST': 'github.com', 'GH_PROMPT_DISABLED': '1'}.entries.any(
            (e) => e.key == entry.key && e.value == entry.value.value,
          )) {
        throw CredentialUseFailure(
          'invalid_env',
          fieldPath: 'launch.env.${entry.key}',
        );
      }
    }
    if (plan.argv.any((v) => v.kind != LaunchValueKind.literal)) {
      throw const CredentialUseFailure(
        'invalid_reference',
        fieldPath: 'launch.argv',
      );
    }
    final argv = plan.argv.map((v) => v.value).toList();
    if (argv.isEmpty ||
        !{
          'repo',
          'issue',
          'pr',
          'api',
          'gist',
          'release',
          'workflow',
          'run',
          'search',
          'status',
        }.contains(argv.first)) {
      throw const CredentialUseFailure(
        'invalid_plan',
        fieldPath: 'launch.argv[0]',
      );
    }
    if (argv.any(
      (a) =>
          a == '--hostname' ||
          a.startsWith('--hostname=') ||
          a == '--web' ||
          a == '-w',
    )) {
      throw const CredentialUseFailure(
        'invalid_plan',
        fieldPath: 'launch.argv',
      );
    }
    if (argv.first == 'api') {
      String? endpoint;
      bool changesAuthentication(String header) => RegExp(
        r'^\s*(authorization|host|proxy-authorization|cookie)\s*:',
        caseSensitive: false,
      ).hasMatch(header);
      for (var i = 1; i < argv.length; i++) {
        final value = argv[i];
        final shortHeader = RegExp(r'^-[ip]*H(.*)$').firstMatch(value);
        if (value.startsWith('--header=') || shortHeader != null) {
          var header = value.startsWith('--header=')
              ? value.substring(9)
              : shortHeader!.group(1)!;
          if (header.startsWith('=')) header = header.substring(1);
          if (header.isEmpty) {
            if (++i >= argv.length) {
              throw const CredentialUseFailure(
                'invalid_plan',
                fieldPath: 'launch.argv',
              );
            }
            header = argv[i];
          }
          if (changesAuthentication(header)) {
            throw const CredentialUseFailure(
              'invalid_plan',
              fieldPath: 'launch.argv',
            );
          }
        } else if (value == '--method' || value == '-X') {
          if (i + 1 >= argv.length ||
              !{'GET', 'POST', 'PUT', 'PATCH', 'DELETE'}.contains(argv[++i])) {
            throw const CredentialUseFailure(
              'invalid_plan',
              fieldPath: 'launch.argv',
            );
          }
        } else if (value.startsWith('--method=') ||
            value.startsWith('-X') && value.length > 2) {
          final method = value.startsWith('--method=')
              ? value.substring(9)
              : value.substring(2);
          if (!{'GET', 'POST', 'PUT', 'PATCH', 'DELETE'}.contains(method)) {
            throw const CredentialUseFailure(
              'invalid_plan',
              fieldPath: 'launch.argv',
            );
          }
        } else if ({
          '--header',
          '-H',
          '--field',
          '-F',
          '--raw-field',
          '-f',
          '--input',
          '--jq',
          '-q',
          '--template',
          '-t',
          '--cache',
        }.contains(value)) {
          if (i + 1 >= argv.length) {
            throw const CredentialUseFailure(
              'invalid_plan',
              fieldPath: 'launch.argv',
            );
          }
          final argument = argv[++i];
          if ({'--header', '-H'}.contains(value) &&
              changesAuthentication(argument)) {
            throw const CredentialUseFailure(
              'invalid_plan',
              fieldPath: 'launch.argv',
            );
          }
        } else if (!value.startsWith('-') && endpoint == null) {
          endpoint = value;
        }
      }
      if (endpoint == null ||
          endpoint.contains('://') ||
          endpoint.startsWith('//') ||
          endpoint.contains('\\')) {
        throw const CredentialUseFailure(
          'invalid_plan',
          fieldPath: 'launch.argv',
        );
      }
    }
  }

  Map<String, Object?> credentialUseStatus(String session, String id) {
    final r = _service._sessionUseRequest(session, id, allowEnded: true);
    return {
      'protocolVersion': r.protocolVersion,
      'status': _service._useState(r),
      'requestId': id,
      'createdAt': _useTimestamp(r.createdAt),
      'requestExpiresAt': _useTimestamp(r.requestExpiresAt),
      'planHash': r.usePlanHash,
      if (r.isFocusedFill) 'useKind': 'focused_fill',
      if (r.state != 'pending')
        'decision': {
          'credentialUse': {
            'approved': r.credentialApproved,
            'state': _service._useGrantState(r),
            if (r.credentialApproved) ...{
              'credentialId': r.credentialId,
              'version': r.version,
              'expiresAt': _useTimestamp(r.credentialExpiresAt),
              if (r.credentialValidity == CredentialUseValidity.session) ...{
                'validity': 'session',
                'sessionId': _service._sessionBindings[session],
              },
              if (r.protocolVersion == 1) ...{
                'maxAttempts': 1,
                'attemptsConsumed': r.attemptConsumed ? 1 : 0,
              } else ...{
                'reusable': true,
                'operationCount': r.isFocusedFill
                    ? (_service._runtimeRepository
                              as FocusedFillRuntimeRepository)
                          .focusedFillOperations
                          .where((e) => e.requestId == r.id)
                          .length
                    : _service._runtimeRepository.credentialExecutions
                          .where((e) => e.requestId == r.id)
                          .length,
              },
            },
          },
          'fieldRead': {
            'approved': r.approvedFields.isNotEmpty,
            if (r.approvedFields.isNotEmpty) ...{
              'fields': r.approvedFields.map((f) => f.toJson()).toList(),
              'expiresAt': _useTimestamp(r.fieldExpiresAt),
            },
          },
        },
      if (r.executionId != null) 'executionId': r.executionId,
    };
  }

  Future<CredentialExecutionMaterial> consumeCredentialUse(
    String session,
    String id, {
    int? supervisorPid,
    String? supervisorCreatedAt,
  }) => _service.owner._serialize(() async {
    final r = _service._sessionUseRequest(session, id);
    if (r.protocolVersion != 1) {
      throw const CredentialUseFailure('operation_required');
    }
    if (r.attemptConsumed) {
      throw CredentialUseFailure(
        'attempt_consumed',
        attemptConsumed: true,
        executionId: r.executionId,
      );
    }
    final state = _service._useState(r);
    if (state == 'pending') throw const CredentialUseFailure('request_pending');
    if (state == 'denied') throw const CredentialUseFailure('request_denied');
    if (r.invalidatedCode != null) {
      throw CredentialUseFailure(r.invalidatedCode!);
    }
    if (!r.credentialApproved) {
      throw const CredentialUseFailure('scope_not_approved');
    }
    if (r.credentialGrantExpired(_service._clock())) {
      throw const CredentialUseFailure('grant_expired');
    }
    final c = _service._useEligible(r);
    if (supervisorPid != null || supervisorCreatedAt != null) {
      if (supervisorPid == null ||
          supervisorCreatedAt == null ||
          CredentialProcessIdentity.isActive(
                supervisorPid,
                supervisorCreatedAt,
              ) !=
              true) {
        throw const CredentialUseFailure('invalid_plan');
      }
    }
    final execution = CredentialExecution(
      id: _service._secret(),
      requestId: id,
      supervisorPid: supervisorPid,
      supervisorCreatedAt: supervisorCreatedAt,
      jobName: supervisorPid == null
          ? null
          : CredentialProcessJob.nameFor(_service._secret().substring(0, 32)),
    );
    final changed = r.changed({
      'attemptConsumed': true,
      'executionId': execution.id,
      'attemptedAt': _useTimestamp(_service._clock().toUtc()),
    });
    void validate() {
      if (!_service._sessionActive(session)) {
        throw const CredentialUseFailure('grant_revoked');
      }
      if (r.credentialGrantExpired(_service._clock())) {
        throw const CredentialUseFailure('grant_expired');
      }
      _service._useEligible(r);
    }

    await _service._saveUse(
      request: changed,
      execution: execution,
      validate: validate,
    );
    return _claimUseExecutionMaterial(r, c, execution, r.plan, validate);
  });

  Future<CredentialExecutionMaterial> _claimUseExecutionMaterial(
    CredentialUseRequest r,
    ManagedCredential c,
    CredentialExecution execution,
    CredentialLaunchPlan plan,
    void Function() validate,
  ) async {
    final capability = _service._secret();
    _service._executionCapabilities[execution.id] = capability;
    CredentialMaterialLease? lease;
    try {
      validate();
      final material = _service._currentCredentialMaterial(c);
      if (material.bytes.isEmpty) {
        throw const CredentialUseFailure('material_prepare_failed');
      }
      if (c.form == CredentialForm.file) {
        lease = ManagedCredentialFiles.create();
        await _service._saveUse(
          execution: execution.changed({
            'materialLease': lease.toPrivateJson(),
            'cleanupState': 'pending',
          }),
        );
      }
      validate();
      return CredentialExecutionMaterial(
        execution.id,
        capability,
        plan,
        CredentialMaterialValue(c.id, c.version, c.form, material.bytes),
        r.alias,
        lease,
        plan.receiver == 'ssh_identity'
            ? {'ssh_known_hosts': _service._sshHostTrust!.bytes}
            : const {},
        execution.jobName,
      );
    } on Object catch (e) {
      _service._executionCapabilities.remove(execution.id);
      final code = e is CredentialUseFailure
          ? e.code
          : 'material_prepare_failed';
      var cleanup = 'not_needed';
      if (lease != null) {
        try {
          ManagedCredentialFiles.cleanup(lease);
          cleanup = 'complete';
        } on Object {
          cleanup = 'needs_check';
        }
      }
      try {
        await _service._saveUse(
          execution: execution.changed({
            'executionState': 'prepare_failed',
            'errorCode': code == 'material_prepare_failed'
                ? code
                : 'material_claim_failed',
            'finishedAt': _useTimestamp(_service._clock().toUtc()),
            if (lease != null) 'materialLease': lease.toPrivateJson(),
            'cleanupState': cleanup,
          }),
        );
      } on Object {
        throw CredentialUseFailure(
          'audit_unavailable',
          attemptConsumed: true,
          executionId: execution.id,
        );
      }
      throw CredentialUseFailure(
        code,
        attemptConsumed: true,
        executionId: execution.id,
      );
    }
  }
}

extension CredentialRuntimeOwnerAccess on OwnerAccess {
  List<CredentialUseRequest> get credentialUseRequests =>
      _service._runtimeRepository.credentialUseRequests;
  List<CredentialExecution> get credentialExecutions => List.unmodifiable(
    _service._runtimeRepository.credentialExecutions.map(
      _service._executionForDisplay,
    ),
  );
  String credentialUseState(CredentialUseRequest request) =>
      _service._useState(request);
  String credentialGrantState(CredentialUseRequest request) =>
      _service._useGrantState(request);

  /// Current permission, independently from the immutable recorded decision.
  /// This reads the live authorization model without writing/pruning history.
  /// Online decisions remain blocked until their exact original receipt settles.
  /// Legacy local diagnostic readback does not activate an unconfirmed grant.
  bool credentialUseDecisionUnconfirmed(CredentialUseRequest request) =>
      _service._inactiveCredentialApprovals.contains(request.id) ||
      _service._onlineCredentialDecisionPending(request.id);

  String credentialFieldGrantState(
    CredentialUseRequest request, {
    bool forReview = false,
  }) {
    if (request.approvedFields.isEmpty) return 'not_approved';
    if (request.fieldExpiresAt == null ||
        !_service._clock().isBefore(request.fieldExpiresAt!)) {
      return 'expired';
    }
    final active = _service._requests[request.id];
    final operation = pendingAdditionalApproval;
    // The exact revoke validates its original review while its own read barrier
    // is held. Agent reads and all other projections still observe the barrier.
    final ownRevoke =
        forReview &&
        operation != null &&
        identical(operation.owner, this) &&
        operation.entered &&
        operation.kind == 'credential' &&
        operation.command.requestId == request.id &&
        operation.command.action == InformationApprovalAction.revoke;
    return request.approvedFields.any(
          (field) => _service._canRead(
            active,
            field,
            ignoreDecisionBarrier: ownRevoke,
          ),
        )
        ? 'available'
        : 'revoked';
  }

  void checkCredentialUseEligibility(CredentialUseRequest request) {
    _service._useEligible(request);
  }

  Future<void> revokeCredentialUse(String id) => _serialize(() async {
    final r = _service._useRequest(id);
    if (!r.credentialApproved || r.attemptConsumed) {
      throw const CredentialUseFailure('request_terminal');
    }
    await _service._saveUse(
      request: r.changed({
        'invalidatedCode': 'grant_revoked',
        'revokedAt': _useTimestamp(_service._clock().toUtc()),
      }),
    );
  });
  Future<void> decideCredentialUse(
    String id, {
    required bool approveCredential,
    List<FieldRef> fields = const [],
    Duration? lifetime = AccessTiming.defaultLifetime,
    Duration? fieldLifetime,
    Map<FieldRef, int>? reviewedVersions,
  }) => _serialize(() async {
    final r = _service._useRequest(id);
    if (_service._onlineCredentialDecisionPending(id)) {
      throw const CredentialUseFailure('audit_unavailable');
    }
    if (_service._useState(r) != 'pending') {
      throw const CredentialUseFailure('request_terminal');
    }
    if (!AccessTiming.acceptsCredentialLifetime(
          lifetime,
          sessionValidity: r.supportsSessionValidity,
        ) ||
        fieldLifetime != null &&
            !AccessTiming.acceptsFieldLifetime(
              fieldLifetime,
              protocolVersion: r.protocolVersion,
            )) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final effectiveFieldLifetime =
        fieldLifetime ??
        (r.protocolVersion == 2 ? AccessTiming.defaultLifetime : lifetime!);
    if (fields.toSet().length != fields.length ||
        fields.any(
          (f) => !r.fields.contains(f) || _service._field(f) == null,
        )) {
      throw const CredentialUseFailure('invalid_reference');
    }
    if (reviewedVersions != null &&
        (reviewedVersions.length != fields.toSet().length ||
            fields.any(
              (f) => reviewedVersions[f] != _service._field(f)!.version,
            ))) {
      throw const CredentialUseFailure('scope_changed');
    }
    if (approveCredential) _service._useEligible(r);
    final now = _service._clock().toUtc();
    final state = !approveCredential && fields.isEmpty
        ? 'denied'
        : approveCredential &&
              (r.fields.isEmpty || fields.length == r.fields.length)
        ? 'approved'
        : 'partially_approved';
    final changed = r.changed({
      'state': state,
      'decidedAt': _useTimestamp(now),
      'credentialApproved': approveCredential,
      'approvedFields': fields.map((f) => f.toJson()).toList(),
      'credentialExpiresAt': approveCredential && lifetime != null
          ? _useTimestamp(now.add(lifetime))
          : null,
      if (approveCredential && lifetime == null)
        'credentialValidity': 'session',
      'fieldExpiresAt': fields.isNotEmpty
          ? _useTimestamp(now.add(effectiveFieldLifetime))
          : null,
    });
    final session = _service._credentialUseSessions[id]!;
    final recorded = fields.map((f) {
      final item = information.firstWhere((i) => i.id == f.itemId);
      return RecordedField(
        item.id,
        f.fieldId,
        item.name,
        item.fields.firstWhere((v) => v.id == f.fieldId).name,
      );
    }).toList();
    final fieldGrant = fields.isEmpty
        ? null
        : GrantHistory(
            id: _service._secret(),
            requestId: id,
            sessionId: _service._sessionBindings[session]!,
            chatLabel: r.chatLabel,
            agentName: r.agentName,
            externalChatId: r.externalChatId,
            purpose: r.purpose,
            approvedAt: now,
            expiresAt: now.add(effectiveFieldLifetime),
            fields: recorded,
            events: [GrantEvent(GrantEventKind.approved, now)],
          );
    final fieldRequest = fields.isEmpty
        ? null
        : RequestHistory(
            id: id,
            sessionId: _service._sessionBindings[session]!,
            chatLabel: r.chatLabel,
            agentName: r.agentName,
            externalChatId: r.externalChatId,
            purpose: r.purpose,
            createdAt: r.createdAt,
            requestExpiresAt: r.requestExpiresAt,
            recordedAt: now,
            state: AccessRequestState.approved,
            fields: recorded,
            grantId: fieldGrant!.id,
          );
    void validate() {
      if (_service._useState(r) != 'pending') {
        throw const CredentialUseFailure('request_terminal');
      }
      if (approveCredential) _service._useEligible(r);
      if (fields.any((f) => _service._field(f) == null)) {
        throw const CredentialUseFailure('invalid_reference');
      }
      if (reviewedVersions != null &&
          fields.any(
            (f) => reviewedVersions[f] != _service._field(f)!.version,
          )) {
        throw const CredentialUseFailure('scope_changed');
      }
    }

    void publishFields() {
      if (!_service._sessionActive(session) ||
          _service._requests.containsKey(id)) {
        return;
      }
      if (fields.isNotEmpty) {
        final request =
            _Request(
                id,
                session,
                r.purpose,
                Set.unmodifiable(r.fields),
                r.createdAt,
                r.requestExpiresAt,
                agentName: r.agentName,
                externalChatId: r.externalChatId,
              )
              ..approvedAt = now
              ..recordedFields = recorded
              ..history = fieldGrant
              ..state = AccessRequestState.approved
              ..grant = ClaimedGrant(
                _service._secret(),
                fields,
                now.add(effectiveFieldLifetime),
              );
        _service._requests[id] = request;
        _service._grants[request.grant!.token] = request;
      }
    }

    try {
      await _service._saveUse(
        request: changed,
        fieldGrant: fieldGrant,
        fieldRequest: fieldRequest,
        validate: validate,
      );
    } on CredentialUseFailure {
      final operation = pendingAdditionalApproval;
      if (operation != null) {
        try {
          final receipt = await _additionalApprovals.additionalApprovalReceipt(
            operation.command.operationId,
          );
          if (receipt != null) {
            _checkAdditionalReceipt(receipt, operation.command);
            publishFields();
            return;
          }
        } on Object {
          // Original decision could not confirm commit. A later metadata query
          // may report its fact, but must never activate a new permission.
          _service._rememberOnlineCredentialDecision(operation);
          _service._inactiveCredentialApprovals.add(id);
          _service._uncertainCredentialDecisions[operation
              .command
              .operationId] = (committed) {
            if (!committed) _service._inactiveCredentialApprovals.remove(id);
          };
        }
      }
      rethrow;
    }
    publishFields();
  });
}
