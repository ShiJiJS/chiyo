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
