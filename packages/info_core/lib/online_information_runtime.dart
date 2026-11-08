part of 'info_core.dart';

/// Trusted online host boundary. All host commands, including owner decisions,
/// run through [run] so a reply is published only after private state is saved.
/// This is separate from portable history/backup and grants no Agent authority.
final class OnlineInformationRuntime {
  OnlineInformationRuntime._(this.service, this._state, this._generation);
  final InformationService service;
  final ServerStateRepository _state;
  String _generation;
  Future<void> _queue = Future.value();
  bool _closing = false, _failed = false;
  Future<void>? _closeFuture;

  static Future<OnlineInformationRuntime> open({
    required InformationRepository repository,
    DateTime Function()? clock,
  }) async {
    if (repository is! ServerStateRepository) {
      throw const AccessFailure('unsupported_capability');
    }
    final state = repository as ServerStateRepository;
    final snapshot = await state.openServerState();
    final service = InformationService._online(
      repository: repository,
      clock: clock,
    );
    final runtime = OnlineInformationRuntime._(
      service,
      state,
      snapshot.generation,
    );
    try {
      if (snapshot.payload.containsKey('textRuntime') &&
          snapshot.payload['textRuntime'] == null) {
        throw const FormatException('Invalid online state');
      }
      runtime._restore(snapshot.payload['textRuntime']);
      await runtime._save();
      return runtime;
    } on Object {
      // A malformed or unavailable state must never be replaced with an empty
      // usable runtime. Preserve disk evidence; close resources without writes.
      await service._close(preserveOnlineAuthorizations: true);
      rethrow;
    }
  }

  Future<T> run<T>(FutureOr<T> Function() action) {
    if (_closing || _failed) {
      return Future.error(const AccessFailure('service_unavailable'));
    }
    final result = _queue.then((_) async {
      if (_failed) throw const AccessFailure('service_unavailable');
      await _checkGeneration();
      await _resolveDeviceCredentialDecisions();
      final libraryGeneration = service._libraryGeneration;
      try {
        return await action();
      } finally {
        // Only the successful original Owner restore barrier changes this
        // in-memory generation. A portable restore atomically deletes private
        // server state; adopt that fresh, empty generation before checkpointing
        // the now-cleared runtime. Never adopt an external generation change or
        // a restore that failed before its storage commit.
        if (service._libraryGeneration != libraryGeneration) {
          await _afterOwnerRestore(libraryGeneration);
        }
        // Failed commands can still expire/end/revoke a capability. Persist
        // those facts too; failure here overrides any content result.
        await _save();
      }
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _afterOwnerRestore(int previousLibraryGeneration) async {
    try {
      final fresh = await _state.openServerState();
      if (service._libraryGeneration != previousLibraryGeneration + 1 ||
          fresh.generation == _generation ||
          fresh.revision != 0 ||
          fresh.payload.isNotEmpty) {
        throw const AccessFailure('library_changed');
      }
      _generation = fresh.generation;
    } on Object {
      _failed = true;
      rethrow;
    }
  }

  Future<void> _checkGeneration() async {
    try {
      if ((await _state.openServerState()).generation != _generation) {
        throw const AccessFailure('library_changed');
      }
    } on Object {
      _failed = true;
      rethrow;
    }
  }

  Future<void> _save() async {
    try {
      await service._drainInformationDecisions();
      await _resolveDeviceCredentialDecisions();
      _restoreDeviceCredentialFieldGrants();
      for (final request in service._requests.values) {
        service._expire(request);
      }
      for (final task in service.owner.organizationTasks) {
        service.owner.organizationState(task);
      }
      await _maintainDeviceCredentialRequests();
      await service._auditWrites;
      if (service._auditFailed ||
          service._uncertainInformationDecisions.isNotEmpty) {
        throw const AccessFailure('audit_unavailable');
      }
      final value = _encode();
      for (var attempt = 0; attempt < 8; attempt++) {
        final snapshot = await _state.openServerState();
        if (snapshot.generation != _generation) {
          throw const AccessFailure('library_changed');
        }
        try {
          await _state.commitServerState(snapshot, {
            ...snapshot.payload,
            'textRuntime': value,
          });
          return;
        } on AccessFailure catch (e) {
          // Device enrollment/binding may write another namespace between our
          // read and CAS. Refresh it rather than overwriting that change.
          if (e.status != 'server_state_changed' || attempt == 7) rethrow;
        }
      }
    } on Object {
      _failed = true;
      rethrow;
    }
  }

  Map<String, Object?> _encode() => {
    'version': 3,
    'credentialRuntime': _encodeDeviceCredentialRequests(),
    'expiredOrganizations': [
      for (final task in service.owner.organizationTasks)
        if (service._expiredOrganizations.contains(task.id)) task.id,
    ],
    'sessions': [
      for (final entry in service._sessions.entries)
        {
          'secret': entry.key,
          'label': entry.value,
          'binding': service._sessionBindings[entry.key],
          'ended': service._endedSessions.contains(entry.key),
        },
    ],
    'endCapabilities': {...service._endCapabilities},
    'requests': [
      for (final request in service._requests.values)
        // Mixed field scopes remain exact ordinary grants, but only for
        // credential requests explicitly bound to an online device.
        if (!service._credentialUseSessions.containsKey(request.id) ||
            service._deviceCredentialRequests.containsKey(request.id))
          {
            'id': request.id,
            'session': request.session,
            'purpose': request.purpose,
            'operationId': request.operationId,
            'createdAt': request.createdAt.toUtc().toIso8601String(),
            'expiresAt': request.expiresAt.toUtc().toIso8601String(),
            'state': request.state.name,
            'fields': request.fields.map((f) => f.toJson()).toList(),
            'recordedFields': request.recordedFields
                .map((f) => f.toJson())
                .toList(),
            'invalidatedFields': request.invalidatedFields
                .map((f) => f.toJson())
                .toList(),
            if (request.grant case final grant?)
              'grant': {
                'token': grant.token,
                'expiresAt': grant.expiresAt.toUtc().toIso8601String(),
                'fields': grant.fields.map((f) => f.toJson()).toList(),
              },
          },
    ],
  };

  void _restore(Object? raw) {
    Map<String, dynamic> object(Object? value) {
      if (value is! Map) throw const FormatException('Invalid online state');
      return Map<String, dynamic>.from(value);
    }

    List<dynamic> list(Object? value) {
      if (value is! List || value.length > 100000) {
        throw const FormatException('Invalid online state');
      }
      return value;
    }

    String text(Object? value, [int max = 2000]) {
      if (value is! String || value.isEmpty || value.length > max) {
        throw const FormatException('Invalid online state');
      }
      return value;
    }

    DateTime date(Object? value) => DateTime.parse(text(value, 50)).toUtc();
    Set<FieldRef> fields(Object? value) {
      final result = list(value).map((v) {
        final f = object(v);
        return FieldRef(text(f['itemId'], 200), text(f['fieldId'], 200));
      }).toSet();
      if (result.length > 200) {
        throw const FormatException('Invalid online state');
      }
      return result;
    }

    final ended = <String>{};
    if (raw != null) {
      final data = object(raw);
      if (data['version'] != 1 &&
          data['version'] != 2 &&
          data['version'] != 3) {
        throw const FormatException('Invalid online state version');
      }
      if (data['version'] != 1) {
        final known = {
          for (final task in service.owner.organizationTasks) task.id,
        };
        for (final value in list(data['expiredOrganizations'])) {
          final id = text(value, 200);
          if (known.contains(id)) service._expiredOrganizations.add(id);
        }
      }
      for (final value in list(data['sessions'])) {
        final row = object(value), secret = text(object(value)['secret'], 200);
        if (service._sessions.containsKey(secret) || row['ended'] is! bool) {
          throw const FormatException('Invalid online state session');
        }
        service._sessions[secret] = text(row['label'], 200);
        service._sessionBindings[secret] = text(row['binding'], 200);
        if (row['ended'] as bool) ended.add(secret);
      }
      if (data['version'] == 3) {
        _restoreDeviceCredentialRequests(data['credentialRuntime']);
      }
      for (final entry in object(data['endCapabilities']).entries) {
        if (!service._sessions.containsKey(entry.value)) {
          throw const FormatException('Invalid online state capability');
        }
        service._endCapabilities[text(entry.key, 200)] = text(entry.value, 200);
      }
      final histories = {
        for (final h in service._repository.requestHistory) h.id: h,
      };
      final grants = {
        for (final h in service._repository.grantHistory) h.id: h,
      };
      final credentialRequestIds =
          service._repository is CredentialRuntimeRepository
          ? {
              for (final r in service._runtimeRepository.credentialUseRequests)
                r.id,
            }
          : <String>{};
      for (final value in list(data['requests'])) {
        final row = object(value),
            session = text(object(value)['session'], 200);
        final id = text(row['id'], 200), operation = row['operationId'];
        if (credentialRequestIds.contains(id) &&
            (!service._deviceCredentialRequests.containsKey(id) ||
                service._credentialUseSessions[id] != session ||
                service._inactiveCredentialApprovals.contains(id))) {
          throw const FormatException(
            'Inconsistent online credential field binding',
          );
        }
        if (!service._sessions.containsKey(session) ||
            service._requests.containsKey(id) ||
            operation != null &&
                (operation is! String ||
                    !RegExp(
                      r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
                    ).hasMatch(operation))) {
          throw const FormatException('Invalid online state request');
        }
        final request = _Request(
          id,
          session,
          text(row['purpose']),
          Set.unmodifiable(fields(row['fields'])),
          date(row['createdAt']),
          date(row['expiresAt']),
          operationId: operation as String?,
        );
        if (request.fields.isEmpty ||
            !request.expiresAt.isAfter(request.createdAt)) {
          throw const FormatException('Invalid online state request');
        }
        request.state = AccessRequestState.values.byName(
          text(row['state'], 20),
        );
        request.recordedFields = list(
          row['recordedFields'],
        ).map((v) => RecordedField.fromJson(object(v))).toList();
        request.invalidatedFields.addAll(fields(row['invalidatedFields']));
        final fact = histories[id];
        if (fact != null) {
          if (fact.restoredAt != null ||
              fact.sessionId != service._sessionBindings[session] ||
              fact.createdAt != request.createdAt ||
              fact.requestExpiresAt != request.expiresAt ||
              fact.purpose != request.purpose) {
            throw const FormatException('Inconsistent online history');
          }
          // Durable terminal facts win even if a crash interrupted saving the
          // private snapshot after the approval/revocation transaction.
          request.state = fact.state;
          if (fact.sessionEnded || fact.applicationClosed) ended.add(session);
          request.history = fact.grantId == null ? null : grants[fact.grantId];
        } else if (request.state == AccessRequestState.approved) {
          // Retention may have removed old facts. Missing proof of an active
          // grant cannot keep it usable; terminal snapshots remain terminal.
          request.state = AccessRequestState.revoked;
        }
        final grant = request.history;
        if (grant != null) {
          if (grant.restoredAt != null ||
              grant.requestId != id ||
              grant.sessionId != service._sessionBindings[session] ||
              !request.fields.containsAll(
                grant.fields.map((f) => FieldRef(f.itemId, f.fieldId)),
              )) {
            throw const FormatException('Inconsistent online grant');
          }
          request.approvedAt = grant.approvedAt;
          if (request.state == AccessRequestState.approved && !grant.active) {
            request.state = grant.events.last.kind == GrantEventKind.expired
                ? AccessRequestState.expired
                : AccessRequestState.revoked;
          }
        }
        if (request.state == AccessRequestState.approved && grant == null) {
          throw const FormatException('Missing online grant');
        }
        if (row['grant'] != null && grant != null) {
          final saved = object(row['grant']);
          final approved = fields(saved['fields']);
          if (date(saved['expiresAt']) != grant.expiresAt ||
              approved.length != grant.fields.length ||
              !approved.containsAll(
                grant.fields.map((f) => FieldRef(f.itemId, f.fieldId)),
              )) {
            throw const FormatException('Inconsistent online scope');
          }
          request.grant = ClaimedGrant(
            text(saved['token'], 200),
            approved.toList(),
            grant.expiresAt,
          );
        } else if (request.state == AccessRequestState.approved) {
          // Approval committed but no reply was published before the crash.
          // Resume that exact recorded scope/deadline, never extend it.
          request.grant = ClaimedGrant(
            service._secret(),
            grant!.fields.map((f) => FieldRef(f.itemId, f.fieldId)).toList(),
            grant.expiresAt,
          );
        }
        service._requests[id] = request;
        if (request.grant case final proof?) {
          if (service._grants.containsKey(proof.token)) {
            throw const FormatException('Duplicate online proof');
          }
          service._grants[proof.token] = request;
        }
      }
    }
    _restoreDeviceCredentialFieldGrants();
    for (final intent in service._onlineCredentialDecisions.values) {
      service._requests[intent.requestId]?.informationDecisionPending = true;
    }
    for (final session in ended) {
      service._endSession(session);
    }
    for (final request in service._requests.values) {
      service._expire(request);
    }
    // A history record alone (e.g. a portable restore) never creates capability.
    final reconciled = {
      for (final r in service._requests.values)
        if (r.history != null) r.history!.id,
    };
    for (final history in service._repository.grantHistory.where(
      (g) =>
          g.active &&
          !reconciled.contains(g.id) &&
          !service._onlineCredentialDecisionPending(g.requestId),
    )) {
      final expired = !service._clock().isBefore(history.expiresAt);
      final finished = history.finish(
        expired ? GrantEventKind.expired : GrantEventKind.applicationClosed,
        expired ? history.expiresAt : service._clock(),
      );
      service._enqueueAudit(
        () => service._repository.saveGrantHistory(finished),
      );
    }
    service._pruneAudit();
  }

  /// Ordinary server maintenance preserves valid capabilities. The host must
  /// stop accepting requests first, then close this runtime, then the repository.
  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closing = true;
    return _closeFuture = _queue.then((_) async {
      try {
        await service.agent.drainInformationFileDeliveries();
        if (!_failed) await _save();
      } finally {
        await service._close(preserveOnlineAuthorizations: true);
      }
    });
  }
}
