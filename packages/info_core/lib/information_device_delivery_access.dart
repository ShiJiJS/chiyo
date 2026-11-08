part of 'info_core.dart';

/// Online delivery never creates a server file lease. The same approved field,
/// immutable version and operation record are used while the trusted device
/// executor owns its real reservation, verified copy and cleanup capability.
extension DeviceInformationFileAgentAccess on AgentAccess {
  Future<Map<String, Object?>> _prepareDeviceInformationFile(
    String session,
    InformationFileFetchInput input,
  ) async {
    final binding = _service._sessionBindings[session]!;
    final existing = _service._informationDeliveries
        .where(
          (r) =>
              r.runtime &&
              r.sessionBinding == binding &&
              r.operationId == input.operationId,
        )
        .firstOrNull;
    if (existing != null) {
      if (!existing.deviceDelivery ||
          existing.requestId != input.requestId ||
          existing.fieldRef != input.field) {
        throw const InformationFileFailure(
          'operation_conflict',
          operationClaimed: true,
        );
      }
    }
    final request = _service._fileRequest(
      session,
      input.requestId,
      input.field,
    );
    if (existing != null) {
      var result = existing;
      if (result.cleanupCapability == null &&
          !InformationFileDelivery.terminals.contains(result.state)) {
        result = result.changed({
          'cleanupCapability': _service._secret().replaceAll('=', ''),
        });
        await _service._saveInformationDelivery(result);
        _service._checkDeviceFileDelivery(session, result);
      }
      return _fileReply(result, deviceProof: true);
    }
    final field = _service._field(input.field)!;
    if (field.kind != FieldKind.file) {
      throw const InformationFileFailure('not_a_file');
    }
    final repo = _service._repository as InformationAttachmentRepository;
    final version = (await repo.informationAttachmentVersions(
      field.attachment!.attachmentId,
    )).where((v) => v.reference == field.attachment && v.available).firstOrNull;
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
    final record = InformationFileDelivery.preparing(
      id: _service._secret(),
      sessionBinding: binding,
      operationId: input.operationId,
      requestId: input.requestId,
      grantId: request.history!.id,
      field: RecordedField(item.id, field.id, item.name, field.name),
      fieldVersion: field.version,
      version: version,
      createdAt: _service._clock().toUtc(),
      expiresAt: request.grant!.expiresAt.toUtc(),
      deviceDelivery: true,
      cleanupCapability: _service._secret().replaceAll('=', ''),
    );
    await _service._saveInformationDelivery(record, claim: true);
    _service._checkDeviceFileDelivery(session, record);
    return _fileReply(record, deviceProof: true);
  }

  Future<Map<String, Object?>> downloadDeviceInformationFile(
    String session,
    String deliveryId,
  ) => _service.owner._serialize(() async {
    _service._deviceFileSession(session);
    _deliveryId(deliveryId);
    await _service._reconcileInformationDeliveries();
    final record = _service._ownInformationDelivery(session, deliveryId);
    _service._checkDeviceFileDelivery(session, record);
    if (!{'preparing', 'ready'}.contains(record.state)) {
      throw InformationFileFailure(
        'not_authorized',
        deliveryId: record.id,
        operationClaimed: true,
      );
    }
    final bytes = await _readDeliveryOriginal(
      _service._repository as InformationAttachmentRepository,
      record,
      validate: () => _service._checkDeviceFileDelivery(session, record),
    );
    return {
      ..._fileReply(record, deviceProof: true),
      'bytes': base64Encode(bytes),
    };
  });

  Future<Map<String, Object?>> completeDeviceInformationFile(
    String session,
    String deliveryId,
    int byteLength,
    String digest,
  ) => _service.owner._serialize(() async {
    _service._deviceFileSession(session);
    _deliveryId(deliveryId);
    await _service._reconcileInformationDeliveries();
    var record = _service._ownInformationDelivery(session, deliveryId);
    _service._checkDeviceFileDelivery(session, record);
    if (byteLength != record.byteLength || digest != record.sha256) {
      throw const InformationFileFailure('attachment_integrity_failed');
    }
    if (record.state == 'ready') return _fileReply(record, deviceProof: true);
    if (record.state != 'preparing') {
      throw const InformationFileFailure('not_authorized');
    }
    record = record.changed({'state': 'ready'});
    await _service._saveInformationDelivery(record);
    _service._checkDeviceFileDelivery(session, record);
    return _fileReply(record, deviceProof: true);
  });

  /// Cleanup acknowledgement conveys no content authority. An ended session
  /// can still confirm unlink of its own registered device copy; it cannot
  /// read, fetch, complete or use another device/session's delivery.
  Future<Map<String, Object?>> cleanupDeviceInformationFile(
    String session,
    String deliveryId,
  ) => _service.owner._serialize(() async {
    if (!_service._deviceFileDelivery || !informationFileDeliveryAvailable) {
      throw const InformationFileFailure('unsupported_capability');
    }
    if (_service._closed || _service._backupBusy) {
      throw const InformationFileFailure('service_unavailable');
    }
    if (!_service._sessionBindings.containsKey(session)) {
      throw const InformationFileFailure('not_authorized');
    }
    _deliveryId(deliveryId);
    await _service._reconcileInformationDeliveries();
    var record = _service._ownInformationDelivery(session, deliveryId);
    if (!record.deviceDelivery) {
      throw const InformationFileFailure('not_authorized');
    }
    record = await _service._acknowledgeDeviceCopyCleanup(record);
    return _fileReply(record);
  });

  Future<Map<String, Object?>> watchDeviceInformationFile(
    InformationFileCleanupInput input,
  ) => _service.owner._serialize(() async {
    var record = _service._cleanupDeviceCopy(input);
    await _service._reconcileInformationDeliveries();
    record = _service._cleanupDeviceCopy(input);
    return {
      'protocolVersion': 2,
      'status': 'ok',
      'delivery': record.statusJson(),
    };
  });

  Future<Map<String, Object?>> discardDeviceInformationFile(
    InformationFileCleanupInput input,
  ) => _service.owner._serialize(() async {
    _service._cleanupDeviceCopy(input);
    await _service._reconcileInformationDeliveries();
    final record = await _service._acknowledgeDeviceCopyCleanup(
      _service._cleanupDeviceCopy(input),
    );
    return {
      'protocolVersion': 2,
      'status': 'ok',
      'delivery': record.statusJson(),
    };
  });
}

extension _DeviceInformationFileService on InformationService {
  InformationFileDelivery _cleanupDeviceCopy(
    InformationFileCleanupInput input,
  ) {
    if (!_deviceFileDelivery || !agent.informationFileDeliveryAvailable) {
      throw const InformationFileFailure('unsupported_capability');
    }
    if (_closed || _backupBusy) {
      throw const InformationFileFailure('service_unavailable');
    }
    final record = _informationDeliveries
        .where((r) => r.runtime && r.deviceDelivery && r.id == input.deliveryId)
        .firstOrNull;
    final expected = sha256
        .convert(utf8.encode(record?.cleanupCapability ?? ''))
        .bytes;
    final supplied = sha256.convert(utf8.encode(input.capability)).bytes;
    var different = 0;
    for (var n = 0; n < expected.length; n++) {
      different |= expected[n] ^ supplied[n];
    }
    if (record == null || record.cleanupCapability == null || different != 0) {
      throw const InformationFileFailure('not_authorized');
    }
    return record;
  }

  Future<InformationFileDelivery> _acknowledgeDeviceCopyCleanup(
    InformationFileDelivery record,
  ) async {
    if (record.state == 'ready' || record.state == 'preparing') {
      record = await _finishInformationDelivery(record, 'released', 'released');
    }
    if (record.state == 'cleanup_pending') {
      record = record.changed({
        'state': record.targetState!,
        'targetState': null,
        'cleanupError': null,
      });
      await _saveInformationDelivery(record);
    }
    return record;
  }

  void _deviceFileSession(String session) {
    if (!_deviceFileDelivery || !agent.informationFileDeliveryAvailable) {
      throw const InformationFileFailure('unsupported_capability');
    }
    _fileSession(session);
  }

  void _checkDeviceFileDelivery(
    String session,
    InformationFileDelivery record,
  ) {
    _deviceFileSession(session);
    final request = _fileRequest(session, record.requestId, record.fieldRef);
    if (!record.deviceDelivery ||
        record.sessionBinding != _sessionBindings[session] ||
        request.history?.id != record.grantId) {
      throw const InformationFileFailure('field_removed');
    }
  }
}

/// Both local and remote delivery read and validate the same immutable bytes.
Future<Uint8List> _readDeliveryOriginal(
  InformationAttachmentRepository repo,
  InformationFileDelivery record, {
  required void Function() validate,
}) => repo.withInformationAttachment(record.attachment, (actual, chunks) async {
  if (actual.reference != record.attachment ||
      actual.sha256 != record.sha256 ||
      actual.byteLength != record.byteLength) {
    throw const InformationFileFailure('attachment_integrity_failed');
  }
  final body = BytesBuilder(copy: false), result = _InformationFileDigest();
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
  validate();
  return body.takeBytes();
});
