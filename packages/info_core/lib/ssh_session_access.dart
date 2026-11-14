part of 'info_core.dart';

extension SshSessionAgentAccess on AgentAccess {
  Map<String, Object?> reusableSshSessionGrant(
    String session,
    String device,
    String credentialId,
    int version,
    SshSessionTarget target,
  ) {
    _service._requireSession(session);
    final trust = _service._sshHostTrust;
    if (trust == null) throw const CredentialUseFailure('receiver_not_ready');
    final expected = _useFingerprint(target.trusted(trust).toJson());
    for (final request
        in _service._batchRepository.credentialBatches.reversed) {
      if (request.deviceId != device ||
          request.sessionBinding != _service._sessionBindings[session] ||
          request.items.length != 1) {
        continue;
      }
      final item = request.items.single;
      if (item.credentialId != credentialId ||
          item.version != version ||
          item.destination.ssh == null ||
          _useFingerprint(item.destination.ssh!.toJson()) != expected) {
        continue;
      }
      try {
        _service._requireBatchItem(request, item);
      } on CredentialUseFailure {
        continue;
      }
      return {
        ...credentialBatchStatus(session, device, request.id),
        'reused': true,
      };
    }
    return {'status': 'not_found'};
  }

  /// Checks live grant, fixed credential version, source device/chat and the
  /// approved host-trust snapshot without claiming login material again.
  Map<String, Object?> checkSshSessionGrant(
    String session,
    String device,
    String requestId, {
    bool includeTrust = false,
  }) {
    final request = _service._sessionBatch(session, device, requestId);
    if (request.items.length != 1 ||
        request.items.single.destination.ssh == null) {
      throw const CredentialUseFailure('unsupported_receiver');
    }
    final item = request.items.single;
    _service._requireBatchItem(request, item);
    return {
      'status': 'ok',
      'target': item.destination.ssh!.toJson(),
      'itemId': item.id,
      'credentialId': item.credentialId,
      'version': item.version,
      if (includeTrust)
        'knownHostsBase64': base64Encode(_service._sshHostTrust!.bytes),
    };
  }
}
