part of 'info_storage.dart';

const _metadataBudgetTimestamp = '9999-12-31T23:59:59.999999Z';

String _longestBudgetValue(Iterable<String> values) =>
    values.reduce((a, b) => a.length >= b.length ? a : b);

/// These projections are deliberately not domain objects. They count the
/// largest remaining portable contribution, including JSON-inside-JSON escaping,
/// while the ordinary snapshot keeps its original validated facts.
void _reserveRuntimeBackupOutcomes(
  Map<String, List<Map<String, Object?>>> tables,
) {
  void reserve(
    String table,
    Map<String, Object?> Function(Map<String, dynamic>) project,
  ) {
    tables[table] = [
      for (final row in tables[table]!)
        {...row, 'payload': jsonEncode(project(_backupJson(row)))},
    ];
  }

  reserve('credential_use_requests', (json) {
    final request = CredentialUseRequest.fromJson(json);
    if (!request.credentialApproved ||
        request.invalidatedCode != null ||
        request.restoredAt != null)
      return json;
    return {
      ...json,
      // First/last operation identities and invalidation dates can still be
      // recorded under this grant. Opaque IDs have at most200 code units.
      if (!request.isFocusedFill) 'executionId': 'X' * 200,
      'attemptConsumed': false,
      'attemptedAt': _metadataBudgetTimestamp,
      'revokedAt': _metadataBudgetTimestamp,
      // Archive error text is bounded to100 code units. Controls upper-bound
      // Unicode and quote/backslash expansion through both JSON encodings.
      'invalidatedCode': '\u0001' * 100,
    };
  });
  reserve('credential_executions', (json) {
    final execution = CredentialExecution.fromJson(json);
    final stable =
        {
          'exited',
          'prepare_failed',
          'start_failed',
        }.contains(execution.state) &&
        {'complete', 'not_needed'}.contains(execution.cleanupState);
    if (execution.restoredAt != null || stable) return json;
    return {
      ...json,
      'executionState': _longestBudgetValue({
        'preparing',
        'running',
        'exited',
        'prepare_failed',
        'start_failed',
        'unknown',
      }),
      'cleanupState': _longestBudgetValue({
        'not_needed',
        'pending',
        'complete',
        'failed',
        'needs_check',
      }),
      'processStarted': false,
      'exitCode': -4294967295,
      'errorCode': '\u0001' * 100,
      'startedAt': _metadataBudgetTimestamp,
      'finishedAt': _metadataBudgetTimestamp,
    };
  });
  reserve('credential_focused_fills', (json) {
    final fill = FocusedFillOperation.fromStorageJson(json);
    if (fill.restoredAt != null ||
        {
          FocusedFillState.sent,
          FocusedFillState.refused,
        }.contains(fill.state) ||
        fill.attentionAcknowledgedAt != null)
      return json;
    return {
      ...json,
      'status': 'accepted',
      'fillState': _longestBudgetValue(
        FocusedFillState.values.map((s) => s.name),
      ),
      'inputReleased': false,
      'errorCode': _longestBudgetValue(focusedFillErrorCodes),
      'checkedAt': _metadataBudgetTimestamp,
      'finishedAt': _metadataBudgetTimestamp,
      'attentionAcknowledgedAt': _metadataBudgetTimestamp,
    };
  });
  reserve(
    'managed_credentials',
    (json) => {
      ...json,
      if (json['deletedAt'] != null && json['purgedAt'] == null)
        'purgedAt': _metadataBudgetTimestamp,
    },
  );
}
