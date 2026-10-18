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

  ManagedCredential _useEligible(CredentialUseRequest r) =>
      _guardUseEligibility(
        r.credentialId,
        r.version,
        generation: r.useGeneration,
      );
  ManagedCredential _guardUseEligibility(
    String id,
    int version, {
    int? generation,
  }) {
    try {
      return _eligibleCredential(id, version, useGeneration: generation);
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
  }) async {
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
  }

  String _useState(CredentialUseRequest r) {
    if (r.state != 'pending') return r.state;
    final session = _credentialUseSessions[r.id];
    if (session == null || !_sessionActive(session)) return 'cancelled';
    if (!_clock().isBefore(r.requestExpiresAt)) return 'expired';
    return 'pending';
  }

  String _useGrantState(CredentialUseRequest r) {
    if (r.attemptConsumed) return 'consumed';
    if (!r.credentialApproved) return 'not_approved';
    if (r.invalidatedCode != null) return 'revoked';
    if (!_clock().isBefore(r.credentialExpiresAt!)) return 'expired';
    final session = _credentialUseSessions[r.id];
    if (session == null || !_sessionActive(session)) return 'revoked';
    try {
      _useEligible(r);
    } on CredentialUseFailure catch (e) {
      return e.code == 'credential_expired' ? 'expired' : 'version_invalidated';
    }
    return 'available';
  }
}

extension CredentialRuntimeAgentAccess on AgentAccess {
  CredentialExecution credentialExecutionStatus(String session, String id) {
    final e = _service._runtimeRepository.credentialExecutions
        .where((e) => e.id == id)
        .firstOrNull;
    if (e == null) throw const CredentialUseFailure('session_mismatch');
    _service._sessionUseRequest(session, e.requestId, allowEnded: true);
    return e;
  }

  Future<CredentialExecution> reportCredentialExecution(
    CredentialExecutionReport report,
  ) => _service.owner._serialize(() async {
    if (_service._executionCapabilities[report.executionId] !=
        report.executionCapability) {
      throw const CredentialUseFailure('session_mismatch');
    }
    final old = _service._runtimeRepository.credentialExecutions
        .where((e) => e.id == report.executionId)
        .firstOrNull;
    if (old == null) throw const CredentialUseFailure('session_mismatch');
    final next = report.state;
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
        }.contains(report.errorCode)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    if (next == 'running') {
      if (report.jobName != null &&
          !RegExp(
            r'^Local\\AgentInfoRuntime-[A-Za-z0-9_-]{32}$',
          ).hasMatch(report.jobName!)) {
        throw const CredentialUseFailure('invalid_plan');
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
    final changed = CredentialExecution(
      id: old.id,
      requestId: old.requestId,
      state: next,
      processStarted: old.processStarted || next == 'running',
      pid: report.pid ?? old.pid,
      processCreatedAt: report.processCreatedAt ?? old.processCreatedAt,
      startedAt: report.startedAt ?? old.startedAt,
      finishedAt: report.finishedAt,
      exitCode: report.exitCode,
      errorCode: report.errorCode,
      materialLease: old.materialLease,
      cleanupState: old.cleanupState,
      jobName: report.jobName ?? old.jobName,
    );
    await _service._saveUse(execution: changed);
    return changed;
  });
  Future<CredentialUseRequest> requestCredentialUse(
    String session,
    CredentialUseInput input,
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
    final CredentialLaunchPlan launch;
    if (input.launch.receiver == 'aws_shared_credentials') {
      launch = _service._validateAwsReceiver(input, c);
    } else {
      _validateTokenReceiver(input, c);
      launch = input.launch;
    }
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
      id: _service._secret(),
      chatLabel: _service._sessions[session]!,
      purpose: input.purpose,
      alias: input.alias,
      credentialId: c.id,
      version: c.version,
      useGeneration: c.useGeneration,
      plan: launch.resolved(identity, cwd),
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
      'protocolVersion': 1,
      'status': _service._useState(r),
      'requestId': id,
      'createdAt': _useTimestamp(r.createdAt),
      'requestExpiresAt': _useTimestamp(r.requestExpiresAt),
      'planHash': r.plan.planHash,
      if (r.state != 'pending')
        'decision': {
          'credentialUse': {
            'approved': r.credentialApproved,
            if (r.credentialApproved) ...{
              'credentialId': r.credentialId,
              'version': r.version,
              'expiresAt': _useTimestamp(r.credentialExpiresAt),
              'maxAttempts': 1,
              'attemptsConsumed': r.attemptConsumed ? 1 : 0,
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
    String id,
  ) => _service.owner._serialize(() async {
    final r = _service._sessionUseRequest(session, id);
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
    if (!_service._clock().isBefore(r.credentialExpiresAt!)) {
      throw const CredentialUseFailure('grant_expired');
    }
    final c = _service._useEligible(r);
    final execution = CredentialExecution(
      id: _service._secret(),
      requestId: id,
    );
    final changed = r.changed({
      'attemptConsumed': true,
      'executionId': execution.id,
    });
    void validate() {
      if (!_service._sessionActive(session)) {
        throw const CredentialUseFailure('grant_revoked');
      }
      if (!_service._clock().isBefore(r.credentialExpiresAt!)) {
        throw const CredentialUseFailure('grant_expired');
      }
      _service._useEligible(r);
    }

    await _service._saveUse(
      request: changed,
      execution: execution,
      validate: validate,
    );
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
      return CredentialExecutionMaterial(
        execution.id,
        capability,
        r.plan,
        CredentialMaterialValue(c.id, c.version, c.form, material.bytes),
        r.alias,
        lease,
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
          execution: CredentialExecution(
            id: execution.id,
            requestId: id,
            state: 'prepare_failed',
            errorCode: code == 'material_prepare_failed'
                ? code
                : 'material_claim_failed',
            finishedAt: _service._clock().toUtc(),
            materialLease: lease,
            cleanupState: cleanup,
          ),
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
  });
}

extension CredentialRuntimeOwnerAccess on OwnerAccess {
  List<CredentialUseRequest> get credentialUseRequests =>
      _service._runtimeRepository.credentialUseRequests;
  List<CredentialExecution> get credentialExecutions =>
      _service._runtimeRepository.credentialExecutions;
  String credentialUseState(CredentialUseRequest request) =>
      _service._useState(request);
  String credentialGrantState(CredentialUseRequest request) =>
      _service._useGrantState(request);
  Future<void> revokeCredentialUse(String id) => _serialize(() async {
    final r = _service._useRequest(id);
    if (!r.credentialApproved || r.attemptConsumed) {
      throw const CredentialUseFailure('request_terminal');
    }
    await _service._saveUse(
      request: r.changed({'invalidatedCode': 'grant_revoked'}),
    );
  });
  Future<void> decideCredentialUse(
    String id, {
    required bool approveCredential,
    List<FieldRef> fields = const [],
    Duration lifetime = const Duration(minutes: 15),
    Duration? fieldLifetime,
  }) => _serialize(() async {
    final r = _service._useRequest(id);
    if (_service._useState(r) != 'pending') {
      throw const CredentialUseFailure('request_terminal');
    }
    if (lifetime != const Duration(minutes: 15) &&
            lifetime != const Duration(minutes: 30) ||
        fieldLifetime != null &&
            fieldLifetime != const Duration(minutes: 15) &&
            fieldLifetime != const Duration(minutes: 30)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    if (fields.toSet().length != fields.length ||
        fields.any(
          (f) => !r.fields.contains(f) || _service._field(f) == null,
        )) {
      throw const CredentialUseFailure('invalid_reference');
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
      'credentialApproved': approveCredential,
      'approvedFields': fields.map((f) => f.toJson()).toList(),
      'credentialExpiresAt': approveCredential
          ? _useTimestamp(now.add(lifetime))
          : null,
      'fieldExpiresAt': fields.isNotEmpty
          ? _useTimestamp(now.add(fieldLifetime ?? lifetime))
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
            approvedAt: now,
            expiresAt: now.add(fieldLifetime ?? lifetime),
            fields: recorded,
            events: [GrantEvent(GrantEventKind.approved, now)],
          );
    final fieldRequest = fields.isEmpty
        ? null
        : RequestHistory(
            id: id,
            sessionId: _service._sessionBindings[session]!,
            chatLabel: r.chatLabel,
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
    }

    await _service._saveUse(
      request: changed,
      fieldGrant: fieldGrant,
      fieldRequest: fieldRequest,
      validate: validate,
    );
    if (fields.isNotEmpty) {
      final request =
          _Request(
              id,
              session,
              r.purpose,
              Set.unmodifiable(r.fields),
              r.createdAt,
              r.requestExpiresAt,
            )
            ..approvedAt = now
            ..recordedFields = recorded
            ..history = fieldGrant
            ..state = AccessRequestState.approved
            ..grant = ClaimedGrant(
              _service._secret(),
              fields,
              now.add(fieldLifetime ?? lifetime),
            );
      _service._requests[id] = request;
      _service._grants[request.grant!.token] = request;
    }
  });
}
