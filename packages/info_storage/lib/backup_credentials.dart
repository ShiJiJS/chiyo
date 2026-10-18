part of 'info_storage.dart';

// Explicit format-five shapes: neither a future private field nor arbitrary
// runtime registration can silently enter a portable backup.
void _validateBackupCredentials(
  Map<String, List<Map<String, Object?>>> tables,
) {
  final credentials = <String, ManagedCredential>{};
  for (final row in tables['managed_credentials']!) {
    final j = _backupObject(_backupJson(row), {
      'id',
      'name',
      'publicPurpose',
      'privateNote',
      'form',
      'version',
      'revision',
      'useGeneration',
      'suggestedBinding',
      'createdAt',
      'modifiedAt',
      'discoverable',
      'enabled',
      'expiresAt',
      'deletedAt',
      'purgedAt',
      'fileName',
      'byteLength',
      'linkedItemIds',
    });
    final id = _backupId(j, 'id');
    if (row['id'] != id || credentials.containsKey(id)) _backupInvalid();
    _backupText(j, 'name', 60, required: true);
    _backupText(j, 'publicPurpose', 2000);
    _backupText(j, 'privateNote', 4000);
    if (!RegExp(
          r'^[A-Za-z_][A-Za-z0-9_]{0,63}$',
        ).hasMatch(_backupText(j, 'suggestedBinding', 64, required: true)) ||
        [
          'name',
          'publicPurpose',
          'privateNote',
        ].any((k) => (j[k] as String).contains('\u0000')))
      _backupInvalid();
    for (final key in ['version', 'revision', 'useGeneration']) {
      _backupVersion(j, key);
    }
    for (final key in ['createdAt', 'modifiedAt']) {
      _backupDate(j[key]);
    }
    for (final key in ['expiresAt', 'deletedAt', 'purgedAt']) {
      if (j[key] != null) _backupDate(j[key]);
    }
    if (j['enabled'] is! bool ||
        j['discoverable'] is! bool ||
        !{'string', 'file'}.contains(j['form']) ||
        j['byteLength'] is! int ||
        (j['byteLength'] as int) < 1 ||
        (j['byteLength'] as int) > (j['form'] == 'file' ? 1048576 : 65536))
      _backupInvalid();
    final fileName = j['fileName'];
    if (j['form'] == 'string' && fileName != null ||
        j['form'] == 'file' &&
            (fileName is! String ||
                fileName.isEmpty ||
                fileName.length > 255 ||
                fileName == '.' ||
                fileName == '..' ||
                RegExp(r'[\\/:\x00-\x1f]').hasMatch(fileName)))
      _backupInvalid();
    final links = _backupList(j['linkedItemIds'], 200);
    if (links.any((v) => v is! String || v.isEmpty || v.length > 200) ||
        links.toSet().length != links.length)
      _backupInvalid();
    // Links may legitimately reference an information item later deleted.
    final c = ManagedCredential.fromJson(j);
    if (c.purgedAt != null && c.deletedAt == null ||
        c.deletedAt != null && c.enabled)
      _backupInvalid();
    credentials[id] = c;
  }
  final materials = <String, CredentialMaterial>{};
  for (final row in tables['credential_materials']!) {
    final j = _backupObject(_backupJson(row), {
      'credentialId',
      'version',
      'bytes',
      'createdAt',
      'retiredAt',
      'fileName',
    });
    final id = _backupId(j, 'credentialId');
    final version = _backupVersion(j);
    if (id != row['credential_id'] || version != row['version'])
      _backupInvalid();
    final c = credentials[id];
    if (c == null || version > c.version || c.purgedAt != null)
      _backupInvalid();
    _backupDate(j['createdAt']);
    if (j['retiredAt'] != null) _backupDate(j['retiredAt']);
    final encoded = _backupText(j, 'bytes', 1398104, required: true);
    final bytes = base64Decode(encoded);
    if (base64Encode(bytes) != encoded ||
        bytes.isEmpty ||
        bytes.length > (c.form == CredentialForm.file ? 1048576 : 65536))
      _backupInvalid();
    if (c.form == CredentialForm.string &&
        (j['fileName'] != null || utf8.decode(bytes).contains('\u0000')))
      _backupInvalid();
    if (c.form == CredentialForm.file &&
        (j['fileName'] is! String ||
            (j['fileName'] as String).isEmpty ||
            (j['fileName'] as String).length > 255 ||
            RegExp(r'[\\/:\x00-\x1f]').hasMatch(j['fileName'] as String)))
      _backupInvalid();
    if (version != c.version && j['retiredAt'] == null ||
        c.deletedAt != null && j['retiredAt'] == null)
      _backupInvalid();
    final m = CredentialMaterial.fromStorageJson(j), key = '$id:$version';
    if (materials.containsKey(key)) _backupInvalid();
    materials[key] = m;
  }
  for (final c in credentials.values.where((c) => c.deletedAt == null)) {
    final m = materials['${c.id}:${c.version}'];
    if (m == null ||
        m.retiredAt != null ||
        m.bytes.length != c.byteLength ||
        m.fileName != c.fileName)
      _backupInvalid();
  }
  if (tables['ssh_host_trust']!.length > 1) _backupInvalid();
  for (final row in tables['ssh_host_trust']!) {
    if (row['id'] != 1) _backupInvalid();
    final j = _backupObject(_backupJson(row), {
      'id',
      'name',
      'bytesBase64',
      'confirmedAt',
    });
    _backupId(j, 'id');
    _backupDate(j['confirmedAt']);
    _backupText(j, 'name', 255, required: true);
    final bytes = _backupText(j, 'bytesBase64', 1398104, required: true);
    final trust = SshHostTrustSnapshot.fromStorageJson(j);
    if (base64Encode(trust.bytes) != bytes) _backupInvalid();
    validateSshKnownHosts(trust.name, trust.bytes);
  }
  _validateBackupCredentialHistory(tables);
}

void _retainBackupCredentials(
  Map<String, List<Map<String, Object?>>> tables,
  DateTime cutoff,
) {
  tables['credential_materials']!.removeWhere((r) {
    final j = _backupJson(r);
    return j['retiredAt'] != null &&
        !_backupDate(j['retiredAt']).isAfter(cutoff);
  });
}

void _archiveCredentialRuntime(Map<String, List<Map<String, Object?>>> tables) {
  final requests = tables['credential_use_requests']!
      .map((r) => CredentialUseRequest.fromJson(_backupJson(r)))
      .where((r) => r.state != 'pending')
      .toList();
  final ids = requests.map((r) => r.id).toSet();
  tables['credential_use_requests'] = [
    for (final r in requests) {'id': r.id, 'payload': jsonEncode(r.toJson())},
  ];
  tables['credential_executions'] = [
    for (final row in tables['credential_executions']!)
      if (ids.contains(row['request_id']))
        {
          'id': row['id'],
          'request_id': row['request_id'],
          'payload': jsonEncode(
            CredentialExecution.fromJson(_backupJson(row)).toJson(),
          ),
        },
  ];
}

Object? _orderedBackupJson(Object? value) => value is Map
    ? {
        for (final k in (value.keys.cast<String>().toList()..sort()))
          k: _orderedBackupJson(value[k]),
      }
    : value is List
    ? value.map(_orderedBackupJson).toList()
    : value;

void _validateBackupCredentialHistory(
  Map<String, List<Map<String, Object?>>> tables,
) {
  final requests = <String, CredentialUseRequest>{};
  for (final row in tables['credential_use_requests']!) {
    final j = _backupObject(
      _backupJson(row),
      {
        'id',
        'chatLabel',
        'purpose',
        'alias',
        'credentialId',
        'version',
        'useGeneration',
        'plan',
        'createdAt',
        'requestExpiresAt',
        'fields',
        'state',
        'credentialApproved',
        'approvedFields',
        'credentialExpiresAt',
        'fieldExpiresAt',
        'executionId',
        'attemptConsumed',
        'invalidatedCode',
        'credentialName',
        'decidedAt',
        'revokedAt',
        'attemptedAt',
      },
      {'requestedPlan', 'restoredAt'},
    );
    final id = _backupId(j, 'id');
    if (row['id'] != id || requests.containsKey(id)) _backupInvalid();
    _backupId(j, 'credentialId');
    _backupText(j, 'chatLabel', 2000);
    _backupText(j, 'purpose', 2000, required: true);
    if (!RegExp(
      r'^[A-Za-z_][A-Za-z0-9_]{0,63}$',
    ).hasMatch(_backupText(j, 'alias', 64, required: true)))
      _backupInvalid();
    for (final key in ['version', 'useGeneration']) {
      _backupVersion(j, key);
    }
    for (final key in ['createdAt', 'requestExpiresAt']) {
      _backupDate(j[key]);
    }
    for (final key in [
      'credentialExpiresAt',
      'fieldExpiresAt',
      'decidedAt',
      'revokedAt',
      'attemptedAt',
      'restoredAt',
    ]) {
      if (j[key] != null) _backupDate(j[key]);
    }
    if (!{
          'approved',
          'partially_approved',
          'denied',
          'cancelled',
          'expired',
        }.contains(j['state']) ||
        j['credentialApproved'] is! bool ||
        j['attemptConsumed'] is! bool)
      _backupInvalid();
    if (j['credentialName'] != null) _backupText(j, 'credentialName', 200);
    if (j['executionId'] != null) _backupId(j, 'executionId');
    if (j['invalidatedCode'] != null)
      _backupText(j, 'invalidatedCode', 100, required: true);
    for (final key in ['fields', 'approvedFields']) {
      final refs = _backupList(j[key], 200), seen = <String>{};
      for (final ref in refs) {
        final f = _backupObject(ref, {'itemId', 'fieldId'});
        _backupId(f, 'itemId');
        _backupId(f, 'fieldId');
        if (!seen.add(jsonEncode(_orderedBackupJson(f)))) _backupInvalid();
      }
    }
    final r = CredentialUseRequest.fromJson(j);
    if (r.approvedFields.any((f) => !r.fields.contains(f)) ||
        r.attemptConsumed && !r.credentialApproved ||
        r.attemptConsumed != (r.executionId != null))
      _backupInvalid();
    // Also rejects unknown nested plan/identity/reference keys; no filesystem
    // inspection or executable revalidation occurs while previewing history.
    if (jsonEncode(_orderedBackupJson(r.toJson())) !=
        jsonEncode(_orderedBackupJson(j)))
      _backupInvalid();
    requests[id] = r;
  }
  final executionIds = <String>{}, usedRequests = <String>{};
  for (final row in tables['credential_executions']!) {
    final j = _backupObject(
      _backupJson(row),
      {
        'protocolVersion',
        'status',
        'executionId',
        'requestId',
        'executionState',
        'attemptConsumed',
        'processStarted',
        'exitCode',
        'errorCode',
        'startedAt',
        'finishedAt',
        'cleanupState',
        'outputAvailable',
        'outputTruncated',
      },
      {'restoredAt'},
    );
    final id = _backupId(j, 'executionId'), request = _backupId(j, 'requestId');
    if (row['id'] != id ||
        row['request_id'] != request ||
        !executionIds.add(id) ||
        !usedRequests.add(request) ||
        requests[request]?.executionId != id)
      _backupInvalid();
    if (j['protocolVersion'] != 1 ||
        j['status'] != 'ok' ||
        j['attemptConsumed'] != true ||
        j['processStarted'] is! bool ||
        j['outputAvailable'] != false ||
        j['outputTruncated'] != false ||
        !{
          'preparing',
          'running',
          'exited',
          'prepare_failed',
          'start_failed',
          'unknown',
        }.contains(j['executionState']) ||
        !{
          'not_needed',
          'prepared',
          'pending',
          'complete',
          'failed',
          'needs_check',
        }.contains(j['cleanupState']))
      _backupInvalid();
    if (j['exitCode'] != null &&
        (j['exitCode'] is! int || (j['exitCode'] as int).abs() > 4294967295))
      _backupInvalid();
    if (j['errorCode'] != null)
      _backupText(j, 'errorCode', 100, required: true);
    for (final key in ['startedAt', 'finishedAt', 'restoredAt']) {
      if (j[key] != null) _backupDate(j[key]);
    }
    final e = CredentialExecution.fromJson(j);
    if (e.state == 'exited' && (e.exitCode == null || e.finishedAt == null) ||
        e.state == 'unknown' && e.exitCode != null)
      _backupInvalid();
  }
  if (requests.values.any(
    (r) => r.executionId != null && !executionIds.contains(r.executionId),
  ))
    _backupInvalid();
}

void _retainBackupCredentialHistory(
  Map<String, List<Map<String, Object?>>> tables,
  DateTime cutoff,
  DateTime? restoredAt,
) {
  final executions = {
    for (final row in tables['credential_executions']!)
      row['request_id']: CredentialExecution.fromJson(_backupJson(row)),
  };
  tables['credential_use_requests']!.removeWhere((row) {
    final r = CredentialUseRequest.fromJson(_backupJson(row)),
        e = executions[row['id']];
    return [
      r.createdAt,
      ?r.decidedAt,
      ?r.revokedAt,
      ?r.attemptedAt,
      ?e?.startedAt,
      ?e?.finishedAt,
    ].every((t) => t.isBefore(cutoff));
  });
  final ids = tables['credential_use_requests']!.map((r) => r['id']).toSet();
  tables['credential_executions']!.removeWhere(
    (r) => !ids.contains(r['request_id']),
  );
  if (restoredAt == null) return;
  tables['credential_use_requests'] = [
    for (final row in tables['credential_use_requests']!)
      {
        ...row,
        'payload': jsonEncode(
          CredentialUseRequest.fromJson(_backupJson(row)).changed({
            'invalidatedCode': 'grant_revoked',
            'restoredAt': restoredAt.toIso8601String(),
          }).toJson(),
        ),
      },
  ];
  tables['credential_executions'] = [
    for (final row in tables['credential_executions']!)
      {
        ...row,
        'payload': jsonEncode(
          CredentialExecution.fromJson(_backupJson(row)).changed({
            if ({
              'preparing',
              'running',
            }.contains(executions[row['request_id']]!.state)) ...{
              'executionState': 'unknown',
              'exitCode': null,
              'finishedAt': null,
              'errorCode': 'execution_unknown',
            },
            'cleanupState': 'not_needed',
            'restoredAt': restoredAt.toIso8601String(),
          }).toJson(),
        ),
      },
  ];
}
