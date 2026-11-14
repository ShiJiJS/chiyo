import 'dart:async';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'agent_client.dart';
import 'ssh_session_host.dart';
import 'package:info_remote/agent_connection.dart';

/// A resident owner of CLI executions for one-command adapters. It stores only
/// bounded process output in memory; Core still authorizes every operation.
class CredentialExecutionHost {
  CredentialExecutionHost({
    required this.port,
    this.workerExecutable,
    CredentialProcessStarter? processStarter,
    DateTime Function()? clock,
    this.connection,
    this.deviceFileStateDirectory,
  }) : _processStarter = processStarter,
       _clock = clock ?? DateTime.now {
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _prune());
  }
  final int port;
  final AgentConnectionProfile? connection;
  final Directory? deviceFileStateDirectory;
  final String? workerExecutable;
  final CredentialProcessStarter? _processStarter;
  final DateTime Function() _clock;
  final _entries = <String, _HostedExecution>{};
  Timer? _timer;
  int _reservations = 0;
  bool _closed = false;
  SshSessionHost? _ssh;

  AgentClient _client(String session) => AgentClient(
    port,
    sessionSecret: session,
    credentialProcessStarter: _processStarter,
    runtimeWorkerExecutable: workerExecutable,
    connection: connection,
    deviceFileStateDirectory: deviceFileStateDirectory,
  );

  /// Inspection does not cancel or forget an active operation.
  bool get canStop =>
      (_ssh?.canStop ?? true) &&
      _reservations == 0 &&
      _entries.values.every((e) => e.finishedAt != null);
  bool get isIdle {
    _prune();
    return (_ssh?.isIdle ?? true) && _reservations == 0 && _entries.isEmpty;
  }

  void _remove(String id) {
    _entries.remove(id)?.client.close();
  }

  void _prune() {
    final cutoff = _clock().subtract(const Duration(minutes: 30));
    for (final e in _entries.entries.toList()) {
      if (e.value.finishedAt case final finished?) {
        if (finished.isBefore(cutoff)) _remove(e.key);
      }
    }
  }

  bool _makeRoom() {
    _prune();
    final finished =
        _entries.entries.where((e) => e.value.finishedAt != null).toList()
          ..sort((a, b) => a.value.finishedAt!.compareTo(b.value.finishedAt!));
    for (final e in finished) {
      if (_entries.length + _reservations < 16) break;
      _remove(e.key);
    }
    return _entries.length + _reservations < 16;
  }

  Future<Map<String, dynamic>> execute(
    String session,
    Map<String, dynamic> input,
  ) async {
    if (_closed) {
      return Map.from(
        const CredentialUseFailure(
          'service_unavailable',
        ).toJson(protocolVersion: input['protocolVersion'] == 2 ? 2 : 1),
      );
    }
    if ((input['command'] as String? ?? '').startsWith('ssh-')) {
      if (connection == null || deviceFileStateDirectory == null) {
        return {'status': 'service_unavailable'};
      }
      _ssh ??= SshSessionHost(
        connection!,
        Directory(
          '${deviceFileStateDirectory!.absolute.parent.path}/ssh-sessions',
        ),
      );
      return _ssh!.execute(session, input);
    }
    _prune();
    final command = input['command'];
    final program = const {
      'program-run',
      'program-status',
      'program-output',
      'program-cleanup',
    }.contains(command);
    final starts = command == 'run-use' || command == 'program-run';
    if (!{
          'run-use',
          'execution-status',
          'execution-output',
          'cleanup-use',
        }.contains(command) &&
        !program) {
      return Map.from(
        const CredentialUseFailure(
          'invalid_plan',
        ).toJson(protocolVersion: input['protocolVersion'] == 2 ? 2 : 1),
      );
    }
    if (!starts) {
      final entry = program
          ? _entries.values
                .where(
                  (entry) =>
                      entry.session == session &&
                      entry.operationId == input['operationId'],
                )
                .firstOrNull
          : _entries[input['executionId']];
      if (entry != null && entry.session == session) {
        return entry.client.execute(input);
      }
      final client = _client(session);
      try {
        return await client.execute(input);
      } finally {
        client.close();
      }
    }
    if (program || input['protocolVersion'] == 2) {
      // Query before reserving a capacity slot: an old operation is readable
      // even when all slots are occupied, and never needs a second worker.
      final query = _client(session);
      try {
        final existing = await query.execute(
          program
              ? {...input, 'command': 'program-status'}
              : {...input, 'command': 'operation-status'},
        );
        if (existing['status'] != 'not_found') return existing;
      } finally {
        query.close();
      }
    }
    if (_processStarter == null) {
      if (!Platform.isWindows && !Platform.isMacOS) {
        return Map.from(
          const CredentialUseFailure(
            'unsupported_tool_version',
          ).toJson(protocolVersion: input['protocolVersion'] == 2 ? 2 : 1),
        );
      }
      if (workerExecutable == null || !await File(workerExecutable!).exists()) {
        return Map.from(
          const CredentialUseFailure(
            'service_unavailable',
          ).toJson(protocolVersion: input['protocolVersion'] == 2 ? 2 : 1),
        );
      }
    }
    if (_closed) {
      return Map.from(
        const CredentialUseFailure(
          'service_unavailable',
        ).toJson(protocolVersion: input['protocolVersion'] == 2 ? 2 : 1),
      );
    }
    if (!_makeRoom()) {
      return Map.from(
        const CredentialUseFailure(
          'execution_capacity',
        ).toJson(protocolVersion: input['protocolVersion'] == 2 ? 2 : 1),
      );
    }
    _reservations++;
    final client = _client(session);
    var retained = false;
    try {
      final result = await client.execute(input);
      if (result['status'] == 'accepted') {
        final entry = _HostedExecution(
          client,
          session,
          operationId: program ? input['operationId'] as String : null,
        );
        if (!_closed) _entries[result['executionId'] as String] = entry;
        retained = true;
        unawaited(
          client.drainCredentialExecutions().then((_) {
            if (_closed) {
              client.close();
            } else {
              entry.finishedAt = _clock();
            }
          }),
        );
      }
      return result;
    } finally {
      _reservations--;
      if (!retained) client.close();
    }
  }

  Future<void> drain() async {
    await Future.wait(
      _entries.values.map((e) => e.client.drainCredentialExecutions()),
    );
  }

  /// Stop accepting work without killing a program that is already running.
  /// The external worker retains its Windows process group and drains pipes.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ssh != null) unawaited(_ssh!.close());
    _timer?.cancel();
    _timer = null;
    for (final entry in _entries.values) {
      entry.client.close();
    }
    _entries.clear();
  }
}

class _HostedExecution {
  _HostedExecution(this.client, this.session, {this.operationId});
  final AgentClient client;
  final String session;
  final String? operationId;
  DateTime? finishedAt;
}
