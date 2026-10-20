part of 'info_storage.dart';

extension _FocusedFillStorage on EncryptedInformationRepository {
  Future<void> _loadFocusedFills() async {
    for (final row
        in await _db
            .customSelect(
              'SELECT id,request_id,payload FROM credential_focused_fills ORDER BY rowid',
            )
            .get()) {
      final operation = FocusedFillOperation.fromStorageJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      if (operation.id != row.read<String>('id') ||
          operation.requestId != row.read<String>('request_id')) {
        throw const StorageFailure('invalid_runtime_snapshot');
      }
      _focusedFillOperations.add(
        _archiveFocusedFill(operation, _clock().toUtc()),
      );
    }
  }
}

FocusedFillOperation _archiveFocusedFill(
  FocusedFillOperation operation,
  DateTime now, {
  bool restored = false,
}) => operation.changed({
  if (operation.state == FocusedFillState.checking) ...{
    'fillState': 'unknown',
    'finishedAt': now.toIso8601String(),
    'errorCode': 'fill_unknown',
  },
  if (restored) 'restoredAt': now.toIso8601String(),
});

void _validateFocusedFillSnapshot(
  List<CredentialUseRequest> requests,
  List<CredentialExecution> executions,
  List<FocusedFillOperation> fills,
) {
  Never invalid() => throw const StorageFailure('invalid_runtime_snapshot');
  final byId = {for (final r in requests) r.id: r};
  final recordIds = executions.map((e) => e.id).toSet();
  final operations = <String, Set<String>>{};
  for (final fill in fills) {
    final request = byId[fill.requestId];
    if (request == null ||
        !request.isFocusedFill ||
        request.protocolVersion != 2 ||
        !request.credentialApproved ||
        request.attemptedAt == null ||
        !recordIds.add(fill.id) ||
        !operations.putIfAbsent(request.id, () => {}).add(fill.operationId) ||
        !fill.application.matches(request.focusedFill!.application))
      invalid();
    try {
      FocusedFillOperation.fromStorageJson(
        Map<String, dynamic>.from(fill.toStorageJson()),
      );
      final input = FocusedFillOperationInput.fromJson({
        'protocolVersion': 2,
        'command': 'fill-use',
        'requestId': request.id,
        'operationId': fill.operationId,
      });
      // Wall-clock rollback must not make an actual input fact unpersistable.
      // State transitions, not timestamp ordering, prove checking/release.
      if (fill.fingerprint != input.fingerprint ||
          fill.inputReleased && fill.checkedAt == null)
        invalid();
    } on Object {
      invalid();
    }
  }
  for (final request in requests.where((r) => r.isFocusedFill)) {
    if (request.protocolVersion != 2 ||
        request.attemptConsumed ||
        request.executionId != null ||
        request.fields.isNotEmpty ||
        request.approvedFields.isNotEmpty ||
        (request.attemptedAt != null) != operations.containsKey(request.id)) {
      invalid();
    }
  }
}
