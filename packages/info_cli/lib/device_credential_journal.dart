import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'private_device_state.dart';

/// Durable cleanup/control facts only. Never stores material, readable chat
/// proof, command output, or a capability that can launch another operation.
final class DeviceCredentialJournal {
  DeviceCredentialJournal(this.profile, this.directory);
  final AgentConnectionProfile profile;
  final Directory directory;
  String get _scope => sha256
      .convert(utf8.encode('${profile.serverId}\n${profile.deviceToken}'))
      .toString();

  Future<DeviceCredentialJournalEntry> begin(
    CredentialExecutionMaterial material,
  ) => _begin(
    material.executionId,
    material.executionCapability,
    material.jobName,
  );

  Future<DeviceCredentialJournalEntry> beginProgram(
    CredentialProgramMaterial material,
  ) => _begin(
    material.executionId,
    material.executionCapability,
    material.jobName,
    program: true,
  );

  Future<DeviceCredentialJournalEntry> _begin(
    String executionId,
    String capability,
    String? jobName, {
    bool program = false,
  }) async {
    final identity = CredentialProcessIdentity.capture(pid);
    if (identity == null ||
        jobName == null ||
        !CredentialProcessJob.validName(jobName)) {
      identity?.close();
      throw const CredentialUseFailure('material_prepare_failed');
    }
    final folder = await privateDeviceDirectory(directory.absolute);
    final file = File(
      '${folder.path}/${sha256.convert(utf8.encode(executionId))}.json',
    );
    try {
      if (await readPrivateDeviceState(file) != null) {
        throw const CredentialUseFailure('execution_unknown');
      }
      final entry = DeviceCredentialJournalEntry._(profile, file, {
        'version': program ? 2 : 1,
        if (program) 'kind': 'program',
        'deviceScope': _scope,
        'executionId': executionId,
        'executionCapability': capability,
        'jobName': jobName,
        'supervisorPid': pid,
        'supervisorIdentity': identity.value,
        'workerPid': null,
        'workerIdentity': null,
        'lease': null,
        'report': null,
        'cleaned': false,
      });
      await entry._save();
      return entry;
    } finally {
      identity.close();
    }
  }

  /// A dead supervisor is not proof its child tree ended. Inspect the original
  /// process group before touching any material; uncertain inspection retains
  /// the journal. No timeout creates another execution or starts a worker.
  Future<void> maintain() async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final folder = await privateDeviceDirectory(directory.absolute);
    var count = 0;
    await for (final file in folder.list(followLinks: false)) {
      if (file is! File ||
          !RegExp(
            r'^[0-9a-f]{64}\.json$',
          ).hasMatch(file.uri.pathSegments.last)) {
        continue;
      }
      if (++count > 500) throw const CredentialUseFailure('execution_capacity');
      final state = await readPrivateDeviceState(file);
      if (state == null || state['deviceScope'] != _scope) continue;
      final entry = DeviceCredentialJournalEntry._(profile, file, state);
      entry._validate();
      if (!state['cleaned'] &&
          CredentialProcessIdentity.isActive(
                state['supervisorPid'] as int,
                state['supervisorIdentity'] as String,
              ) !=
              false) {
        continue;
      }
      if (!state['cleaned'] &&
          CredentialProcessJob.isActive(
                state['jobName'] as String,
                workerPid: state['workerPid'] as int?,
                workerCreatedAt: state['workerIdentity'] as String?,
              ) !=
              false) {
        continue;
      }
      await entry.finish(treeEnded: true);
    }
  }
}

final class DeviceCredentialJournalEntry {
  DeviceCredentialJournalEntry._(this.profile, this.file, this._state);
  final AgentConnectionProfile profile;
  final File file;
  final Map<String, dynamic> _state;
  bool get _program => _state['version'] == 2 && _state['kind'] == 'program';
  void _validate() {
    if (_state.length != (_program ? 13 : 12) ||
        !_state.keys.toSet().containsAll(const {
          'version',
          'deviceScope',
          'executionId',
          'executionCapability',
          'jobName',
          'supervisorPid',
          'supervisorIdentity',
          'workerPid',
          'workerIdentity',
          'lease',
          'report',
          'cleaned',
        }) ||
        (!_program && _state['version'] != 1) ||
        _state['deviceScope'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(_state['deviceScope'] as String) ||
        _state['executionId'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9_-]{43}=?$',
        ).hasMatch(_state['executionId'] as String) ||
        _state['executionCapability'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9_-]{43}=?$',
        ).hasMatch(_state['executionCapability'] as String) ||
        _state['jobName'] is! String ||
        !CredentialProcessJob.validName(_state['jobName'] as String) ||
        _state['supervisorPid'] is! int ||
        (_state['supervisorPid'] as int) < 1 ||
        _state['supervisorIdentity'] is! String ||
        (_state['supervisorIdentity'] as String).isEmpty ||
        _state['cleaned'] is! bool ||
        (_state['workerPid'] == null) != (_state['workerIdentity'] == null) ||
        _state['workerPid'] != null && _state['workerPid'] is! int ||
        _state['workerIdentity'] != null &&
            _state['workerIdentity'] is! String ||
        _state['lease'] != null && _state['lease'] is! Map<String, dynamic> ||
        _state['report'] != null && _state['report'] is! Map<String, dynamic>) {
      throw const CredentialUseFailure('execution_unknown');
    }
    if (_state['report'] case final Map<String, dynamic> value) {
      final report = CredentialExecutionReport.fromPrivateJson(value);
      if (report.executionId != _state['executionId'] ||
          report.executionCapability != _state['executionCapability'] ||
          report.jobName != _state['jobName']) {
        throw const CredentialUseFailure('execution_unknown');
      }
    }
  }

  Future<void> _save() async {
    _validate();
    await writePrivateDeviceState(file, _state);
  }

  Future<void> rememberLease(CredentialMaterialLease lease) async {
    _state['lease'] = lease.toPrivateJson();
    await _save();
  }

  Future<void> rememberWorker(int pid, String identity) async {
    if (_state['workerPid'] != null &&
        (_state['workerPid'] != pid || _state['workerIdentity'] != identity)) {
      throw const CredentialUseFailure('execution_unknown');
    }
    _state['workerPid'] = pid;
    _state['workerIdentity'] = identity;
    await _save();
  }

  Future<CredentialExecutionReport> rememberReport(
    CredentialExecutionReport report,
  ) async {
    if (_state['report'] case final Map<String, dynamic> previous) {
      if (previous['executionState'] != 'running') {
        return CredentialExecutionReport.fromPrivateJson(previous);
      }
    }
    _state['report'] = report.toPrivateJson();
    await _save();
    return report;
  }

  Future<void> finish({required bool treeEnded}) async {
    if (!treeEnded) return;
    if (_state['cleaned'] != true) {
      if (_state['lease'] case final Map<String, dynamic> lease) {
        ManagedCredentialFiles.cleanup(
          CredentialMaterialLease.fromPrivateJson(lease),
        );
      }
      _state['cleaned'] = true;
      await _save(); // Physical cleanup is durable even when server is offline.
    }
    final connection = AgentConnection(profile);
    try {
      var report = _state['report'] as Map<String, dynamic>?;
      if (report == null || report['executionState'] == 'running') {
        // A dead process group proves cleanup is safe, not its exit status.
        report = CredentialExecutionReport(
          executionId: _state['executionId'] as String,
          executionCapability: _state['executionCapability'] as String,
          state: 'unknown',
          errorCode: 'execution_unknown',
          pid: report?['pid'] as int?,
          processCreatedAt: report?['processCreatedAt'] as String?,
          startedAt: report?['startedAt'] == null
              ? null
              : DateTime.parse(report!['startedAt'] as String),
          jobName: _state['jobName'] as String,
        ).toPrivateJson().cast<String, dynamic>();
        _state['report'] = report;
        await _save();
      }
      final result = await connection.call(
        _program
            ? '/credential-use/program/report'
            : '/credential-use/device/execution/report',
        report,
      );
      if (result['status'] != 'ok') return;
      final cleaned = await connection.call(
        _program
            ? '/credential-use/program/cleanup'
            : '/credential-use/device/cleanup/complete',
        {
          'executionId': _state['executionId'],
          'executionCapability': _state['executionCapability'],
          'treeEnded': true,
        },
      );
      if (cleaned['status'] == 'ok') await file.delete();
    } finally {
      connection.close();
    }
  }
}
