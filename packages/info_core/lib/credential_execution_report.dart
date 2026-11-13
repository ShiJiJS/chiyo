part of 'info_core.dart';

/// Pure progress validation shared by execution receivers. Authentication,
/// current grants, actual worker identity and durable publication remain the
/// caller's responsibility. No report can start a process or issue material.
/// Null means the exact already-recorded report, including a terminal reply.
Map<String, Object?>? _credentialExecutionReportChanges(
  CredentialExecution old,
  CredentialExecutionReport report,
) {
  final next = report.state;
  if (old.id != report.executionId ||
      old.jobName != null && old.jobName != report.jobName) {
    throw const CredentialUseFailure('invalid_plan');
  }
  if (old.state == next &&
      old.pid == report.pid &&
      old.processCreatedAt == report.processCreatedAt &&
      old.startedAt == report.startedAt &&
      old.finishedAt == report.finishedAt &&
      old.jobName == report.jobName &&
      old.exitCode == report.exitCode &&
      old.errorCode == report.errorCode) {
    return null;
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
  return {
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
}
