import 'history_transport.dart' show historyEnvelope, historyText, historyInt;
import 'workspace_settings.dart';

/// Shared library policy only. Device appearance, notification and window
/// preferences never cross this port or inherit another device's choices.
class WorkspaceServerPolicy {
  const WorkspaceServerPolicy({
    required this.generation,
    required this.version,
    required this.requestMinutes,
    required this.retentionDays,
  });
  final String generation;
  final int version, requestMinutes, retentionDays;
  Map<String, Object?> get json => {
    'wireVersion': 1,
    'generation': generation,
    'version': version,
    'requestMinutes': requestMinutes,
    'retentionDays': retentionDays,
  };
  factory WorkspaceServerPolicy.fromJson(Object? raw) {
    final b = historyEnvelope(raw, [
      'generation',
      'version',
      'requestMinutes',
      'retentionDays',
    ]);
    final generation = historyText(b['generation']);
    final request = historyInt(b['requestMinutes'], min: 1);
    final retention = historyInt(b['retentionDays'], min: 1);
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(generation) ||
        request > 10080 ||
        !const [30, 90, 180, 365].contains(retention)) {
      throw const FormatException('Invalid policy');
    }
    return WorkspaceServerPolicy(
      generation: generation,
      version: historyInt(b['version'], min: 1),
      requestMinutes: request,
      retentionDays: retention,
    );
  }
}

class WorkspaceServerPolicyChange {
  WorkspaceServerPolicyChange({
    required this.operationId,
    required this.commandDigest,
    required this.generation,
    required this.expectedVersion,
    required this.requestMinutes,
    required this.retentionDays,
    this.retentionToken,
  });
  final String operationId, commandDigest, generation;
  final int expectedVersion, requestMinutes, retentionDays;
  final String? retentionToken;
  Map<String, Object?> get json => {
    'wireVersion': 1,
    'operationId': operationId,
    'commandDigest': commandDigest,
    'generation': generation,
    'expectedVersion': expectedVersion,
    'requestMinutes': requestMinutes,
    'retentionDays': retentionDays,
    'retentionToken': retentionToken,
  };
  factory WorkspaceServerPolicyChange.fromJson(Object? raw) {
    final b = historyEnvelope(raw, [
      'operationId',
      'commandDigest',
      'generation',
      'expectedVersion',
      'requestMinutes',
      'retentionDays',
      'retentionToken',
    ]);
    final operation = policyOperationId(b['operationId']);
    final digest = historyText(b['commandDigest']);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('Invalid policy command');
    }
    final p = WorkspaceServerPolicy.fromJson({
      'wireVersion': 1,
      'generation': b['generation'],
      'version': b['expectedVersion'],
      'requestMinutes': b['requestMinutes'],
      'retentionDays': b['retentionDays'],
    });
    return WorkspaceServerPolicyChange(
      operationId: operation,
      commandDigest: digest,
      generation: p.generation,
      expectedVersion: p.version,
      requestMinutes: p.requestMinutes,
      retentionDays: p.retentionDays,
      retentionToken: b['retentionToken'] == null
          ? null
          : historyText(b['retentionToken']),
    );
  }
}

class WorkspaceServerPolicyReceipt {
  const WorkspaceServerPolicyReceipt({
    required this.operationId,
    required this.commandDigest,
    required this.expectedVersion,
    required this.policy,
  });
  final String operationId, commandDigest;
  final int expectedVersion;
  final WorkspaceServerPolicy policy;
  bool matches(WorkspaceServerPolicyChange c) =>
      operationId == c.operationId &&
      commandDigest == c.commandDigest &&
      expectedVersion == c.expectedVersion &&
      policy.version == c.expectedVersion + 1 &&
      policy.generation == c.generation &&
      policy.requestMinutes == c.requestMinutes &&
      policy.retentionDays == c.retentionDays;
  Map<String, Object?> get json => {
    'wireVersion': 1,
    'operationId': operationId,
    'commandDigest': commandDigest,
    'expectedVersion': expectedVersion,
    'policy': policy.json,
  };
  factory WorkspaceServerPolicyReceipt.fromJson(Object? raw) {
    final b = historyEnvelope(raw, [
      'operationId',
      'commandDigest',
      'expectedVersion',
      'policy',
    ]);
    final digest = historyText(b['commandDigest']);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('Invalid policy receipt');
    }
    final p = WorkspaceServerPolicy.fromJson(b['policy']);
    final expected = historyInt(b['expectedVersion'], min: 1);
    if (p.version != expected + 1) {
      throw const FormatException('Invalid policy version');
    }
    return WorkspaceServerPolicyReceipt(
      operationId: policyOperationId(b['operationId']),
      commandDigest: digest,
      expectedVersion: expected,
      policy: p,
    );
  }
}

String policyOperationId(Object? value) {
  final id = historyText(value);
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$').hasMatch(id)) {
    throw const FormatException('Invalid policy operation');
  }
  return id;
}

Map<String, Object?> retentionPreviewToJson(WorkspaceRetentionPreview p) => {
  'wireVersion': 1,
  'token': p.token,
  'days': p.days,
  'cutoff': p.cutoff.toUtc().toIso8601String(),
  'requests': p.requests,
  'grants': p.grants,
  'operations': p.operations,
  'preserved': p.preserved,
};
WorkspaceRetentionPreview retentionPreviewFromJson(Object? raw) {
  final b = historyEnvelope(raw, [
    'token',
    'days',
    'cutoff',
    'requests',
    'grants',
    'operations',
    'preserved',
  ]);
  final date = DateTime.parse(historyText(b['cutoff']));
  if (!date.isUtc ||
      date.toIso8601String() != b['cutoff'] ||
      !const [30, 90, 180, 365].contains(b['days'])) {
    throw const FormatException('Invalid retention preview');
  }
  return WorkspaceRetentionPreview(
    token: historyText(b['token']),
    days: historyInt(b['days'], min: 1),
    cutoff: date,
    requests: historyInt(b['requests']),
    grants: historyInt(b['grants']),
    operations: historyInt(b['operations']),
    preserved: historyInt(b['preserved']),
  );
}
