import 'dart:async';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'agent_client.dart';

/// A resident owner of CLI executions for one-command adapters. It stores only
/// bounded process output in memory; Core still authorizes every operation.
class CredentialExecutionHost {
  CredentialExecutionHost({
    required this.port,
    this.workerExecutable,
    CredentialProcessStarter? processStarter,
    DateTime Function()? clock,
  }) : _processStarter = processStarter,
       _clock = clock ?? DateTime.now {
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _prune());
  }
  final int port;
  final String? workerExecutable;
  final CredentialProcessStarter? _processStarter;
  final DateTime Function() _clock;
  final _entries = <String, _HostedExecution>{};
  Timer? _timer;
  int _reservations = 0;
  bool _closed = false;

  AgentClient _client(String session) => AgentClient(
    port,
    sessionSecret: session,
    credentialProcessStarter: _processStarter,
    runtimeWorkerExecutable: workerExecutable,
  );
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
        const CredentialUseFailure('service_unavailable').toJson(),
      );
    }
    _prune();
    final command = input['command'];
    if (!{
      'run-use',
      'execution-status',
      'execution-output',
      'cleanup-use',
    }.contains(command)) {
      return Map.from(const CredentialUseFailure('invalid_plan').toJson());
    }
    if (command != 'run-use') {
      final entry = _entries[input['executionId']];
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
    if (_processStarter == null) {
      if (!Platform.isWindows) {
        return Map.from(
          const CredentialUseFailure('unsupported_tool_version').toJson(),
        );
      }
      if (workerExecutable == null || !await File(workerExecutable!).exists()) {
        return Map.from(
          const CredentialUseFailure('service_unavailable').toJson(),
        );
      }
    }
    if (_closed) {
      return Map.from(
        const CredentialUseFailure('service_unavailable').toJson(),
      );
    }
    if (!_makeRoom()) {
      return Map.from(
        const CredentialUseFailure('execution_capacity').toJson(),
      );
    }
    _reservations++;
    final client = _client(session);
    var retained = false;
    try {
      final result = await client.execute(input);
      if (result['status'] == 'accepted') {
        final entry = _HostedExecution(client, session);
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
    _timer?.cancel();
    _timer = null;
    for (final entry in _entries.values) {
      entry.client.close();
    }
    _entries.clear();
  }
}

class _HostedExecution {
  _HostedExecution(this.client, this.session);
  final AgentClient client;
  final String session;
  DateTime? finishedAt;
}
