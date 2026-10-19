part of 'info_core.dart';

extension InformationFileAgentAccess on AgentAccess {
  Future<void> drainInformationFileDeliveries() async {
    while (true) {
      final work = _service._informationDeliveryCleanup;
      await work;
      if (identical(work, _service._informationDeliveryCleanup)) return;
    }
  }

  bool get informationFileDeliveryAvailable =>
      _service.informationDeliveryFiles != null &&
      _service._repository is InformationAttachmentRepository &&
      _service._repository is InformationFileDeliveryRepository;

  Future<Map<String, Object?>> fetchInformationFile(
    String session,
    InformationFileFetchInput input,
  ) => _service.owner._serialize(() async {
    _service._fileSession(session);
    if (!informationFileDeliveryAvailable) {
      throw const InformationFileFailure('unsupported_capability');
    }
    await _service._reconcileInformationDeliveries();
    final binding = _service._sessionBindings[session]!;
    final existing = _service._informationDeliveries
        .where(
          (r) =>
              r.runtime &&
              r.sessionBinding == binding &&
              r.operationId == input.operationId,
        )
        .firstOrNull;
    if (existing != null &&
        (existing.requestId != input.requestId ||
            existing.fieldRef != input.field)) {
      throw const InformationFileFailure(
        'operation_conflict',
        operationClaimed: true,
      );
    }
    final request = _service._fileRequest(
      session,
      input.requestId,
      input.field,
    );
    if (existing != null) {
      if (existing.state != 'ready') return _fileReply(existing);
      try {
        await _service.informationDeliveryFiles!.verify(
          existing.lease!,
          existing.byteLength,
          existing.sha256,
        );
      } on Object catch (error) {
        final code = _service._deliveryError(error);
        await _service._finishInformationDelivery(existing, 'failed', code);
        throw InformationFileFailure(
          code,
          deliveryId: existing.id,
          operationClaimed: true,
        );
      }
      _service._fileRequest(session, input.requestId, input.field);
      return _fileReply(existing, ready: true);
    }
    final current = _service._field(input.field)!;
    if (current.kind != FieldKind.file) {
      throw const InformationFileFailure('not_a_file');
    }
    final repo = _service._repository as InformationAttachmentRepository;
    final version =
        (await repo.informationAttachmentVersions(
              current.attachment!.attachmentId,
            ))
            .where((v) => v.reference == current.attachment && v.available)
            .firstOrNull;
    if (version == null) {
      throw const InformationFileFailure('attachment_missing');
    }
    _service._fileRequest(session, input.requestId, input.field);
    final held = _service._informationDeliveries
        .where((r) => r.holdsCopy)
        .toList();
    if (_service._informationDeliveries.length >=
            informationDeliveryHistoryLimit ||
        held.length >= informationDeliveryLimit ||
        held.fold<int>(0, (n, r) => n + r.byteLength) + version.byteLength >
            informationDeliveryByteLimit) {
      throw const InformationFileFailure('delivery_capacity');
    }
    final item = _service._repository.items.firstWhere(
      (i) => i.id == input.field.itemId,
    );
    var record = InformationFileDelivery.preparing(
      id: _service._secret(),
      sessionBinding: binding,
      operationId: input.operationId,
      requestId: input.requestId,
      grantId: request.history!.id,
      field: RecordedField(item.id, current.id, item.name, current.name),
      fieldVersion: current.version,
      version: version,
      createdAt: _service._clock().toUtc(),
      expiresAt: request.grant!.expiresAt.toUtc(),
    );
    _service._inFlightInformationDeliveries.add(record.id);
    InformationDeliveryLease? reserved;
    try {
      await _service._saveInformationDelivery(record);
      _service._fileRequest(session, input.requestId, input.field);
      final extension =
          RegExp(
            r'\.([A-Za-z0-9]{1,12})$',
          ).firstMatch(version.originalName)?.group(1)?.toLowerCase() ??
          'bin';
      reserved = await _service.informationDeliveryFiles!.reserve(
        'attachment.$extension',
      );
      record = record.changed({'lease': reserved.toPrivateJson()});
      await _service._saveInformationDelivery(record);
      _service._fileRequest(session, input.requestId, input.field);
      await repo.withInformationAttachment(record.attachment, (
        actual,
        chunks,
      ) async {
        if (actual.sha256 != record.sha256 ||
            actual.byteLength != record.byteLength) {
          throw const InformationFileFailure('attachment_integrity_failed');
        }
        final body = BytesBuilder(copy: false),
            result = _InformationFileDigest();
        final hash = sha256.startChunkedConversion(result);
        var length = 0;
        try {
          await for (final bytes in chunks) {
            length += bytes.length;
            if (bytes.length > 1024 * 1024 || length > record.byteLength) {
              throw const InformationFileFailure('attachment_integrity_failed');
            }
            hash.add(bytes);
            body.add(bytes);
          }
        } finally {
          hash.close();
        }
        if (length != record.byteLength ||
            result.value?.toString() != record.sha256) {
          throw const InformationFileFailure('attachment_integrity_failed');
        }
        _service._fileRequest(session, input.requestId, input.field);
        await _service.informationDeliveryFiles!.write(
          reserved!,
          body.takeBytes(),
        );
      });
      await _service.informationDeliveryFiles!.verify(
        reserved,
        record.byteLength,
        record.sha256,
      );
      _service._fileRequest(session, input.requestId, input.field);
      record = record.changed({'state': 'ready'});
      await _service._saveInformationDelivery(record);
      _service._fileRequest(session, input.requestId, input.field);
      return _fileReply(record, ready: true);
    } on Object catch (error) {
      final code = _service._deliveryError(error);
      // Even a failed registry write can leave a known empty reservation.
      // It is kept in the pending audit queue and never exposed to the Agent.
      if (reserved != null && record.lease == null) {
        record = record.changed({'lease': reserved.toPrivateJson()});
      }
      try {
        await _service._finishInformationDelivery(
          record,
          'failed',
          _service._closed
              ? 'service_closed'
              : InformationFileDelivery.reasons.contains(code)
              ? code
              : 'delivery_io_failed',
        );
      } on Object {
        /* Pending immutable facts retain this lease for retry. */
      }
      throw InformationFileFailure(
        code,
        deliveryId: record.id,
        operationClaimed: true,
      );
    } finally {
      _service._inFlightInformationDeliveries.remove(record.id);
    }
  });

  Future<Map<String, Object?>> informationFileStatus(
    String session,
    String deliveryId,
  ) => _service.owner._serialize(() async {
    _service._fileSession(session);
    _deliveryId(deliveryId);
    if (!informationFileDeliveryAvailable) {
      throw const InformationFileFailure('unsupported_capability');
    }
    await _service._reconcileInformationDeliveries();
    return _fileReply(_service._ownInformationDelivery(session, deliveryId));
  });
  Future<Map<String, Object?>> releaseInformationFile(
    String session,
    String deliveryId,
  ) => _service.owner._serialize(() async {
    _service._fileSession(session);
    _deliveryId(deliveryId);
    if (!informationFileDeliveryAvailable) {
      throw const InformationFileFailure('unsupported_capability');
    }
    var record = _service._ownInformationDelivery(session, deliveryId);
    if (record.state == 'ready' || record.state == 'preparing') {
      record = await _service._finishInformationDelivery(
        record,
        'released',
        'released',
      );
    } else if (record.state == 'cleanup_pending') {
      record = await _service._cleanupInformationDelivery(record);
    }
    return _fileReply(record);
  });
}

Map<String, Object?> _fileReply(
  InformationFileDelivery record, {
  bool ready = false,
}) => {
  'protocolVersion': 2,
  'status': 'ok',
  'delivery': ready ? record.readyJson() : record.statusJson(),
};

extension _InformationFileDeliveryService on InformationService {
  List<InformationFileDelivery> get _informationDeliveries {
    final stored = _repository is InformationFileDeliveryRepository
        ? (_repository as InformationFileDeliveryRepository)
              .informationFileDeliveries
        : <InformationFileDelivery>[];
    return List.unmodifiable(
      {
        for (final r in stored) r.id: r,
        ..._pendingInformationDeliveries,
      }.values,
    );
  }

  void _fileSession(String session) {
    if (_closed || _backupBusy) {
      throw const InformationFileFailure('service_unavailable');
    }
    if (_endedSessions.contains(session) &&
        _sessionBindings.containsKey(session)) {
      throw const InformationFileFailure('session_ended');
    }
    if (!_sessionActive(session)) {
      throw const InformationFileFailure('not_authorized');
    }
  }

  _Request _fileRequest(String session, String requestId, FieldRef ref) {
    _fileSession(session);
    final request = _requests[requestId];
    if (request == null ||
        request.session != session ||
        request.grant == null ||
        !request.grant!.fields.contains(ref)) {
      throw const InformationFileFailure('not_authorized');
    }
    _expire(request);
    if (request.state == AccessRequestState.expired) {
      throw const InformationFileFailure('grant_expired');
    }
    if (request.state != AccessRequestState.approved) {
      throw const InformationFileFailure('not_authorized');
    }
    if (request.invalidatedFields.contains(ref) || _field(ref) == null) {
      throw const InformationFileFailure('field_removed');
    }
    return request;
  }

  InformationFileDelivery _ownInformationDelivery(String session, String id) {
    final found = _informationDeliveries
        .where(
          (r) =>
              r.runtime &&
              r.sessionBinding == _sessionBindings[session] &&
              r.id == id,
        )
        .firstOrNull;
    if (found == null) throw const InformationFileFailure('not_authorized');
    return found;
  }

  String _deliveryError(Object error) => switch (error) {
    InformationFileFailure(:final code) => code,
    AccessFailure(status: 'attachment_integrity_failed') =>
      'attachment_integrity_failed',
    RuntimeMaterialFailure(code: 'integrity_failed') =>
      'attachment_integrity_failed',
    _ => 'delivery_io_failed',
  };
  Future<void> _saveInformationDelivery(InformationFileDelivery record) async {
    if (_repository is! InformationFileDeliveryRepository) {
      throw const InformationFileFailure('unsupported_capability');
    }
    _pendingInformationDeliveries[record.id] = record;
    _enqueueAudit(() async {
      await (_repository as InformationFileDeliveryRepository)
          .saveInformationFileDelivery(record);
      if (identical(_pendingInformationDeliveries[record.id], record)) {
        _pendingInformationDeliveries.remove(record.id);
      }
    });
    await _auditWrites;
    if (_auditFailed) {
      throw InformationFileFailure(
        'audit_failed',
        deliveryId: record.id,
        operationClaimed: true,
      );
    }
  }

  Future<InformationFileDelivery> _finishInformationDelivery(
    InformationFileDelivery record,
    String target,
    String reason,
  ) async {
    final now = _clock().toUtc().toIso8601String();
    final finished = record.changed({
      'state': record.lease == null ? target : 'cleanup_pending',
      'targetState': record.lease == null ? null : target,
      'finishedAt': now,
      'reason': reason,
      'cleanupError': null,
    });
    Object? auditError;
    try {
      await _saveInformationDelivery(finished);
    } on Object catch (e) {
      auditError = e;
    }
    final result = finished.lease == null
        ? finished
        : await _cleanupInformationDelivery(finished);
    if (auditError != null) throw auditError;
    return result;
  }

  Future<InformationFileDelivery> _cleanupInformationDelivery(
    InformationFileDelivery record,
  ) async {
    if (record.lease == null) return record;
    var result = record;
    try {
      if (informationDeliveryFiles == null) {
        throw const RuntimeMaterialFailure('cleanup_failed');
      }
      await informationDeliveryFiles!.cleanup(record.lease!);
      result = record.changed({
        'state': record.targetState ?? 'unknown',
        'targetState': null,
        'lease': null,
        'cleanupError': null,
        'finishedAt':
            record.finishedAt?.toIso8601String() ??
            _clock().toUtc().toIso8601String(),
      });
    } on Object catch (error) {
      result = record.changed({
        'state': 'cleanup_pending',
        'targetState': record.targetState ?? 'unknown',
        'finishedAt':
            record.finishedAt?.toIso8601String() ??
            _clock().toUtc().toIso8601String(),
        'cleanupError':
            error is RuntimeMaterialFailure && error.code != 'cleanup_failed'
            ? 'cleanup_identity_mismatch'
            : 'cleanup_failed',
      });
    }
    await _saveInformationDelivery(result);
    return result;
  }

  String? _informationDeliveryInvalid(InformationFileDelivery record) {
    if (_closed) return 'service_closed';
    final session = _sessionBindings.entries
        .where((e) => e.value == record.sessionBinding)
        .firstOrNull
        ?.key;
    if (session == null) return 'restarted';
    if (_endedSessions.contains(session)) return 'session_ended';
    if (!_clock().isBefore(record.expiresAt)) return 'grant_expired';
    try {
      final request = _fileRequest(session, record.requestId, record.fieldRef);
      if (request.history?.id != record.grantId) return 'not_authorized';
    } on InformationFileFailure catch (e) {
      return InformationFileDelivery.reasons.contains(e.code)
          ? e.code
          : 'not_authorized';
    }
    return null;
  }

  Future<int> _reconcileInformationDeliveries() async {
    if (_repository is! InformationFileDeliveryRepository) return 0;
    for (final record in _informationDeliveries.toList()) {
      if (!record.runtime ||
          _inFlightInformationDeliveries.contains(record.id)) {
        continue;
      }
      if (record.state == 'cleanup_pending') {
        await _cleanupInformationDelivery(record);
        continue;
      }
      if (record.state != 'ready' && record.state != 'preparing') continue;
      final reason = _informationDeliveryInvalid(record);
      if (reason != null || record.state == 'preparing') {
        await _finishInformationDelivery(
          record,
          record.state == 'preparing' ? 'unknown' : 'expired',
          reason ?? 'delivery_unknown',
        );
      }
    }
    final cutoff = _clock().subtract(Duration(days: owner.auditRetentionDays));
    final activeBindings = {
      for (final entry in _sessionBindings.entries)
        if (_sessionActive(entry.key)) entry.value,
    };
    final prune = {
      for (final r in _informationDeliveries)
        if (!r.holdsCopy &&
            (!r.runtime ||
                InformationFileDelivery.terminals.contains(r.state)) &&
            (!r.runtime || !activeBindings.contains(r.sessionBinding)) &&
            (r.finishedAt ?? r.createdAt).isBefore(cutoff) &&
            !_clock().isBefore(r.expiresAt))
          r.id,
    };
    if (prune.isNotEmpty) {
      await (_repository as InformationFileDeliveryRepository)
          .pruneInformationFileDeliveryHistory(prune);
    }
    return _informationDeliveries
        .where((r) => r.state == 'cleanup_pending')
        .length;
  }

  void _scheduleInformationDeliveryCleanup() {
    if (informationDeliveryFiles == null) return;
    if (!_informationDeliveries.any((r) => r.runtime && r.holdsCopy)) {
      return;
    }
    _informationDeliveryCleanupRequested = true;
    if (_informationDeliveryCleanupScheduled) return;
    _informationDeliveryCleanupScheduled = true;
    _informationDeliveryCleanup = owner
        ._serialize(() async {
          do {
            _informationDeliveryCleanupRequested = false;
            await _reconcileInformationDeliveries();
          } while (_informationDeliveryCleanupRequested);
        })
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          _informationDeliveryCleanupScheduled = false;
          if (_informationDeliveryCleanupRequested) {
            _scheduleInformationDeliveryCleanup();
          }
        });
  }
}

extension InformationFileDeliveryOwnerAccess on OwnerAccess {
  List<InformationFileDelivery> get informationFileDeliveries =>
      List.unmodifiable(_service._informationDeliveries);
  Future<int> reconcileInformationFileDeliveries() => _serialize(() async {
    await _retryAuditStorage();
    return _service._reconcileInformationDeliveries();
  });
  Future<void> _closeInformationFileDeliveries() {
    // A disabled optional feature must not touch a closed repository during
    // existing callers' repeated shutdown. No copy can be created without it.
    if (_service.informationDeliveryFiles == null) return Future.value();
    if (_service._informationDeliveryShutdownComplete) return Future.value();
    if (!_service._informationDeliveries.any((r) => r.runtime && r.holdsCopy)) {
      _service._informationDeliveryShutdownComplete = true;
      return Future.value();
    }
    return _serialize(() async {
      await _retryAuditStorage();
      await _service._reconcileInformationDeliveries();
      await _service._auditWrites;
      if (_service._auditFailed) {
        throw const InformationFileFailure('audit_failed');
      }
      _service._informationDeliveryShutdownComplete = true;
    });
  }
}
