import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_remote/owner_client.dart';
import 'workspace/workspace_source.dart';

/// The server owns its live requests and decisions. A local content replica
/// cannot stand in for that inbox. This connection never copies approvals or
/// retries mutations, and never falls back to the local owner on failure.
final class ServerRequestConnection implements OwnerTransport {
  ServerRequestConnection({
    required this.profile,
    required this.configuration,
    required this.changed,
    this.pollInterval = const Duration(seconds: 10),
  });
  final ConnectionProfile profile;
  final LocalLibraryConfiguration configuration;
  final void Function() changed;
  final Duration pollInterval;
  OwnerClient? _client;
  Future<OwnerClient>? _opening;
  Timer? _timer;
  bool _closed = false, _polling = false;
  String? _observation;

  Future<OwnerClient> _connect() {
    if (_closed) return Future.error(const RemoteFailure('connection_closed'));
    if (_client != null) return Future.value(_client);
    return _opening ??= (() async {
      final client = await OwnerClient.connect(
        address: Uri.parse(profile.address),
        token: profile.token,
        expectedServerId: profile.serverId,
        trust: profile.certificate.isEmpty
            ? null
            : (SecurityContext(
                withTrustedRoots: false,
              )..setTrustedCertificatesBytes(utf8.encode(profile.certificate))),
      );
      try {
        if (_closed) throw const RemoteFailure('connection_closed');
        // Keep the owner selection on this persistent local replica, while new
        // Agent chats target the server whose requests this mode displays.
        final connections = AutomaticConnectionStore(configuration.directory);
        await connections.connect(client, {
          ...profile.toJson(),
          'mode': 'local',
          'libraryId': configuration.libraryId,
        });
        if (_closed) throw const RemoteFailure('connection_closed');
        final current = await connections.agentFile();
        await (await AgentConnectionProfile.read(
          current!,
        )).saveIn(Directory(configuration.directory));
        _client = client;
        return client;
      } catch (_) {
        client.close();
        rethrow;
      }
    })().whenComplete(() => _opening = null);
  }

  Future<void> activate() async {
    _timer ??= Timer.periodic(pollInterval, (_) => unawaited(_poll()));
    await _poll();
  }

  Future<void> _poll() async {
    if (_closed || _polling) return;
    _polling = true;
    try {
      final result = await request('GET', '/v1/owner/updates');
      final observation = result['workspaceObservation'];
      if (!_closed && observation is String && _observation != observation) {
        _observation = observation;
        changed();
      }
    } on Object {
      // Normal inbox reads expose the original connection error. Offline must
      // not quietly replace a NAS inbox with this device's empty local inbox.
      if (!_closed) changed();
    } finally {
      _polling = false;
    }
  }

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Object? body,
  ]) async => (await _connect()).request(method, path, body);

  Future<WorkspaceSummary> summary(int localRecords) async {
    try {
      final value =
          (await request('GET', '/v1/owner/updates'))['summary'] as Map;
      return WorkspaceSummary(
        records: localRecords,
        pending: value['pending'] as int,
        proposals: value['proposals'] as int,
      );
    } on Object {
      throw const WorkspaceFailure('unavailable', '暂时无法读取服务器上的申请，请检查连接后重试。');
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    try {
      await _opening;
    } on Object {
      /* Nothing was published after close. */
    }
    _client?.close();
  }
}
