part of 'info_core.dart';

/// Agent queries are scoped by the authenticated private session, never by a
/// display name or an external chat ID. Projections intentionally exclude
/// proposed values, credential accounts/material and private runtime handles.
extension AgentRecordQueries on AgentAccess {
  static const recordKinds = {
    'access',
    'credential-use',
    'credential-reveal',
    'import',
    'update',
    'delete',
    'organization',
  };

  Iterable<Map<String, Object?>> _ownRequestRecords(String session) sync* {
    _service._requireSession(session);
    final binding = _service._sessionBindings[session];
    for (final r in _service._requests.values) {
      if (r.session != session) continue;
      final state = status(session, r.id);
      yield {
        'id': r.id,
        'kind': 'access',
        'status': state['status'],
        'purpose': r.purpose,
        'agentName': r.agentName,
        'createdAt': _useTimestamp(r.createdAt),
        if (r.operationId != null) 'operationId': r.operationId,
      };
    }
    if (_service._repository case CredentialRuntimeRepository runtime) {
      for (final r in runtime.credentialUseRequests) {
        if (_service._credentialUseSessions[r.id] != session) continue;
        yield {
          'id': r.id,
          'kind': r.isReveal ? 'credential-reveal' : 'credential-use',
          'status': credentialUseStatus(session, r.id)['status'],
          'purpose': r.purpose,
          'agentName': r.agentName,
          'createdAt': _useTimestamp(r.createdAt),
          'credentialId': r.credentialId,
          'version': r.version,
        };
      }
    }
    if (_service._repository case CredentialBatchRepository batches) {
      for (final r in batches.credentialBatches) {
        if (r.sessionBinding != binding || r.archived) continue;
        yield {
          'id': r.id,
          'kind': 'credential-use',
          'protocolVersion': 3,
          'status': _service._batchState(r),
          'purpose': r.purpose,
          'agentName': r.agentName,
          'operationId': r.operationId,
          'createdAt': _useTimestamp(r.createdAt),
          'itemCount': r.items.length,
        };
      }
    }
    for (final p in _service._repository.importProposals) {
      if (p.sessionBinding != binding) continue;
      yield {
        'id': p.id,
        'kind': 'import',
        'title': p.title,
        'purpose': p.purpose,
        'agentName': p.agentName,
        'createdAt': _useTimestamp(p.createdAt),
        'status': importStatus(session, p.id)['status'],
        if (p.operationId != null) 'operationId': p.operationId,
      };
    }
    for (final p in _service._repository.updateProposals) {
      if (p.sessionBinding != binding) continue;
      yield {
        'id': p.id,
        'kind': 'update',
        'title': p.title,
        'purpose': p.purpose,
        'agentName': p.agentName,
        'createdAt': _useTimestamp(p.createdAt),
        'status': updateStatus(session, p.id)['status'],
        if (p.operationId != null) 'operationId': p.operationId,
      };
    }
    for (final p in _service._repository.deleteProposals) {
      if (p.sessionBinding != binding) continue;
      yield {
        'id': p.id,
        'kind': 'delete',
        'title': p.title,
        'purpose': p.purpose,
        'agentName': p.agentName,
        'createdAt': _useTimestamp(p.createdAt),
        'status': deleteStatus(session, p.id)['status'],
      };
    }
    for (final task in _service._repository.organizationTasks) {
      if (task.sessionBinding != binding) continue;
      yield {
        'id': task.id,
        'kind': 'organization',
        'title': task.title,
        'purpose': task.purpose,
        'agentName': task.agentName,
        'createdAt': _useTimestamp(task.createdAt),
        'status': organizationStatus(session, task.id)['status'],
      };
    }
  }

  Map<String, Object?> queryOwnRequests(
    String session, {
    String? kind,
    String? state,
    int offset = 0,
    int limit = 20,
    bool proposalsOnly = false,
  }) {
    _service._requireSession(session);
    if (kind != null && !recordKinds.contains(kind) ||
        state != null && !RegExp(r'^[a-z][a-z_]{0,63}$').hasMatch(state) ||
        offset < 0 ||
        offset > 1000000 ||
        limit < 1 ||
        limit > 100) {
      throw const AccessFailure('invalid_query');
    }
    final records =
        _ownRequestRecords(session)
            .where(
              (r) =>
                  (!proposalsOnly ||
                      {'import', 'update', 'delete'}.contains(r['kind'])) &&
                  (kind == null || r['kind'] == kind) &&
                  (state == null || r['status'] == state),
            )
            .toList()
          ..sort((a, b) {
            final date = (b['createdAt'] as String).compareTo(
              a['createdAt'] as String,
            );
            return date != 0
                ? date
                : (a['id'] as String).compareTo(b['id'] as String);
          });
    return {
      'status': 'ok',
      'records': records.skip(offset).take(limit).toList(),
      'total': records.length,
      'offset': offset,
      'nextOffset': offset + limit < records.length ? offset + limit : null,
    };
  }

  Map<String, Object?> showOwnRequest(String session, String id) {
    _service._requireSession(session);
    final record = _ownRequestRecords(
      session,
    ).where((r) => r['id'] == id).firstOrNull;
    if (record == null) return {'status': 'not_found'};
    if (record['protocolVersion'] == 3) {
      final r = _service._batchRequest(id);
      return {...record, ...credentialBatchStatus(session, r.deviceId, id)};
    }
    final detail = switch (record['kind']) {
      'import' => importStatus(session, id),
      'update' => updateStatus(session, id),
      'delete' => deleteStatus(session, id),
      'organization' => organizationStatus(session, id),
      _ => status(session, id),
    };
    return {...record, ...detail};
  }

  Iterable<Map<String, Object?>> _ownOperationRecords(String session) sync* {
    _service._requireSession(session);
    for (final r in _ownRequestRecords(session)) {
      if (r['operationId'] is! String) continue;
      yield {
        'id': r['operationId'],
        'operationId': r['operationId'],
        'kind': {'import', 'update', 'delete'}.contains(r['kind'])
            ? 'proposal-submit'
            : 'request-submit',
        'requestId': r['id'],
        'requestKind': r['kind'],
        'state': 'submitted',
        'requestStatus': r['status'],
        'createdAt': r['createdAt'],
      };
    }
    if (_service._repository case CredentialBatchRepository batches) {
      final binding = _service._sessionBindings[session];
      for (final operation in batches.credentialBatchOperations) {
        if (operation.sessionBinding != binding) continue;
        yield {
          ..._service._batchOperationForDisplay(operation).toPublicJson(),
          'id': operation.operationId,
          'kind': 'credential-fill',
          'state': _service._batchOperationForDisplay(operation).state.name,
        };
      }
    }
    if (_service._repository case CredentialRuntimeRepository runtime) {
      for (final e in runtime.credentialExecutions) {
        if (_service._credentialUseSessions[e.requestId] != session) continue;
        yield {
          ...e.toJson(),
          'id': e.operationId ?? e.id,
          'kind': 'credential-execution',
          'state': e.state,
          'createdAt': _useTimestamp(
            e.createdAt ??
                e.startedAt ??
                runtime.credentialUseRequests
                    .firstWhere((r) => r.id == e.requestId)
                    .createdAt,
          ),
        };
      }
      for (final r in runtime.credentialUseRequests) {
        if (_service._credentialUseSessions[r.id] != session) continue;
        for (final read in r.revealReads) {
          yield {
            'id': read.operationId,
            'operationId': read.operationId,
            'requestId': r.id,
            'kind': 'credential-reveal-read',
            'state': 'completed',
            'createdAt': _useTimestamp(read.at),
          };
        }
      }
      if (runtime is FocusedFillRuntimeRepository) {
        for (final operation in (runtime).focusedFillOperations) {
          if (_service._credentialUseSessions[operation.requestId] != session) {
            continue;
          }
          yield {
            ...operation.toJson(),
            'id': operation.operationId,
            'kind': 'focused-fill',
            'state': operation.state.name,
          };
        }
      }
    }
  }

  Map<String, Object?> queryOwnOperations(
    String session, {
    String? requestId,
    int offset = 0,
    int limit = 20,
  }) {
    _service._requireSession(session);
    if (offset < 0 ||
        offset > 1000000 ||
        limit < 1 ||
        limit > 100 ||
        requestId != null && (requestId.isEmpty || requestId.length > 200)) {
      throw const AccessFailure('invalid_query');
    }
    final records =
        _ownOperationRecords(session)
            .where((r) => requestId == null || r['requestId'] == requestId)
            .toList()
          ..sort((a, b) {
            final time = (b['createdAt'] as String).compareTo(
              a['createdAt'] as String,
            );
            return time != 0
                ? time
                : (a['id'] as String).compareTo(b['id'] as String);
          });
    return {
      'status': 'ok',
      'records': records.skip(offset).take(limit).toList(),
      'total': records.length,
      'offset': offset,
      'nextOffset': offset + limit < records.length ? offset + limit : null,
    };
  }

  Map<String, Object?> showOwnOperation(String session, String id) {
    _service._requireSession(session);
    final matches = _ownOperationRecords(
      session,
    ).where((r) => r['id'] == id).toList();
    if (matches.isEmpty) return {'status': 'not_found'};
    // Legacy protocols allowed the same operation ID in separate namespaces.
    // Do not guess an execution when a submit shares its ID.
    if (matches.length != 1) throw const AccessFailure('operation_conflict');
    return {'status': 'ok', ...matches.single};
  }
}
