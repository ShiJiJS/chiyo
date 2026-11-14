import 'dart:async';

/// Private authentication requests originate from a verified child, never from
/// terminal output. Platform code refuses unsupported prompt categories.
class SshLoginChallenge {
  const SshLoginChallenge({
    required this.challengeId,
    required this.processId,
    required this.processIdentity,
    required this.category,
  });
  final String challengeId, processIdentity, category;
  final int processId;
}

typedef SshLoginChallengeHandler =
    Future<List<int>?> Function(SshLoginChallenge challenge);

class SshTransportLaunch {
  const SshTransportLaunch({
    required this.executable,
    required this.arguments,
    required this.environment,
    required this.onLoginChallenge,
    this.onProcessCreated,
  });
  final String executable;
  final List<String> arguments;

  /// Nonsecret environment only. The authentication response uses private IPC.
  final Map<String, String> environment;
  final SshLoginChallengeHandler onLoginChallenge;

  /// Register the native broker before it may start SSH or consume key files.
  final Future<void> Function(int processId, String processIdentity)?
  onProcessCreated;
}

abstract interface class SshTransportLauncher {
  Future<SshTransportProcess> start(SshTransportLaunch launch);
}

abstract interface class SshTransportProcess {
  /// Bounded JSON-lines helper protocol. Terminal data is base64 within frames.
  Stream<List<int>> get output;
  Stream<List<int>> get diagnostics;
  Future<int> get exitCode;
  Future<void> send(List<int> bytes);
  Future<void> closeInput();
  Future<void> terminate();
}

class SshTransportFailure implements Exception {
  const SshTransportFailure(this.code);
  final String code;
  @override
  String toString() => 'SshTransportFailure($code)';
}
