part of 'agent_client.dart';

const _programBase = '/credential-use/program';

extension _ProgramClient on AgentClient {
  DeviceCredentialJournal get _programJournal =>
      _deviceCredentialJournal ??
      (throw const CredentialUseFailure('service_unavailable'));

  Future<Map<String, dynamic>> _programStatus(String operation) async {
    final result = await _call('/operations/show', {
      'sessionSecret': _session,
      'id': operation,
    });
    if (result['status'] == 'ok' && result['kind'] != 'credential-program') {
      throw const CredentialUseFailure('operation_conflict');
    }
    return result;
  }

  Future<Map<String, dynamic>> _existingProgram(
    Map<String, dynamic> input,
  ) async {
    final previous = await _programStatus(input['operationId'] as String);
    if (previous['status'] != 'ok' || input['requestId'] == null) {
      return previous;
    }
    if (previous['requestId'] != input['requestId']) {
      throw const CredentialUseFailure('operation_conflict');
    }
    final stored = CredentialProgramPlan.fromPreparedJson(
      previous['programPlan'] as Map<String, dynamic>,
    );
    Object? raw = input['launch'];
    if (raw == null) {
      final request = await _call('$_programBase/status', {
        'sessionSecret': _session,
        'requestId': input['requestId'],
      });
      if (request['programPlan'] is! Map<String, dynamic>) return request;
      raw = Map<String, dynamic>.from(request['programPlan'] as Map)
        ..remove('executableIdentity');
    }
    if (raw is! Map<String, dynamic>) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final requested = CredentialProgramPlan.fromJson(raw).withVersions({
      for (final binding in stored.bindings)
        binding.reference.credentialId: binding.reference.version!,
    });
    if (requested.path != stored.path ||
        requested.cwd != stored.cwd ||
        requested.resolved(stored.identity!, stored.cwd).planHash !=
            stored.planHash) {
      throw const CredentialUseFailure('operation_conflict');
    }
    return previous;
  }

  Future<Map<String, dynamic>> _observedProgram(
    Map<String, dynamic> input,
  ) async {
    final stored = await _existingProgram(input);
    if (stored['status'] != 'ok') return stored;
    final Map<String, dynamic> observed;
    if (hostedCredentialExecutions) {
      final profile = _remote?.profile ?? _local?.profile;
      if (profile == null || deviceFileStateDirectory == null) {
        return {...stored, 'outputState': 'unknown'};
      }
      observed = await DeviceCredentialHost(
        profile,
        deviceFileStateDirectory!,
        workerExecutable: _runtimeWorkerExecutable,
      ).inspectProgram(_session!, input);
      if (observed['status'] == 'output_unavailable') {
        return {
          ...stored,
          'outputAvailable': false,
          'outputComplete': false,
          'outputTruncated': false,
          'outputState': 'not_retained',
        };
      }
      if (observed['status'] != 'ok' ||
          observed['executionId'] != stored['executionId'] ||
          observed['outputAvailable'] is! bool ||
          observed['outputComplete'] is! bool ||
          observed['outputTruncated'] is! bool) {
        return {...stored, 'outputState': 'unknown'};
      }
    } else {
      observed = _programExecutions.outputMetadata(
        stored['executionId'] as String,
      );
    }
    return {
      ...stored,
      for (final key in [
        'outputAvailable',
        'outputComplete',
        'outputTruncated',
      ])
        key: observed[key],
      'outputState': observed['outputAvailable'] == true
          ? 'retained'
          : 'not_retained',
    };
  }

  Future<Map<String, dynamic>> _executeProgramCommand(
    Map<String, dynamic> input,
  ) async {
    try {
      final command = input['command'];
      final allowed = switch (command) {
        'program-request' => {
          'command',
          'operationId',
          'purpose',
          'title',
          'launch',
          'agentName',
          'externalChatId',
          'submissionVersion',
          'prepared',
        },
        'program-run' ||
        'program-status' => {'command', 'operationId', 'requestId', 'launch'},
        'program-output' => {'command', 'operationId', 'cursor', 'limit'},
        _ => {'command', 'operationId'},
      };
      if (input.keys.any((key) => !allowed.contains(key)) ||
          utf8.encode(jsonEncode(input)).length > 262144) {
        throw const CredentialUseFailure('unknown_field');
      }
      final operation = input['operationId'];
      if (operation is! String ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(operation)) {
        throw const CredentialUseFailure('invalid_reference');
      }
      if (_session == null) {
        throw const CredentialUseFailure('session_required');
      }
      final support = await _call('/capabilities', {});
      if (support['status'] != 'ok') return support;
      if (!(support['capabilities'] as List? ?? []).contains(
        'credential-programs.v3',
      )) {
        throw const CredentialUseFailure('unsupported_capability');
      }
      if (command == 'program-status') return await _observedProgram(input);
      if (command == 'program-request') {
        if (input['launch'] is! Map<String, dynamic> ||
            input['purpose'] is! String) {
          throw const CredentialUseFailure('invalid_plan');
        }
        final plan = CredentialProgramPlan.fromJson(
          input['launch'] as Map<String, dynamic>,
        );
        final prepared = input['prepared'] == null
            ? await DeviceCredentialLaunch.prepareProgram(plan)
            : DeviceCredentialLaunch.fromPrivateJson(
                input['prepared'] as Map<String, dynamic>,
              );
        prepared.resolveProgram(plan);
        return await _call('$_programBase/request', {
          'sessionSecret': _session,
          'operationId': operation,
          'prepared': prepared.toPrivateJson(),
          'input': {
            for (final key in [
              'purpose',
              'title',
              'launch',
              'agentName',
              'externalChatId',
              'submissionVersion',
            ])
              if (input.containsKey(key)) key: input[key],
          },
        });
      }
      if (hostedCredentialExecutions) {
        final profile = _remote?.profile ?? _local?.profile;
        if (profile == null || deviceFileStateDirectory == null) {
          throw const CredentialUseFailure('service_unavailable');
        }
        return await DeviceCredentialHost(
          profile,
          deviceFileStateDirectory!,
          workerExecutable: _runtimeWorkerExecutable,
        ).execute(_session!, input);
      }
      await _programJournal.maintain();
      if (command == 'program-run') {
        return await _programExecutions.start(input);
      }
      final status = await _programStatus(operation);
      if (status['status'] != 'ok') return status;
      if (command == 'program-output') {
        return {
          ..._programExecutions.output(
            status['executionId'] as String,
            input['cursor'] ?? 0,
            input['limit'] ?? 16,
          ),
          'protocolVersion': 3,
          'operationId': operation,
        };
      }
      // Cleanup only inspects the existing journal/process tree. It cannot
      // acquire another material response or launch a replacement worker.
      if (command == 'program-cleanup') return await _programStatus(operation);
      throw const CredentialUseFailure('invalid_plan');
    } on CredentialUseFailure catch (error) {
      return Map<String, dynamic>.from(error.toJson(protocolVersion: 3));
    } on Object {
      return Map<String, dynamic>.from(
        const CredentialUseFailure(
          'service_unavailable',
        ).toJson(protocolVersion: 3),
      );
    }
  }
}

/// Owns a single real process for an original multi-credential claim. It shares
/// the existing gated worker, OS identities, journal and bounded output rather
/// than converting each receiver into a separate legacy execution.
class _CredentialProgramExecutor extends _CredentialOutputStore {
  _CredentialProgramExecutor(this.client);
  final AgentClient client;
  final running = <Future<void>>{};

  Future<void> drain() async {
    while (running.isNotEmpty) {
      await Future.wait(running.toList());
    }
  }

  Future<Map<String, dynamic>> start(Map<String, dynamic> input) async {
    final operation = input['operationId'] as String;
    final existing = await client._existingProgram(input);
    if (existing['status'] != 'not_found') return existing;
    prune();
    if (outputs.length + reservations >= 16) {
      throw const CredentialUseFailure('execution_capacity');
    }
    final requestId = input['requestId'];
    if (requestId is! String) {
      throw const CredentialUseFailure('invalid_reference');
    }
    final request = await client._call('$_programBase/status', {
      'sessionSecret': client._session,
      'requestId': requestId,
    });
    if (request['programPlan'] is! Map<String, dynamic>) return request;
    final approved = CredentialProgramPlan.fromPreparedJson(
      request['programPlan'] as Map<String, dynamic>,
    );
    final original = Map<String, dynamic>.from(approved.toJson())
      ..remove('executableIdentity');
    final raw = input['launch'] ?? original;
    if (raw is! Map<String, dynamic>) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final plan = CredentialProgramPlan.fromJson(raw).withVersions({
      for (final binding in approved.bindings)
        binding.reference.credentialId: binding.reference.version!,
    });
    final prepared = await DeviceCredentialLaunch.prepareProgram(plan);
    prepared.resolveProgram(plan).requireApprovedScope(approved);
    final job = CredentialProcessJob.nameFor(
      base64Url.encode(List.generate(24, (_) => Random.secure().nextInt(256))),
    );
    reservations++;
    try {
      final claim = await client._call('$_programBase/begin', {
        'sessionSecret': client._session,
        'requestId': requestId,
        'operationId': operation,
        'launch': plan.toJson(),
        'prepared': prepared.toPrivateJson(),
        'jobName': job,
      });
      final rawMaterial = claim.remove('material');
      if (rawMaterial == null) return claim;
      final material = CredentialProgramMaterial.fromPrivateJson(
        rawMaterial as Map<String, dynamic>,
      );
      if (material.operationId != operation ||
          material.requestId != requestId ||
          material.jobName != job ||
          material.plan.planHash != prepared.resolveProgram(plan).planHash) {
        throw const CredentialUseFailure('execution_unknown');
      }
      final output = _ExecutionOutput(
        secretPatterns: [
          for (final value in material.materials.values.toSet()) value.bytes,
        ],
      );
      outputs[material.executionId] = output;
      late Future<void> work;
      work = Future<void>(
        () => _launch(material, output),
      ).whenComplete(() => running.remove(work));
      running.add(work);
      return {
        ...claim,
        'protocolVersion': 3,
        'status': 'accepted',
        'operationId': operation,
        'operationClaimed': true,
        'duplicate': false,
      };
    } finally {
      reservations--;
    }
  }

  Future<void> _launch(
    CredentialProgramMaterial material,
    _ExecutionOutput output,
  ) async {
    DeviceCredentialJournalEntry? journal;
    CredentialMaterialLease? lease;
    Directory? folder;
    Process? process;
    CredentialProcessIdentity? identity;
    Future<void>? stdoutDone, stderrDone;
    _UncertainCredentialLaunch? uncertain;
    DateTime? started;
    String? created;
    var preparing = true;
    Map<String, dynamic> getProof() => {
      'executionId': material.executionId,
      'executionCapability': material.executionCapability,
    };
    Future<void> requireCall(String suffix, Map<String, dynamic> body) async {
      final result = await client._call('$_programBase/$suffix', body);
      if (result['status'] != 'ok') {
        throw CredentialUseFailure(
          result['errorCode'] as String? ?? 'audit_unavailable',
        );
      }
    }

    Future<void> report(String state, {String? code, int? exitCode}) async {
      var value = CredentialExecutionReport(
        executionId: material.executionId,
        executionCapability: material.executionCapability,
        state: state,
        errorCode: code,
        exitCode: exitCode,
        pid: process?.pid,
        processCreatedAt: created,
        jobName: material.jobName,
        startedAt: started,
        finishedAt: {'running', 'unknown'}.contains(state)
            ? null
            : DateTime.now().toUtc(),
      );
      if (journal != null) value = await journal.rememberReport(value);
      await requireCall(
        'report',
        value.toPrivateJson().cast<String, dynamic>(),
      );
    }

    try {
      journal = await client._programJournal.beginProgram(material);
      await requireCall('authorize', getProof());
      final plan = material.plan;
      final bindingIds = <String, String>{
        for (var i = 0; i < plan.bindings.length; i++)
          plan.bindings[i].location: material.itemIds[i],
      };
      final fileNames = <String>[
        for (final binding in plan.bindings)
          if (binding.via == 'file')
            'credential-${bindingIds[binding.location]}.bin',
      ];
      if (fileNames.isNotEmpty) {
        lease = ManagedCredentialFiles.create();
        await journal.rememberLease(lease);
        lease = ManagedCredentialFiles.reserve(lease, fileNames);
        await journal.rememberLease(lease);
        await requireCall('materials/register', {
          ...getProof(),
          'lease': lease.toPrivateJson(),
        });
        for (final binding in plan.bindings) {
          if (binding.via == 'file') {
            final id = bindingIds[binding.location]!;
            ManagedCredentialFiles.write(
              lease,
              'credential-$id.bin',
              material.materials[id]!.bytes,
            );
          }
        }
      }
      folder = await Directory.systemTemp.createTemp('chiyo-program-');
      final workerEnv = await _isolatedCredentialEnvironment(folder, plan.path);
      String resolve(
        CredentialProgramValue value,
        String location,
      ) => switch (value.kind) {
        CredentialProgramValueKind.literal => value.literal!,
        CredentialProgramValueKind.material =>
          material.materials[bindingIds[location]]!.stringValue,
        CredentialProgramValueKind.file =>
          '${lease!.path}${Platform.pathSeparator}credential-${bindingIds[location]}.bin',
      };
      final targetEnv = <String, String>{...workerEnv};
      for (final entry in plan.env.entries) {
        if (Platform.isWindows) {
          targetEnv.removeWhere(
            (key, _) => key.toLowerCase() == entry.key.toLowerCase(),
          );
        }
        targetEnv[entry.key] = resolve(entry.value, 'env.${entry.key}');
      }
      final argv = [
        for (var i = 0; i < plan.argv.length; i++)
          resolve(plan.argv[i], 'argv[$i]'),
      ];
      final input = plan.stdin == null
          ? null
          : material.materials[bindingIds['stdin']]!.bytes;
      await _verifyCredentialExecutable(plan.identity!, plan.cwd);
      await requireCall('authorize', getProof());
      preparing = false;
      process = await _startCredentialProcess(
        plan.path,
        argv,
        plan.cwd,
        workerEnv,
        workerExecutable: client._runtimeWorkerExecutable,
        plannedJobName: material.jobName,
        targetEnvironment: targetEnv,
        targetStdin: input,
        registerWorker: (workerPid) async {
          final worker = CredentialProcessIdentity.capture(workerPid);
          if (worker == null) {
            throw const CredentialUseFailure('process_start_failed');
          }
          try {
            await journal!.rememberWorker(workerPid, worker.value);
            await requireCall('worker/register', {
              ...getProof(),
              'workerPid': workerPid,
              'workerCreatedAt': worker.value,
            });
          } finally {
            worker.close();
          }
        },
      );
      stdoutDone = process.stdout
          .listen((bytes) => output.add('stdout', bytes))
          .asFuture<void>();
      stderrDone = process.stderr
          .listen((bytes) => output.add('stderr', bytes))
          .asFuture<void>();
      identity = CredentialProcessIdentity.capture(process.pid);
      if (!Platform.isMacOS) await process.stdin.close();
      try {
        started = DateTime.now().toUtc();
        created = identity?.value;
        if (created == null) {
          throw const CredentialUseFailure('execution_unknown');
        }
        try {
          await report('running');
        } on Object {
          await report('running');
        }
      } finally {
        if (Platform.isMacOS) await process.stdin.close();
      }
      final result = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      output.finish();
      await report('exited', exitCode: result);
    } on Object catch (error) {
      if (error is _UncertainCredentialLaunch) {
        uncertain = error;
        try {
          await report('unknown', code: 'execution_unknown');
        } on Object {
          /* Retain original proof. */
        }
        await error.monitor(output);
      }
      if (process != null) {
        try {
          await process.exitCode;
        } on Object {
          /* Unknown exit. */
        }
        try {
          await Future.wait([?stdoutDone, ?stderrDone]);
        } on Object {
          /* Still unknown. */
        }
      }
      final unknown =
          process != null ||
          uncertain != null ||
          error is CredentialUseFailure && error.code == 'execution_unknown';
      try {
        await report(
          unknown
              ? 'unknown'
              : preparing
              ? 'prepare_failed'
              : 'start_failed',
          code: unknown
              ? 'execution_unknown'
              : error is CredentialUseFailure
              ? error.code
              : preparing
              ? 'material_prepare_failed'
              : 'process_start_failed',
        );
      } on Object {
        /* Never retry a launch. */
      }
    } finally {
      identity?.close();
      output.active = false;
      output.finishedAt = DateTime.now();
      output.finish();
      final ended =
          (uncertain == null || uncertain.treeEnded) &&
          (process is! _RuntimeWorkerProcess || process.treeEnded);
      try {
        await journal?.finish(treeEnded: ended);
      } on Object {
        /* Maintain the same journal later. */
      }
      if (ended && folder != null) {
        try {
          await folder.delete(recursive: true);
        } on Object {
          /* No material is kept here. */
        }
      }
    }
  }
}
