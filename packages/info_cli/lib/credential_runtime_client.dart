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
  Map<String, String> environment,
) => Process.start(
  executable,
  argv,
  workingDirectory: cwd,
  environment: environment,
  includeParentEnvironment: false,
  runInShell: false,
);

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
          final status = await _call('/credential-use/execution/status', {
            'sessionSecret': _session,
            'executionId': identity,
          });
          if (status['status'] != 'ok') return status;
          return {
            'protocolVersion': 1,
            'status': 'ok',
            'executionId': identity,
            'cleanupState': status['cleanupState'],
          };
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
    try {
      final request = await _http.post(
        '127.0.0.1',
        port,
        '/credential-use/consume',
      );
      request.headers.contentType = ContentType.json;
      request.followRedirects = false;
      request.write(jsonEncode({'sessionSecret': _session, 'requestId': id}));
      final response = await request.close();
      final decoded =
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>;
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
      throw const CredentialUseFailure('material_claim_failed');
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
    var preparing = true;
    Future<void> report(String state, {String? code, int? exit}) =>
        client._reportCredentialExecution(
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
          ),
        );
    try {
      final plan = m.approvedPlan;
      final binding = plan.env['GH_TOKEN'];
      if (plan.receiver != 'gh_token' ||
          m.credentialMaterial.form != CredentialForm.string ||
          binding?.kind != LaunchValueKind.secret ||
          binding?.value != m.alias ||
          m.credentialMaterial.bytes.isEmpty ||
          m.credentialMaterial.stringValue.isEmpty) {
        throw const CredentialUseFailure('material_prepare_failed');
      }
      folder = await Directory.systemTemp.createTemp('info-runtime-');
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
        'GH_CONFIG_DIR': config.path,
        'GH_HOST': 'github.com',
        'GH_PROMPT_DISABLED': '1',
        'GH_TOKEN': m.credentialMaterial.stringValue,
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
      preparing = false;
      process = await client._credentialProcessStarter(
        plan.path,
        plan.argv.map((v) => v.value).toList(),
        plan.cwd,
        env,
      );
      processIdentity=CredentialProcessIdentity.capture(process.pid);
      await process.stdin.close();
      started = DateTime.now().toUtc();
      created = processIdentity?.value;
      if(created==null)throw const CredentialUseFailure('execution_unknown');
      final stdoutDone = process.stdout
          .listen((data) => output.add('stdout', data))
          .asFuture<void>();
      final stderrDone = process.stderr
          .listen((data) => output.add('stderr', data))
          .asFuture<void>();
      await report('running');
      final result = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      output.complete = true;
      await report('exited', exit: result);
    } on Object catch (e) {
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
      if (folder != null) {
        try {
          await folder.delete(recursive: true);
        } on Object {
          /* D6 contains no credential files. */
        }
      }
    }
  }
}
