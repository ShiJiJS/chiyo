part of 'info_storage.dart';

const _metadataBudgetTimestamp = '9999-12-31T23:59:59.999999Z';
const _backupRowCeiling = 500000;
const _backupNestedFactCeiling = 500000;

int _maximumBackupRows(String table) => switch (table) {
  'information_fields' ||
  'information_item_tags' ||
  'information_file_fields' => 200000,
  'field_templates' || 'settings' => 1000,
  'access_records' || 'recycle_facts' || 'revision_purge_facts' => 200000,
  _ => 10000,
};

bool _backupRowsWithinLimits(Map<String, List<Map<String, Object?>>> tables) {
  var total = 0;
  for (final table in tables.entries) {
    if (table.value.length > _maximumBackupRows(table.key)) return false;
    total += table.value.length;
  }
  return total <= _backupRowCeiling;
}

/// Count structure, not cross-record validity: an ordered audit pair may still
/// be between its writes. Full domain checks remain mandatory for export.
void _checkBackupAdmissionCounts(
  Map<String, List<Map<String, Object?>>> tables,
) {
  Never full() => throw const AccessFailure('attachment_capacity_exceeded');
  if (!_backupRowsWithinLimits(tables)) full();
  var total = 0, nested = tables['information_deliveries']?.length ?? 0;
  for (final table in tables.entries) {
    if (table.value.length > _maximumBackupRows(table.key)) full();
    total += table.value.length;
  }
  var availableRecycle = 0;
  void snapshot(Map<String, dynamic> item) {
    nested +=
        1 + (item['fields'] as List).length + (item['tagIds'] as List).length;
  }

  for (final row in tables['information_revisions']!) {
    snapshot(_backupJson(row));
  }
  for (final row in tables['recycle_entries']!) {
    final entry = _backupJson(row);
    if (entry['state'] == 'available') {
      availableRecycle++;
      snapshot(Map<String, dynamic>.from(entry['snapshot'] as Map));
    }
  }
  for (final row in tables['recycle_facts']!) {
    final fact = _backupJson(row);
    nested += (fact['fieldIds'] as List).length;
    nested += (fact['restoredFieldIds'] as Map?)?.length ?? 0;
  }
  for (final row in tables['grant_history']!) {
    final grant = _backupJson(row);
    nested += (grant['fields'] as List).length;
    nested += (grant['itemVersions'] as Map?)?.length ?? 0;
  }
  // Expiring revisions replace one row with one purge fact. Recycling keeps
  // its entry and adds a fact. Reserve these slots before automatic retention.
  if (tables['revision_purge_facts']!.length +
              tables['information_revisions']!.length >
          _maximumBackupRows('revision_purge_facts') ||
      tables['recycle_facts']!.length + availableRecycle >
          _maximumBackupRows('recycle_facts') ||
      total + availableRecycle > _backupRowCeiling ||
      nested > _backupNestedFactCeiling)
    full();
}

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
    Map<String, Object?> rowWithReservation(Map<String, Object?> row) {
      final original = _backupJson(row), reserved = project(original);
      return identical(original, reserved)
          ? row
          : {...row, 'payload': jsonEncode(reserved)};
    }

    tables[table] = [for (final row in tables[table]!) rowWithReservation(row)];
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
      if (!request.isFocusedFill) 'executionId': '\u0001' * 200,
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
  reserve('managed_credentials', (json) {
    if (json['deletedAt'] == null || json['purgedAt'] != null) return json;
    return {...json, 'purgedAt': _metadataBudgetTimestamp};
  });
  reserve('grant_history', (json) {
    final events = json['events'] as List;
    if (json['restoredAt'] != null ||
        events.isEmpty ||
        (events.last as Map)['kind'] != GrantEventKind.approved.name)
      return json;
    return {
      ...json,
      'events': [
        ...events,
        {
          'kind': _longestBudgetValue(GrantEventKind.values.map((e) => e.name)),
          'at': _metadataBudgetTimestamp,
        },
      ],
    };
  });
  reserve('request_history', (json) {
    if (json['restoredAt'] != null ||
        json['state'] != AccessRequestState.approved.name)
      return json;
    return {
      ...json,
      'state': _longestBudgetValue(
        AccessRequestState.values.map((s) => s.name),
      ),
      'recordedAt': _metadataBudgetTimestamp,
      'sessionEnded': false,
      'applicationClosed': false,
    };
  });
}
