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
  if (!Platform.isWindows) {
    throw const CredentialUseFailure('unsupported_tool_version');
  }
  final runtime = Platform.resolvedExecutable;
  final interpreted =
      workerExecutable == null && runtime.toLowerCase().endsWith('dart.exe');
  final worker =
      workerExecutable ??
      (interpreted
          ? (await Isolate.resolvePackageUri(
              Uri.parse('package:info_cli/runtime_worker.dart'),
            ))!.toFilePath()
          : '${File(runtime).parent.path}/info-runtime-worker.exe');
  if (!await File(worker).exists()) {
    throw const CredentialUseFailure('process_start_failed');
  }
  final args = interpreted
      ? ['--packages=${(await Isolate.packageConfig)!.toFilePath()}', worker]
      : <String>[];
  // In the local SDK, killing a VM launched through dart.exe also terminated
  // its children. Use the VM directly for the development worker, matching the
  // standalone worker executable used in packaged builds.
  final path = interpreted ? '${File(runtime).parent.path}/dartvm.exe' : worker;
  if (!await File(path).exists()) {
    throw const CredentialUseFailure('process_start_failed');
  }
  final state = File('${environment['TEMP']}/worker-state.json');
  final nonce = base64Url.encode(
    List.generate(24, (_) => Random.secure().nextInt(256)),
  );
  final jobName = plannedJobName ?? 'Local\\AgentInfoRuntime-$nonce';
  final process = await Process.start(
    path,
    args,
    workingDirectory: cwd,
    environment: environment,
    includeParentEnvironment: false,
    runInShell: false,
  );
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
  while (!stopped) {
    try {
      final facts =
          jsonDecode(await state.readAsString()) as Map<String, dynamic>;
      if (!released &&
          facts['state'] == 'ready' &&
          facts['jobName'] == jobName &&
          facts['workerPid'] == process.pid) {
        try {
          await registerWorker?.call(process.pid);
          process.stdin.writeln('start');
          await process.stdin.flush();
          released = true;
        } on Object {
          await process.stdin.close();
          await ended;
          await Future.wait([
            process.stdout.drain<void>(),
            process.stderr.drain<void>(),
          ]);
          rethrow;
        }
      }
      if (facts['state'] == 'started' &&
          facts['jobName'] == jobName &&
          facts['pid'] is int) {
        return _RuntimeWorkerProcess(
          process,
          facts['pid'] as int,
          state,
          jobName,
        );
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
  await Future.wait([
    process.stdout.drain<void>(),
    process.stderr.drain<void>(),
  ]);
  throw const CredentialUseFailure('process_start_failed');
}

class _RuntimeWorkerProcess implements Process {
  _RuntimeWorkerProcess(this.worker, this.pid, this.state, this.jobName) {
    try {
      _job = CredentialProcessJob.observe(jobName, pid);
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
        jsonDecode(await state.readAsString()) as Map<String, dynamic>;
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
    Map<String, dynamic> input,
  ) async {
    try {
      if (utf8.encode(jsonEncode(input)).length > 262143) {
        throw const CredentialUseFailure('limit_exceeded');
      }
      final command = input['command'];
      final allowed = switch (command) {
        'request-use' => {
          'command',
          'purpose',
          'credentials',
          'launch',
          'readFields',
        },
        'run-use' => {'command', 'requestId'},
        'execution-output' => {'command', 'executionId', 'cursor', 'limit'},
        _ => {'command', 'executionId'},
      };
      if (input.keys.any((k) => !allowed.contains(k))) {
        throw const CredentialUseFailure('unknown_field');
      }
      if (_session == null) {
        throw const CredentialUseFailure('session_required');
      }
      if (command == 'request-use') {
        CredentialUseInput.fromJson(input);
        return await _call('/credential-use/request', {
          'sessionSecret': _session,
          ...input,
        });
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
        final result = await _call('/credential-use/hosted', {
          'sessionSecret': _session,
          ...input,
        });
        if (command == 'run-use' &&
            result['status'] == 'service_unavailable' &&
            !result.containsKey('attemptConsumed')) {
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
          return await _credentialExecutions.start(identity);
        case 'execution-status':
          final status = await _call('/credential-use/execution/status', {
            'sessionSecret': _session,
            'executionId': identity,
          });
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
          final status = await _call('/credential-use/execution/status', {
            'sessionSecret': _session,
            'executionId': identity,
          });
          if (status['status'] != 'ok') return status;
          return _credentialExecutions.output(
            identity,
            input['cursor'] ?? 0,
            input['limit'] ?? 16,
          );
        case 'cleanup-use':
          return await _call('/credential-use/cleanup', {
            'sessionSecret': _session,
            'executionId': identity,
          });
      }
      throw const CredentialUseFailure('invalid_plan');
    } on CredentialUseFailure catch (e) {
      return Map<String, dynamic>.from(e.toJson());
    } on Object {
      return Map<String, dynamic>.from(
        const CredentialUseFailure('invalid_type').toJson(),
      );
    }
  }

  Future<CredentialExecutionMaterial> _consumeCredentialMaterial(
    String id,
  ) async {
    var mayBeConsumed = false;
    try {
      final request = await _http.post(
        '127.0.0.1',
        port,
        '/credential-use/consume',
      );
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

  Future<void> _reportCredentialExecution(
    CredentialExecutionReport report,
  ) async {
    final result = await _call(
      '/credential-use/execution/report',
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
  final chunks = <Map<String, Object?>>[];
  int bytes = 0;
  bool truncated = false, complete = false, active = true;
  DateTime? finishedAt;
  void add(String stream, List<int> data) {
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

  Future<Map<String, dynamic>> start(String id) async {
    if (!Platform.isWindows && client._usesDefaultCredentialStarter) {
      throw const CredentialUseFailure('unsupported_tool_version');
    }
    prune();
    if (outputs.length + reservations >= 16) {
      throw const CredentialUseFailure('execution_capacity');
    }
    reservations++;
    late CredentialExecutionMaterial material;
    try {
      material = await client._consumeCredentialMaterial(id);
    } finally {
      reservations--;
    }
    final output = _ExecutionOutput();
    outputs[material.executionId] = output;
    late Future<void> work;
    work = Future<void>(
      () => _launch(material, output),
    ).whenComplete(() => running.remove(work));
    running.add(work);
    return {
      'protocolVersion': 1,
      'status': 'accepted',
      'requestId': id,
      'executionId': material.executionId,
      'attemptConsumed': true,
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
    var materialLease = m.materialLease;
    var registeredFiles = false;
    var preparing = true;
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
      await client._reportCredentialExecution(
        CredentialExecutionReport(
          executionId: m.executionId,
          executionCapability: m.executionCapability,
          state: state,
          pid: process?.pid,
          processCreatedAt: created,
          exitCode: exit,
          errorCode: code,
          startedAt: started,
          finishedAt: state == 'running' ? null : DateTime.now().toUtc(),
          jobName:
              m.jobName ??
              (process is _RuntimeWorkerProcess ? process.jobName : null),
        ),
      );
    }

    try {
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
        final registration = await client
            ._call('/credential-use/materials/register', {
              'executionId': m.executionId,
              'executionCapability': m.executionCapability,
              'lease': materialLease.toPrivateJson(),
            });
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
                  final result = await client
                      ._call('/credential-use/worker/register', {
                        'executionId': m.executionId,
                        'executionCapability': m.executionCapability,
                        'workerPid': workerPid,
                        'workerCreatedAt': identity.value,
                      });
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
      await process.stdin.close();
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
      final result = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      output.complete = true;
      await report('exited', exit: result);
    } on Object catch (e) {
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
          process != null
              ? 'unknown'
              : preparing
              ? 'prepare_failed'
              : 'start_failed',
          code: process != null ? 'execution_unknown' : code,
        );
      } on Object {
        /* No retry can start another process. */
      }
    } finally {
      processIdentity?.close();
      output.active = false;
      output.finishedAt = DateTime.now();
      output.complete = true;
      if (materialLease != null) {
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
      if (folder != null &&
          (process is! _RuntimeWorkerProcess || process.treeEnded)) {
        try {
          await folder.delete(recursive: true);
        } on Object {
          /* D6 contains no credential files. */
        }
      }
    }
  }
}
