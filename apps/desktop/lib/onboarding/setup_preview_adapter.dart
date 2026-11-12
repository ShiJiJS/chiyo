import 'package:info_remote/owner_client.dart';
import '../workspace/workspace_sync.dart';
import 'setup_configuration.dart';

/// Only the separate preview entry imports this adapter. Production uses the
/// same widgets with ServerSetupController, never a simulated password store.
class SetupPreviewDraft extends ConnectionSetupModel implements WorkspaceSync {
  String? _configuredEndpoint;
  final _serverPasswords = <String, String>{};
  @override
  bool certificateRemembered = false;
  @override
  DateTime? updatedAt;
  String get endpoint => address.toString();
  @override
  bool get knownServer =>
      addressError == null && _configuredEndpoint == endpoint;
  @override
  bool get serverInitialized =>
      addressError == null && _serverPasswords.containsKey(endpoint);
  @override
  bool get enabled => saved == SetupStorageMode.server;
  @override
  bool get needsReview => false;
  @override
  Object? get failure => null;
  @override
  Future<void> checkServer() => synchronize();
  @override
  Future<void> useLocal() async {
    selected = saved = SetupStorageMode.local;
    changed();
  }

  void saveServer(String password) {
    _configuredEndpoint = endpoint;
    _serverPasswords[endpoint] = password;
    selected = saved = SetupStorageMode.server;
    certificateRemembered = true;
    changed();
  }

  bool passwordMatches(String value) => value == _serverPasswords[endpoint];
  @override
  Future<void> connectPassword(
    String password, {
    required bool initialize,
  }) async {
    if (initialize && serverInitialized) {
      throw const RemoteFailure('already_initialized');
    }
    if (!initialize && !passwordMatches(password)) {
      throw const RemoteFailure('invalid_password');
    }
    await synchronize();
    if (!closed) saveServer(password);
  }

  @override
  Future<void> changePassword(String current, String replacement) async {
    if (!passwordMatches(current)) {
      throw const RemoteFailure('invalid_password');
    }
    _serverPasswords[endpoint] = replacement;
    changed();
  }

  void forgetConnection() {
    _configuredEndpoint = null;
    changed();
  }

  @override
  Future<void> resumeServer() async {
    saved = selected = SetupStorageMode.server;
    changed();
  }

  @override
  Future<void> synchronize() async {
    if (busy) return;
    busy = true;
    changed();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (closed) return;
    busy = false;
    updatedAt = DateTime.now();
    changed();
  }
}
