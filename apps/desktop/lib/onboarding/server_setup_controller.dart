import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_remote/server_setup.dart';
import 'setup_configuration.dart';

class ServerSetupController extends ConnectionSetupModel {
  ServerSetupController({
    required this.onConnected,
    required this.onLocal,
    this.onBusy,
    ConnectionProfile? previous,
    bool syncEnabled = false,
  }) : _profile = previous {
    saved = selected = syncEnabled
        ? SetupStorageMode.server
        : SetupStorageMode.local;
    if (previous != null) {
      final uri = Uri.parse(previous.address);
      host.text = uri.host;
      port.text = '${uri.port}';
    }
  }
  final Future<void> Function(ConnectionProfile, OwnerClient) onConnected;
  final Future<void> Function() onLocal;
  final void Function(bool)? onBusy;
  ConnectionProfile? _profile;
  ServerSetupProbe? _probe;
  bool _initialized = true;
  @override
  bool get serverInitialized => _initialized;
  @override
  bool get setupSupported => _probe?.supportsSetup ?? true;
  @override
  bool get knownServer =>
      addressError == null &&
      _profile != null &&
      Uri.parse(_profile!.address).origin == address.origin &&
      (_probe == null || _probe!.remembered != null);
  @override
  bool get certificateRemembered => _profile?.certificate.isNotEmpty == true;

  Future<T> _perform<T>(Future<T> Function() action) async {
    if (busy) throw const RemoteFailure('connection_busy');
    busy = true;
    onBusy?.call(true);
    changed();
    try {
      return await action();
    } finally {
      busy = false;
      onBusy?.call(false);
      changed();
    }
  }

  @override
  Future<void> checkServer() => _perform(() async {
    if (addressError != null) throw const RemoteFailure('invalid_connection');
    _probe = await ServerSetup.discover(address, previous: _profile);
    _initialized = _probe!.passwordConfigured;
  });

  @override
  Future<void> useLocal() => _perform(() async {
    await onLocal();
    saved = selected = SetupStorageMode.local;
  });

  Future<void> _apply(ConnectionProfile profile) async {
    final client = await connectOwnerProfile(profile);
    try {
      await onConnected(profile, client);
    } finally {
      client.close();
    }
    _profile = profile;
    saved = selected = SetupStorageMode.server;
  }

  @override
  Future<void> resumeServer() => _perform(() async {
    final profile = _probe?.remembered ?? _profile;
    if (profile == null) throw const RemoteFailure('unauthorized');
    await _apply(profile);
  });

  @override
  Future<void> connectPassword(
    String password, {
    required bool initialize,
  }) => _perform(() async {
    final probe = _probe;
    if (probe == null || probe.address.origin != address.origin) {
      throw const RemoteFailure('invalid_connection');
    }
    final profile = await ServerSetup.authenticate(
      probe,
      password,
      initialize: initialize,
    );
    _initialized = true;
    // Keep successfully acquired connection details if the later content sync
    // fails, without publishing a fake completed migration or losing drafts.
    _profile = profile;
    _probe = ServerSetupProbe(
      address: probe.address,
      certificate: probe.certificate,
      serverId: probe.serverId,
      passwordConfigured: true,
      requiresOwnerToken: false,
      remembered: profile,
    );
    await _apply(profile);
  });

  @override
  Future<void> changePassword(String current, String replacement) =>
      _perform(() async {
        final profile = _profile;
        if (profile == null) throw const RemoteFailure('unauthorized');
        final updated = await ServerSetup.changePassword(
          profile,
          current,
          replacement,
        );
        _profile = updated;
        _probe = null;
        await _apply(updated);
      });
}
