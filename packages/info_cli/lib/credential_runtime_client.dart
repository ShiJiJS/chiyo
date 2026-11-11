part of 'agent_client.dart';

typedef CredentialProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> argv,
      String cwd,
      Map<String, String> environment,
    );
Future<Process> _startCredentialProcess(
  String executable,
  List<String> argv,
  String cwd,
  Map<String, String> environment, {
  String? workerExecutable,
  String? plannedJobName,
  Future<void> Function(int workerPid)? registerWorker,
}) async {
  if (!Platform.isWindows && !Platform.isMacOS) {
    throw const CredentialUseFailure('unsupported_tool_version');
  }
  final worker = await RuntimeWorkerCommand.resolve(
    workerExecutable: workerExecutable,
  );
  final state = File(
    '${environment[Platform.isMacOS ? 'TMPDIR' : 'TEMP']}/worker-state.json',
  );
  final nonce = base64Url.encode(
    List.generate(24, (_) => Random.secure().nextInt(256)),
  );
  final jobName = plannedJobName ?? CredentialProcessJob.nameFor(nonce);
  final process = await Process.start(
    worker.executable,
    worker.arguments,
    workingDirectory: cwd,
    environment: environment,
    includeParentEnvironment: false,
    runInShell: false,
  );
  final workerIdentity = CredentialProcessIdentity.capture(process.pid);
  final workerCreatedAt = workerIdentity?.value;
  workerIdentity?.close();
  var stopped = false;
  final ended = process.exitCode.then((code) {
    stopped = true;
    return code;
  });
  process.stdin.writeln(
    jsonEncode({
      'executable': executable,
      'argv': argv,
      'cwd': cwd,
      'statePath': state.path,
      'jobName': jobName,
    }),
  );
  await process.stdin.flush();
  var released = false;
  CredentialProcessJob? launchJob;
  while (!stopped) {
    try {
      final facts =
          jsonDecode(
                await File(
                  '${state.path}${released ? '.started' : ''}',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      if (!released &&
          facts['state'] == 'ready' &&
          facts['jobName'] == jobName &&
          facts['workerPid'] == process.pid) {
        try {
          if (facts['receiptVersion'] != 2) {
            throw const CredentialUseFailure('process_start_failed');
          }
          launchJob = CredentialProcessJob.observe(jobName, process.pid);
          await registerWorker?.call(process.pid);
          // Once any acknowledgement write is attempted, a lost response is
          // not proof the worker did not start the target.
          released = true;
          process.stdin.writeln('start');
          await process.stdin.flush();
        } on Object {
          await process.stdin.close();
          if (released && launchJob != null) {
            throw _UncertainCredentialLaunch(process, launchJob);
          }
          await ended;
          await Future.wait([
            process.stdout.drain<void>(),
            process.stderr.drain<void>(),
          ]);
          launchJob?.close();
          rethrow;
        }
      }
      if (released &&
          facts['state'] == 'started' &&
          facts['jobName'] == jobName &&
          facts['pid'] is int) {
        try {
          final wrapped = _RuntimeWorkerProcess(
            process,
            facts['pid'] as int,
            state,
            jobName,
          );
          launchJob?.close();
          return wrapped;
        } on Object {
          if (launchJob != null) {
            throw _UncertainCredentialLaunch(process, launchJob);
          }
          rethrow;
        }
      }
    } on FileSystemException {
      // The worker has not atomically published its state yet.
    } on FormatException {
      // A not-yet-complete state is not evidence that the target started.
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await ended;
  await process.stdin.close();
  if (released && launchJob != null) {
    var confirmedNotStarted = false;
    try {
      confirmedNotStarted =
          (jsonDecode(await File('${state.path}.finished').readAsString())
                  as Map)['state'] ==
              'start_failed' &&
          CredentialProcessJob.isActive(
                jobName,
                workerPid: process.pid,
                workerCreatedAt: workerCreatedAt,
              ) ==
              false;
    } on Object {
      /* Missing final state is inconclusive. */
    }
    if (!confirmedNotStarted) {
      throw _UncertainCredentialLaunch(process, launchJob);
    }
  }
  launchJob?.close();
  await Future.wait([
    process.stdout.drain<void>(),
    process.stderr.drain<void>(),
  ]);
  throw const CredentialUseFailure('process_start_failed');
}

/// Owns the original job before the target PID was acknowledged. Keep draining
/// and holding the capacity/configuration even though no target identity can be
/// claimed. A dead worker does not imply its descendants ended.
class _UncertainCredentialLaunch implements Exception {
  _UncertainCredentialLaunch(this.worker, this.job);
  final Process worker;
  final CredentialProcessJob job;
  bool treeEnded = false;
  Future<void> monitor(_ExecutionOutput output) async {
    final out = worker.stdout
        .listen((data) => output.add('stdout', data))
        .asFuture<void>();
    final err = worker.stderr
        .listen((data) => output.add('stderr', data))
        .asFuture<void>();
    try {
      await worker.exitCode;
      await Future.wait([out, err]);
    } on Object {
      /* Still wait for a conclusive group-end fact. */
    }
    while (true) {
      try {
        if (job.activeProcesses == 0) break;
      } on Object {
        /* Inconclusive inspection retains the slot and material. */
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    treeEnded = true;
    job.close();
  }
}

class _RuntimeWorkerProcess implements Process {
  _RuntimeWorkerProcess(this.worker, this.pid, this.state, this.jobName) {
    try {
      _job = CredentialProcessJob.observe(jobName, pid, workerPid: worker.pid);
    } on Object {
      // The worker still owns its original job handle and monitors its tree.
      // A later worker failure without this handle must remain unknown.
    }
  }
  final Process worker;
  final File state;
  final String jobName;
  CredentialProcessJob? _job;
  bool treeEnded = false;
  @override
  final int pid;
  @override
  Stream<List<int>> get stdout => worker.stdout;
  @override
  Stream<List<int>> get stderr => worker.stderr;
  @override
  IOSink get stdin => worker.stdin;
  @override
  Future<int> get exitCode => _ended;
  late final Future<int> _ended = _wait();
  Future<int> _wait() async {
    await worker.exitCode;
    try {
      final job = _job;
      if (job != null) {
        await job.waitUntilEmpty();
        treeEnded = true;
      }
    } finally {
      _job?.close();
      _job = null;
    }
    final facts =
        jsonDecode(await File('${state.path}.finished').readAsString())
            as Map<String, dynamic>;
    if (facts['state'] != 'exited' ||
        facts['pid'] != pid ||
        facts['jobName'] != jobName ||
        facts['exitCode'] is! int) {
      throw const CredentialUseFailure('execution_unknown');
    }
    treeEnded =
        true; // The worker wrote exited only after its job became empty.
    return facts['exitCode'] as int;
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;
}

extension _CredentialRuntimeClient on AgentClient {
  Future<Map<String, dynamic>> _executeCredentialCommand(
    Map<String, dynamic> submitted,
  ) async {
    // New requests and operations use reusable authorization. Explicit v1 is
    // retained only for historical clients/records, never an automatic fallback.
    // Execution queries without a version infer it from the stored record.
    final input =
        !submitted.containsKey('protocolVersion') &&
            {
              'request-use',
              'run-use',
              'operation-status',
              'fill-use',
              'fill-status',
              'focus-target',
            }.contains(submitted['command'])
        ? <String, dynamic>{...submitted, 'protocolVersion': 2}
        : submitted;
    try {
      if (utf8.encode(jsonEncode(input)).length > 262143) {
        throw const CredentialUseFailure('limit_exceeded');
      }
      final command = input['command'];
      final version = input['protocolVersion'] ?? 1;
      if (input.containsKey('protocolVersion') &&
          (input['protocolVersion'] is! int || !{1, 2}.contains(version))) {
        throw const CredentialUseFailure('unsupported_protocol');
      }
      final allowed = switch (command) {
        'focus-target' => {'protocolVersion', 'command'},
        'request-use' => {
          'protocolVersion',
          'command',
          'purpose',
          'credentials',
          'launch',
          'readFields',
          'fill',
          'agentName',
          'externalChatId',
          'submissionVersion',
        },
        'fill-use' || 'fill-status' => {
          'protocolVersion',
          'command',
          'requestId',
          'operationId',
        },
        'run-use' || 'operation-status' => {
          'protocolVersion',
          'command',
          'requestId',
          if (version == 2) ...{'operationId', 'launch'},
        },
        'execution-output' => {
          'protocolVersion',
          'command',
          'executionId',
          'cursor',
          'limit',
        },
        _ => {'protocolVersion', 'command', 'executionId'},
      };
      if (input.keys.any((k) => !allowed.contains(k))) {
        throw const CredentialUseFailure('unknown_field');
      }
      if (_session == null) {
        throw const CredentialUseFailure('session_required');
      }
      if (_remote != null && input['protocolVersion'] == 1) {
        throw const CredentialUseFailure('unsupported_protocol');
      }
      final filling =
          command == 'fill-use' ||
          command == 'fill-status' ||
          command == 'focus-target' ||
          input.containsKey('fill');
      if (filling && version != 2) {
        throw const CredentialUseFailure('unsupported_protocol');
      }
      if (version == 2) {
        await _requireReusableCredentialCapability(
          focusedFill: filling,
          focusedTarget: command == 'focus-target',
        );
      }
      if (command == 'focus-target') {
        FocusedFillTargetQuery.fromJson(input);
        final result = await _call('/credential-use/focus-target', {
          'sessionSecret': _session,
          ...input,
        });
        return result['status'] == 'ok'
            ? Map<String, dynamic>.from(
                FocusedFillTarget.fromJson(result).toJson(),
              )
            : result;
      }
      if (command == 'request-use') {
        if (filling) {
          FocusedFillInput.fromJson(input);
        } else {
          CredentialUseInput.fromJson(input);
        }
        final prepared = _remote != null && !filling
            ? await DeviceCredentialLaunch.prepare(
                CredentialUseInput.fromJson(input).launch,
              )
            : null;
        return await _call(
          prepared == null
              ? '/credential-use/request'
              : '/credential-use/device/request',
          {
            'sessionSecret': _session,
            ...input,
            if (prepared != null) 'deviceLaunch': prepared.toPrivateJson(),
          },
        );
      }
      if (command == 'fill-use' || command == 'fill-status') {
        FocusedFillOperationInput.fromJson(input);
        final result = await _call(
          command == 'fill-use'
              ? '/credential-use/fill'
              : '/credential-use/fill/status',
          {'sessionSecret': _session, ...input},
        );
        if (command == 'fill-use' &&
            result['status'] == 'service_unavailable' &&
            !result.containsKey('operationClaimed')) {
          return {
            ...const CredentialUseFailure(
              'fill_unknown',
              attemptConsumed: true,
            ).toJson(protocolVersion: 2),
            'requestId': input['requestId'],
            'operationId': input['operationId'],
          };
        }
        return result;
      }
      CredentialOperationInput? operation;
      if (command == 'operation-status' ||
          command == 'run-use' && version == 2) {
        operation = CredentialOperationInput.fromJson({
          ...input,
          'command': 'run-use',
        });
      }
      if (command == 'operation-status') {
        return await _lookupCredentialOperation(operation!);
      }
      final identity =
          input[command == 'run-use' ? 'requestId' : 'executionId'];
      if (identity is! String ||
          identity.isEmpty ||
          identity.length > 128 ||
          identity.codeUnits.any((c) => c < 33 || c > 126)) {
        throw const CredentialUseFailure('invalid_reference');
      }
      if (hostedCredentialExecutions) {
        if (_remote != null && deviceFileStateDirectory == null) {
          throw const CredentialUseFailure('service_unavailable');
        }
        final result = _remote != null
            ? await DeviceCredentialHost(
                _remote.profile,
                deviceFileStateDirectory!,
                workerExecutable: _runtimeWorkerExecutable,
              ).execute(_session!, input)
            : await _call('/credential-use/hosted', {
                'sessionSecret': _session,
                ...input,
              });
        if (command == 'run-use' &&
            result['status'] == 'service_unavailable' &&
            !result.containsKey(
              version == 2 ? 'operationClaimed' : 'attemptConsumed',
            )) {
          // A lost response is not proof that the resident executor did not
          // reserve the original attempt. Never fall back to another launch.
          throw const CredentialUseFailure(
            'material_claim_failed',
            attemptConsumed: true,
          );
        }
        return result;
      }
      switch (command) {
        case 'run-use':
          return await _credentialExecutions.start(
            identity,
            operation: operation,
          );
        case 'execution-status':
          final status = await _call(
            _remote == null
                ? '/credential-use/execution/status'
                : '/credential-use/device/execution/status',
            {'sessionSecret': _session, 'executionId': identity},
          );
          if (status['status'] == 'ok') {
            final local = _credentialExecutions.outputs[identity];
            status['outputAvailable'] = local != null;
            status['outputTruncated'] = local?.truncated ?? false;
          }
          return status;
        case 'execution-output':
          if (input.containsKey('cursor') && input['cursor'] is! int ||
              input.containsKey('limit') && input['limit'] is! int) {
            throw const CredentialUseFailure('invalid_type');
          }
          // Authorization is checked even for a local memory buffer.
          final status = await _call(
            _remote == null
                ? '/credential-use/execution/status'
                : '/credential-use/device/execution/status',
            {'sessionSecret': _session, 'executionId': identity},
          );
          if (status['status'] != 'ok') return status;
          return {
            ..._credentialExecutions.output(
              identity,
              input['cursor'] ?? 0,
              input['limit'] ?? 16,
            ),
            'protocolVersion': status['protocolVersion'] ?? 1,
          };
        case 'cleanup-use':
          if (_remote != null) {
            await _deviceCredentialJournal?.maintain();
            return await _call('/credential-use/device/execution/status', {
              'sessionSecret': _session,
              'executionId': identity,
            });
          }
          return await _call('/credential-use/cleanup', {
            'sessionSecret': _session,
            'executionId': identity,
          });
      }
      throw const CredentialUseFailure('invalid_plan');
    } on CredentialUseFailure catch (e) {
      return Map<String, dynamic>.from(
        e.toJson(protocolVersion: input['protocolVersion'] == 2 ? 2 : 1),
      );
    } on Object {
      return Map<String, dynamic>.from(
        const CredentialUseFailure(
          'invalid_type',
        ).toJson(protocolVersion: input['protocolVersion'] == 2 ? 2 : 1),
      );
    }
  }

  Future<void> _requireReusableCredentialCapability({
    bool focusedFill = false,
    bool focusedTarget = false,
  }) async {
    final result = await _call('/capabilities', {});
    if (result['status'] == 'service_unavailable') {
      throw const CredentialUseFailure('service_unavailable');
    }
    if (result['status'] != 'ok' ||
        result['protocolVersions'] is! List ||
        !(result['protocolVersions'] as List).contains(2) ||
        result['capabilities'] is! List ||
        !(result['capabilities'] as List).contains(
          _remote == null
              ? 'credential-use-reuse.v1'
              : 'credential-device-execution.v1',
        ) ||
        focusedFill &&
            !(result['capabilities'] as List).contains(
              'credential-focused-fill.v1',
            ) ||
        focusedTarget &&
            !(result['capabilities'] as List).contains(
              'credential-focused-target.v1',
            )) {
      throw const CredentialUseFailure('unsupported_capability');
    }
  }

  Future<Map<String, dynamic>> _lookupCredentialOperation(
    CredentialOperationInput input,
  ) async {
    final result = await _call(
      _remote == null
          ? '/credential-use/operation/status'
          : '/credential-use/device/operation/status',
      {'sessionSecret': _session, ...input.toJson()},
    );
    return result.containsKey('protocolVersion')
        ? result
        : Map<String, dynamic>.from(
            const CredentialUseFailure(
              'service_unavailable',
            ).toJson(protocolVersion: 2),
          );
  }

  Future<CredentialOperationClaim> _claimCredentialOperation(
    CredentialOperationInput input,
  ) async {
    if (_remote != null) {
      if (_deviceCredentialJournal == null) {
        throw const CredentialUseFailure('service_unavailable');
      }
      final prepared = await DeviceCredentialLaunch.prepare(input.launch);
      final jobName = CredentialProcessJob.nameFor(
        base64Url.encode(
          List.generate(24, (_) => Random.secure().nextInt(256)),
        ),
      );
      final decoded = await _call('/credential-use/device/operation', {
        'sessionSecret': _session,
        ...input.toJson(),
        'deviceLaunch': prepared.toPrivateJson(),
        'deviceJob': jobName,
      });
      if (decoded['status'] != 'ok') {
        final explicit = decoded['errorCode'] is String;
        throw CredentialUseFailure(
          explicit ? decoded['errorCode'] as String : 'material_claim_failed',
          attemptConsumed: !explicit || decoded['operationClaimed'] == true,
          executionId: decoded['executionId'] as String?,
        );
      }
      try {
        final claim = CredentialOperationClaim.fromPrivateJson(
          Map<String, dynamic>.from(decoded)..remove('status'),
        );
        if (claim.execution.requestId != input.requestId ||
            claim.execution.operationId != input.operationId ||
            claim.execution.operationFingerprint != input.fingerprint ||
            claim.material != null &&
                (claim.material!.materialLease != null ||
                    claim.material!.jobName != jobName)) {
          throw const FormatException();
        }
        return claim;
      } on Object {
        throw const CredentialUseFailure(
          'material_claim_failed',
          attemptConsumed: true,
        );
      }
    }
    var mayBeClaimed = false, explicitFailure = false;
    try {
      final request = await _http.post(
        '127.0.0.1',
        port,
        '/credential-use/operation',
      );
      _authenticateLocalCredentialRequest(request);
      request.headers.contentType = ContentType.json;
      request.followRedirects = false;
      final supervisor = _usesDefaultCredentialStarter
          ? CredentialProcessIdentity.capture(pid)
          : null;
      if (_usesDefaultCredentialStarter && supervisor == null) {
        throw const CredentialUseFailure('service_unavailable');
      }
      try {
        request.write(
          jsonEncode({
            'sessionSecret': _session,
            ...input.toJson(),
            if (supervisor != null) ...{
              'supervisorPid': pid,
              'supervisorCreatedAt': supervisor.value,
            },
          }),
        );
      } finally {
        supervisor?.close();
      }
      mayBeClaimed = true;
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      _verifyLocalCredentialResponse(response);
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 5))) {
        if (bytes.length + chunk.length > 4194304) {
          throw const FormatException();
        }
        bytes.addAll(chunk);
      }
      final decoded = decodeProtocolObject(
        utf8.decode(bytes),
        maxBytes: 4194304,
      );
      if (decoded['protocolVersion'] == 2 &&
          decoded['errorCode'] is String &&
          decoded['status'] is String) {
        explicitFailure = true;
        throw CredentialUseFailure(
          decoded['errorCode'] as String,
          attemptConsumed: decoded['operationClaimed'] == true,
          executionId: decoded['executionId'] as String?,
        );
      }
      final claim = CredentialOperationClaim.fromPrivateJson(decoded);
      if (claim.execution.requestId != input.requestId ||
          claim.execution.operationId != input.operationId ||
          claim.execution.operationFingerprint != input.fingerprint) {
        throw const FormatException();
      }
      return claim;
    } on Object catch (e) {
      if (e is CredentialUseFailure && (explicitFailure || !mayBeClaimed)) {
        rethrow;
      }
      // No retry/fallback after a missing or malformed private claim. A later
      // query can recover the operation facts, never a second material bundle.
      throw CredentialUseFailure(
        mayBeClaimed ? 'material_claim_failed' : 'service_unavailable',
        attemptConsumed: mayBeClaimed,
      );
    }
  }

  Future<CredentialExecutionMaterial> _consumeCredentialMaterial(
    String id,
  ) async {
    if (_remote != null) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    var mayBeConsumed = false;
    try {
      final request = await _http.post(
        '127.0.0.1',
        port,
        '/credential-use/consume',
      );
      _authenticateLocalCredentialRequest(request);
      request.headers.contentType = ContentType.json;
      request.followRedirects = false;
      final supervisor = _usesDefaultCredentialStarter
          ? CredentialProcessIdentity.capture(pid)
          : null;
      if (_usesDefaultCredentialStarter && supervisor == null) {
        throw const CredentialUseFailure('service_unavailable');
      }
      try {
        request.write(
          jsonEncode({
            'sessionSecret': _session,
            'requestId': id,
            if (supervisor != null) ...{
              'supervisorPid': pid,
              'supervisorCreatedAt': supervisor.value,
            },
          }),
        );
      } finally {
        supervisor?.close();
      }
      mayBeConsumed = true;
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      _verifyLocalCredentialResponse(response);
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 5))) {
        if (bytes.length + chunk.length > 4194304) {
          throw const FormatException();
        }
        bytes.addAll(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (decoded['status'] != 'ok') {
        throw CredentialUseFailure(
          decoded['errorCode'] as String? ?? 'service_unavailable',
          attemptConsumed: decoded['attemptConsumed'] == true,
          executionId: decoded['executionId'] as String?,
        );
      }
      return CredentialExecutionMaterial.fromPrivateJson(decoded);
    } on CredentialUseFailure {
      rethrow;
    } on Object {
      // Once sent, losing the response cannot prove that the audit transaction
      // rolled back. The caller must query the original request, never launch a
      // replacement or advertise this attempt as safely unconsumed.
      throw CredentialUseFailure(
        mayBeConsumed ? 'material_claim_failed' : 'service_unavailable',
        attemptConsumed: mayBeConsumed,
      );
    }
  }

  void _authenticateLocalCredentialRequest(HttpClientRequest request) {
    final profile = _local?.profile;
    if (profile == null) return;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${profile.deviceToken}',
    );
    request.headers.set('x-chiyo-server-id', profile.serverId);
  }

  void _verifyLocalCredentialResponse(HttpClientResponse response) {
    final profile = _local?.profile;
    if (profile != null &&
        response.headers.value('x-chiyo-server-id') != profile.serverId) {
      throw const FormatException('Local library identity mismatch');
    }
  }

  Future<void> _reportCredentialExecution(
    CredentialExecutionReport report,
  ) async {
    final result = await _call(
      _remote == null
          ? '/credential-use/execution/report'
          : '/credential-use/device/execution/report',
      report.toPrivateJson(),
    );
    if (result['status'] != 'ok') {
      throw const CredentialUseFailure(
        'audit_unavailable',
        attemptConsumed: true,
      );
    }
  }
}

class _ExecutionOutput {
  _ExecutionOutput({List<List<int>> secretPatterns = const []})
    : _secretPatterns = secretPatterns;
  List<List<int>> _secretPatterns;
  final _filters = <String, CredentialOutputFilter>{};
  int _rawBytes = 0;
  final chunks = <Map<String, Object?>>[];
  int bytes = 0;
  bool truncated = false, complete = false, active = true;
  DateTime? finishedAt;
  void add(String stream, List<int> data) {
    final remaining = 4194304 - _rawBytes;
    if (data.length > remaining) truncated = true;
    final length = data.length.clamp(0, remaining);
    _rawBytes += length;
    if (length == 0) return;
    final accepted = length == data.length ? data : data.sublist(0, length);
    _append(
      stream,
      _secretPatterns.isEmpty
          ? accepted
          : _filters
                .putIfAbsent(
                  stream,
                  () => CredentialOutputFilter(_secretPatterns),
                )
                .add(accepted),
    );
  }

  void finish() {
    if (complete) return;
    for (final entry in _filters.entries) {
      _append(entry.key, entry.value.finish());
    }
    _filters.clear();
    _secretPatterns = const [];
    complete = true;
  }

  void _append(String stream, List<int> data) {
    final remaining = 4194304 - bytes;
    if (data.length > remaining) truncated = true;
    final length = data.length.clamp(0, remaining);
    for (var i = 0; i < length; i += 4096) {
      final end = (i + 4096).clamp(0, length);
      chunks.add({
        'seq': chunks.length,
        'stream': stream,
        'dataBase64': base64Encode(data.sublist(i, end)),
      });
    }
    bytes += length;
  }
}

List<List<int>> _credentialOutputPatterns(
  CredentialExecutionMaterial material,
) {
  final bytes = material.credentialMaterial.bytes;
  final patterns = <List<int>>[List<int>.of(bytes)];
  if (material.credentialMaterial.form == CredentialForm.file) {
    try {
      final text = utf8.decode(bytes),
          lines = const LineSplitter().convert(text);
      if (material.approvedPlan.receiver == 'aws_shared_credentials') {
        for (final line in lines) {
          final match = RegExp(
            r'^\s*(aws_access_key_id|aws_secret_access_key|aws_session_token)\s*=\s*(.*?)\s*$',
          ).firstMatch(line);
          if (match != null && match[2]!.isNotEmpty) {
            patterns.add(utf8.encode(match[2]!));
          }
        }
      } else if (text.startsWith('-----BEGIN ') && lines.length <= 128) {
        for (final line in lines) {
          if (line.isNotEmpty && !line.startsWith('-----')) {
            patterns.add(utf8.encode(line));
          }
        }
      }
    } on FormatException {
      // Arbitrary binary material has only an exact whole-byte pattern.
    }
  }
  final seen = <String>{};
  return patterns
      .where((p) => p.isNotEmpty && seen.add(base64Encode(p)))
      .toList();
}

class _CredentialRuntimeExecutor {
  _CredentialRuntimeExecutor(this.client);
  final AgentClient client;
  final outputs = <String, _ExecutionOutput>{};
  final running = <Future<void>>{};
  int reservations = 0;
  void prune() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 30));
    outputs.removeWhere((_, o) => !o.active && o.finishedAt!.isBefore(cutoff));
    while (outputs.length + reservations >= 16) {
      final ended = outputs.entries.where((e) => !e.value.active).toList()
        ..sort((a, b) => a.value.finishedAt!.compareTo(b.value.finishedAt!));
      if (ended.isEmpty) break;
      outputs.remove(ended.first.key);
    }
  }

  Future<Map<String, dynamic>> start(
    String id, {
    CredentialOperationInput? operation,
  }) async {
    if (!Platform.isWindows &&
        !Platform.isMacOS &&
        client._usesDefaultCredentialStarter) {
      throw const CredentialUseFailure('unsupported_tool_version');
    }
    if (operation != null) {
      final existing = await client._lookupCredentialOperation(operation);
      if (existing['status'] != 'not_found') return existing;
    }
    prune();
    if (outputs.length + reservations >= 16) {
      throw const CredentialUseFailure('execution_capacity');
    }
    reservations++;
    late CredentialExecutionMaterial material;
    try {
      if (operation == null) {
        material = await client._consumeCredentialMaterial(id);
      } else {
        final claim = await client._claimCredentialOperation(operation);
        if (!claim.newlyClaimed) {
          return Map<String, dynamic>.from(claim.toPublicJson());
        }
        material = claim.material!;
      }
    } finally {
      reservations--;
    }
    final output = _ExecutionOutput(
      secretPatterns: operation == null
          ? const []
          : _credentialOutputPatterns(material),
    );
    outputs[material.executionId] = output;
    late Future<void> work;
    work = Future<void>(
      () => _launch(material, output),
    ).whenComplete(() => running.remove(work));
    running.add(work);
    return {
      'protocolVersion': operation == null ? 1 : 2,
      'status': 'accepted',
      'requestId': id,
      'executionId': material.executionId,
      if (operation == null)
        'attemptConsumed': true
      else ...{
        'operationId': operation.operationId,
        'operationClaimed': true,
        'duplicate': false,
        'grantState': 'available',
      },
      'processStarted': false,
      'executionState': 'preparing',
    };
  }

  Future<void> drain() async {
    while (running.isNotEmpty) {
      await Future.wait(running.toList());
    }
  }

  Map<String, dynamic> output(String id, Object cursor, Object limit) {
    if (cursor is! int || limit is! int || limit < 1 || limit > 16) {
      throw const CredentialUseFailure('invalid_type');
    }
    final o = outputs[id];
    if (o == null) throw const CredentialUseFailure('output_unavailable');
    if (cursor < 0 || cursor > o.chunks.length) {
      throw const CredentialUseFailure('cursor_out_of_range');
    }
    final chunks = o.chunks.skip(cursor).take(limit).toList();
    return {
      'protocolVersion': 1,
      'status': 'ok',
      'executionId': id,
      'chunks': chunks,
      'nextCursor': cursor + chunks.length,
      'hasMore': cursor + chunks.length < o.chunks.length,
      'outputComplete': o.complete,
      'outputTruncated': o.truncated,
    };
  }

  Future<void> _launch(
    CredentialExecutionMaterial m,
    _ExecutionOutput output,
  ) async {
    Directory? folder;
    Process? process;
    CredentialProcessIdentity? processIdentity;
    DateTime? started;
    String? created;
    Future<void>? stdoutDone, stderrDone;
    File? journal;
    DeviceCredentialJournalEntry? deviceJournal;
    var materialLease = m.materialLease;
    var registeredFiles = false;
    var preparing = true;
    _UncertainCredentialLaunch? uncertainLaunch;
    Future<void> report(String state, {String? code, int? exit}) async {
      await journal?.writeAsString(
        jsonEncode({
          'executionId': m.executionId,
          'state': state,
          'pid': process?.pid,
          'processCreatedAt': created,
          if (process is _RuntimeWorkerProcess) 'jobName': process.jobName,
          'cleanupState': 'not_needed',
        }),
        flush: true,
      );
      var value = CredentialExecutionReport(
        executionId: m.executionId,
        executionCapability: m.executionCapability,
        state: state,
        pid: process?.pid,
        processCreatedAt: created,
        exitCode: exit,
        errorCode: code,
        startedAt: started,
        finishedAt: {'running', 'unknown'}.contains(state)
            ? null
            : DateTime.now().toUtc(),
        jobName:
            m.jobName ??
            (process is _RuntimeWorkerProcess ? process.jobName : null),
      );
      if (deviceJournal != null) {
        value = await deviceJournal.rememberReport(value);
      }
      await client._reportCredentialExecution(value);
    }

    try {
      if (client._remote != null) {
        final store = client._deviceCredentialJournal;
        if (store == null) {
          throw const CredentialUseFailure('material_prepare_failed');
        }
        deviceJournal = await store.begin(m);
      }
      final plan = m.approvedPlan;
      final tokenReceiver = plan.receiver == 'gh_token';
      final awsReceiver = plan.receiver == 'aws_shared_credentials';
      final sshReceiver = plan.receiver == 'ssh_identity';
      final binding =
          plan.env[tokenReceiver ? 'GH_TOKEN' : 'AWS_SHARED_CREDENTIALS_FILE'];
      if (tokenReceiver &&
          (m.credentialMaterial.form != CredentialForm.string ||
              binding?.kind != LaunchValueKind.secret ||
              binding?.value != m.alias ||
              m.credentialMaterial.bytes.isEmpty ||
              m.credentialMaterial.stringValue.isEmpty)) {
        throw const CredentialUseFailure('material_prepare_failed');
      }
      if (!tokenReceiver) {
        if (client._remote != null && materialLease == null) {
          materialLease = ManagedCredentialFiles.create();
          await deviceJournal!.rememberLease(materialLease);
        }
        if ((!awsReceiver && !sshReceiver) ||
            m.credentialMaterial.form != CredentialForm.file ||
            materialLease == null ||
            materialLease.files.isNotEmpty) {
          throw const CredentialUseFailure('material_prepare_failed');
        }
        if (awsReceiver &&
            (binding?.kind != LaunchValueKind.file ||
                binding?.value != m.alias ||
                plan.env['AWS_CONFIG_FILE']?.kind !=
                    LaunchValueKind.internalMaterial ||
                plan.env['AWS_CONFIG_FILE']?.value != 'aws_config')) {
          throw const CredentialUseFailure('material_prepare_failed');
        }
        if (awsReceiver) {
          validateAwsSharedCredentialFile(m.credentialMaterial.bytes);
        }
        if (sshReceiver) {
          final hosts = m.internalMaterials['ssh_known_hosts'];
          if (plan.env.isNotEmpty ||
              m.credentialMaterial.bytes.isEmpty ||
              hosts == null ||
              plan.sshTrustSnapshotId == null ||
              plan.internalMaterialHashes['ssh_known_hosts'] !=
                  'sha256:${sha256.convert(hosts)}' ||
              plan.internalMaterialHashes['ssh_config'] !=
                  'sha256:${sha256.convert(const <int>[])}' ||
              plan.internalMaterialHashes['ssh_global_known_hosts'] !=
                  'sha256:${sha256.convert(const <int>[])}') {
            throw const CredentialUseFailure('material_prepare_failed');
          }
        }
        materialLease = ManagedCredentialFiles.reserve(
          materialLease,
          awsReceiver
              ? ['credential.bin', 'aws-config']
              : [
                  'credential.bin',
                  'ssh-config',
                  'known-hosts',
                  'global-known-hosts',
                ],
        );
        await deviceJournal?.rememberLease(materialLease);
        final registration = await client._call(
          client._remote == null
              ? '/credential-use/materials/register'
              : '/credential-use/device/materials/register',
          {
            'executionId': m.executionId,
            'executionCapability': m.executionCapability,
            'lease': materialLease.toPrivateJson(),
          },
        );
        if (registration['status'] != 'ok') {
          throw const CredentialUseFailure(
            'audit_unavailable',
            attemptConsumed: true,
          );
        }
        registeredFiles = true;
        ManagedCredentialFiles.write(
          materialLease,
          'credential.bin',
          m.credentialMaterial.bytes,
        );
        if (awsReceiver) {
          ManagedCredentialFiles.write(materialLease, 'aws-config', const []);
        }
        if (sshReceiver) {
          ManagedCredentialFiles.write(materialLease, 'ssh-config', const []);
          ManagedCredentialFiles.write(
            materialLease,
            'known-hosts',
            m.internalMaterials['ssh_known_hosts']!,
          );
          ManagedCredentialFiles.write(
            materialLease,
            'global-known-hosts',
            const [],
          );
        }
      }
      folder = await Directory.systemTemp.createTemp('info-runtime-');
      journal = File('${folder.path}/journal.json');
      await journal.writeAsString(
        jsonEncode({
          'executionId': m.executionId,
          'state': 'preparing',
          'cleanupState': 'not_needed',
        }),
        flush: true,
      );
      final config = await Directory('${folder.path}/config').create();
      final temp = await Directory('${folder.path}/temp').create();
      final programData = await Directory(
        '${folder.path}/program-data',
      ).create();
      final env = <String, String>{
        'HOME': config.path,
        'USERPROFILE': config.path,
        'APPDATA': config.path,
        'LOCALAPPDATA': config.path,
        'XDG_CONFIG_HOME': config.path,
        if (tokenReceiver) ...{
          'GH_CONFIG_DIR': config.path,
          'GH_HOST': 'github.com',
          'GH_PROMPT_DISABLED': '1',
          'GH_TOKEN': m.credentialMaterial.stringValue,
        } else if (awsReceiver) ...{
          'AWS_SHARED_CREDENTIALS_FILE':
              '${materialLease!.path}${Platform.pathSeparator}credential.bin',
          'AWS_CONFIG_FILE':
              '${materialLease.path}${Platform.pathSeparator}aws-config',
          'AWS_EC2_METADATA_DISABLED': 'true',
          'AWS_PAGER': '',
          'AWS_CLI_AUTO_PROMPT': 'off',
        },
      };
      if (Platform.isWindows) {
        final system = Platform.environment['SystemRoot'];
        if (system == null || system.isEmpty) {
          throw const CredentialUseFailure('material_prepare_failed');
        }
        env.addAll({
          'SystemRoot': system,
          'WINDIR': system,
          'COMSPEC': '$system\\System32\\cmd.exe',
          'TEMP': temp.path,
          'TMP': temp.path,
          'PATH': '$system\\System32;${File(plan.path).parent.path}',
          'ProgramData': programData.path,
        });
      } else {
        env.addAll({
          'PATH': '/usr/bin:/bin',
          'TMPDIR': temp.path,
          'LANG': 'C.UTF-8',
        });
      }
      final file = File(plan.path);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size != plan.executable.byteLength ||
          stat.modified.microsecondsSinceEpoch !=
              plan.executable.modifiedMicros ||
          'sha256:${sha256.convert(await file.readAsBytes())}' !=
              plan.executable.sha256) {
        throw const CredentialUseFailure('executable_changed');
      }
      if (!await Directory(plan.cwd).exists()) {
        throw const CredentialUseFailure('material_prepare_failed');
      }
      String materialPath(String name) =>
          '${materialLease!.path}${Platform.pathSeparator}$name';
      String hostsOption(String option, String file) =>
          '$option="${materialPath(file).replaceAll('\\', '/')}"';
      String resolveArgument(LaunchValue value) => switch (value.kind) {
        LaunchValueKind.literal => value.value,
        LaunchValueKind.file when sshReceiver && value.value == m.alias =>
          materialPath('credential.bin'),
        LaunchValueKind.internalMaterial when sshReceiver =>
          switch (value.value) {
            'ssh_config' => materialPath('ssh-config'),
            'ssh_user_hosts_option' => hostsOption(
              'UserKnownHostsFile',
              'known-hosts',
            ),
            'ssh_global_hosts_option' => hostsOption(
              'GlobalKnownHostsFile',
              'global-known-hosts',
            ),
            _ => throw const CredentialUseFailure('material_prepare_failed'),
          },
        _ => throw const CredentialUseFailure('material_prepare_failed'),
      };
      final argv = plan.argv.map(resolveArgument).toList();
      preparing = false;
      process = client._usesDefaultCredentialStarter
          ? await _startCredentialProcess(
              plan.path,
              argv,
              plan.cwd,
              env,
              workerExecutable: client._runtimeWorkerExecutable,
              plannedJobName: m.jobName,
              registerWorker: (workerPid) async {
                final identity = CredentialProcessIdentity.capture(workerPid);
                if (identity == null) {
                  throw const CredentialUseFailure('process_start_failed');
                }
                try {
                  await deviceJournal?.rememberWorker(
                    workerPid,
                    identity.value,
                  );
                  final result = await client._call(
                    client._remote == null
                        ? '/credential-use/worker/register'
                        : '/credential-use/device/worker/register',
                    {
                      'executionId': m.executionId,
                      'executionCapability': m.executionCapability,
                      'workerPid': workerPid,
                      'workerCreatedAt': identity.value,
                    },
                  );
                  if (result['status'] != 'ok') {
                    throw const CredentialUseFailure(
                      'audit_unavailable',
                      attemptConsumed: true,
                    );
                  }
                } finally {
                  identity.close();
                }
              },
            )
          : await client._credentialProcessStarter(
              plan.path,
              argv,
              plan.cwd,
              env,
            );
      // Drain immediately after OS creation, including when identity capture or
      // audit reporting fails. Neither failure ends the child's lifetime.
      stdoutDone = process.stdout
          .listen((data) => output.add('stdout', data))
          .asFuture<void>();
      stderrDone = process.stderr
          .listen((data) => output.add('stderr', data))
          .asFuture<void>();
      processIdentity = CredentialProcessIdentity.capture(process.pid);
      // Preserve the existing Windows control-channel timing. Only Darwin's
      // paused-target protocol needs the channel held through Core validation.
      if (!Platform.isMacOS) await process.stdin.close();
      try {
        started = DateTime.now().toUtc();
        created = processIdentity?.value;
        if (created == null) {
          throw const CredentialUseFailure('execution_unknown');
        }
        try {
          await report('running');
        } on Object {
          // Retry metadata only; the consumed launch is never retried.
          await report('running');
        }
      } finally {
        // Darwin keeps the actual target suspended until Core has verified
        // its identity. EOF also releases it after an uncertain report.
        if (Platform.isMacOS) await process.stdin.close();
      }
      final result = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      output.finish();
      await report('exited', exit: result);
    } on Object catch (e) {
      if (e is _UncertainCredentialLaunch) {
        uncertainLaunch = e;
        try {
          await report('unknown', code: 'execution_unknown');
        } on Object {
          /* Preserve monitoring despite an unavailable receipt. */
        }
        await e.monitor(output);
      }
      if (process != null) {
        // A reporting/identity failure cannot release a live process's slot or
        // dispose its isolated configuration while it still uses it.
        try {
          await process.exitCode;
        } on Object {
          // The supervisor can die without a trustworthy target exit result.
        }
        try {
          await Future.wait([?stdoutDone, ?stderrDone]);
        } on Object {
          // Preserve unknown rather than infer success from a closed pipe.
        }
      }
      final code = e is CredentialUseFailure
          ? e.code
          : preparing
          ? 'material_prepare_failed'
          : 'process_start_failed';
      try {
        await report(
          process != null ||
                  uncertainLaunch != null ||
                  code == 'execution_unknown'
              ? 'unknown'
              : preparing
              ? 'prepare_failed'
              : 'start_failed',
          code: process != null || uncertainLaunch != null
              ? 'execution_unknown'
              : code,
        );
      } on Object {
        /* No retry can start another process. */
      }
    } finally {
      processIdentity?.close();
      output.active = false;
      output.finishedAt = DateTime.now();
      output.finish();
      final treeEnded =
          (uncertainLaunch == null || uncertainLaunch.treeEnded) &&
          (process is! _RuntimeWorkerProcess || process.treeEnded);
      if (client._remote != null) {
        try {
          await deviceJournal?.finish(treeEnded: treeEnded);
        } on Object {
          // Retain proof and exact OS identities for later maintenance.
        }
      } else if (materialLease != null) {
        if (!registeredFiles && process == null) {
          try {
            ManagedCredentialFiles.cleanup(materialLease);
          } on Object {
            /* Only this invocation's verified empty files may be removed. */
          }
        }
        try {
          await client._call('/credential-use/cleanup', {
            'sessionSecret': client._session,
            'executionId': m.executionId,
          });
        } on Object {
          /* Persisted pending facts remain for recovery. */
        }
      }
      if (folder != null && treeEnded) {
        try {
          await folder.delete(recursive: true);
        } on Object {
          /* D6 contains no credential files. */
        }
      }
    }
  }
}
