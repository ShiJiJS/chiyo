part of 'info_core.dart';

extension SshSessionAgentAccess on AgentAccess {
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
