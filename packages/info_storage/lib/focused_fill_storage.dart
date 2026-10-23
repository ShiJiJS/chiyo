part of 'info_storage.dart';

extension _FocusedFillStorage on EncryptedInformationRepository {
  Future<bool> _portableFocusedFillFormat() async =>
      (await _db
              .customSelect(
                'SELECT version FROM library_format WHERE singleton=1',
              )
              .getSingle())
          .read<int>('version') ==
      _portableFocusedFillLibraryFormat;

  /// Called only inside the transaction installing the first portable request
  /// or restore. Both marker and header roll back with all associated facts.
  /// The open Drift connection keeps its initial schema target; no DDL changes
  /// here. A later open selects target23 from the independent marker.
  Future<void> _requirePortableFocusedFillFormat() async {
    final version =
        (await _db
                .customSelect(
                  'SELECT version FROM library_format WHERE singleton=1',
                )
                .getSingle())
            .read<int>('version');
    if (version == _portableFocusedFillLibraryFormat) return;
    if (version != _libraryFormat)
      throw const StorageFailure('unsupported_schema');
    await _db.customStatement(
      'UPDATE library_format SET version=? WHERE singleton=1',
      [_portableFocusedFillLibraryFormat],
    );
    await _db.customStatement(
      'PRAGMA user_version = $_portableFocusedFillLibraryFormat',
    );
  }

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

bool _hasPortableFocusedFill(Iterable<CredentialUseRequest> requests) =>
    requests.any(
      (request) =>
          request.isFocusedFill &&
          request.focusedFill!.application.executable.startsWith('/'),
    );

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
  List<FocusedFillOperation> fills, {
  bool portableApplications = false,
}) {
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
    // Legacy formats remain Windows-only. Portable identities require the
    // independent library23 marker or explicit backup11 label.
    if (!portableApplications &&
            request.focusedFill!.application.executable.startsWith('/') ||
        request.protocolVersion != 2 ||
        request.attemptConsumed ||
        request.executionId != null ||
        request.fields.isNotEmpty ||
        request.approvedFields.isNotEmpty ||
        (request.attemptedAt != null) != operations.containsKey(request.id)) {
      invalid();
    }
  }
}
