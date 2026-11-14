part of 'info_core.dart';

/// Approved remote destination and credential use. Authentication prompts and
/// transient session/run/receiver IDs are not reusable authorization scopes.
class SshSessionTarget {
  SshSessionTarget({
    required this.host,
    required this.port,
    required this.user,
    required this.authentication,
    required this.credentialUse,
    required this.validity,
    this.trustId,
    this.trustHash,
  }) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9.:%_-]{0,252}$').hasMatch(host) ||
        port < 1 ||
        port > 65535 ||
        !RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.@-]{0,127}$').hasMatch(user) ||
        !{'password', 'publickey'}.contains(authentication) ||
        !{'login', 'sudo'}.contains(credentialUse) ||
        credentialUse == 'sudo' && authentication != 'password' ||
        !{'limited', 'session'}.contains(validity) ||
        (trustId == null) != (trustHash == null) ||
        trustHash != null &&
            !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(trustHash!)) {
      throw const CredentialUseFailure('invalid_plan');
    }
  }
  final String host, user, authentication, credentialUse, validity;
  final int port;
  final String? trustId, trustHash;
  factory SshSessionTarget.fromJson(Map<String, dynamic> value) {
    _useShape(
      value,
      {'host', 'port', 'user', 'authentication', 'credentialUse', 'validity'},
      {'trustId', 'trustHash'},
    );
    return SshSessionTarget(
      host: value['host'] as String,
      port: value['port'] as int,
      user: value['user'] as String,
      authentication: value['authentication'] as String,
      credentialUse: value['credentialUse'] as String,
      validity: value['validity'] as String,
      trustId: value['trustId'] as String?,
      trustHash: value['trustHash'] as String?,
    );
  }
  SshSessionTarget trusted(SshHostTrustSnapshot trust) => SshSessionTarget(
    host: host,
    port: port,
    user: user,
    authentication: authentication,
    credentialUse: credentialUse,
    validity: validity,
    trustId: trust.id,
    trustHash: trust.sha256,
  );
  bool accepts(CredentialForm form) =>
      form ==
      (authentication == 'publickey'
          ? CredentialForm.file
          : CredentialForm.string);
  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    'user': user,
    'authentication': authentication,
    'credentialUse': credentialUse,
    'validity': validity,
    if (trustId != null) 'trustId': trustId,
    if (trustHash != null) 'trustHash': trustHash,
  };
}

class SshSessionOperationContext {
  SshSessionOperationContext({
    required this.kind,
    required this.sessionId,
    required this.digest,
    this.runId,
    this.actionId,
    this.byteLength,
  }) {
    if (!{'open', 'run', 'input', 'credential'}.contains(kind) ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(sessionId) ||
        !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(digest) ||
        (kind == 'open' ? runId != null : runId == null) ||
        (kind == 'credential') != (actionId != null) ||
        byteLength != null && (byteLength! < 0 || byteLength! > 65536)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    if (runId != null) _batchOperationId(runId);
    if (actionId != null) _batchOperationId(actionId);
  }
  final String kind, sessionId, digest;
  final String? runId, actionId;
  final int? byteLength;
  bool get requiresMaterial => kind == 'open' || kind == 'credential';
  factory SshSessionOperationContext.fromJson(Map<String, dynamic> json) {
    _useShape(
      json,
      {'kind', 'sessionId', 'digest'},
      {'runId', 'actionId', 'byteLength'},
    );
    return SshSessionOperationContext(
      kind: json['kind'] as String,
      sessionId: json['sessionId'] as String,
      digest: json['digest'] as String,
      runId: json['runId'] as String?,
      actionId: json['actionId'] as String?,
      byteLength: json['byteLength'] as int?,
    );
  }
  Map<String, Object?> toJson() => {
    'kind': kind,
    'sessionId': sessionId,
    'digest': digest,
    'runId': ?runId,
    'actionId': ?actionId,
    'byteLength': ?byteLength,
  };
}
