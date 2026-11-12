import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'agent_connection.dart';
import 'owner_client.dart';
import 'private_connection_files.dart';

String _identity() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

Future<String?> _deviceStatus(AgentConnectionProfile profile) async {
  final connection = AgentConnection(profile);
  try {
    return (await connection.call('/capabilities', {}))['status'] as String?;
  } finally {
    connection.close();
  }
}

/// One atomic pointer publishes a complete owner/Agent pair. The Agent reads
/// only the pointer and its role-specific file, never the management Token.
final class AutomaticConnectionStore {
  const AutomaticConnectionStore(this.directory);
  final String directory;

  Future<String?> _generation() async {
    final value = await PrivateConnectionFiles.read(
      File('$directory/active.json'),
    );
    if (value == null) return null;
    if (value.length != 2 ||
        value['version'] != 1 ||
        value['generation'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(value['generation'] as String)) {
      throw const RemoteFailure('invalid_profile');
    }
    final generation = value['generation'] as String;
    for (final path in [
      '$directory/connections',
      '$directory/connections/$generation',
    ]) {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const RemoteFailure('invalid_profile');
      }
    }
    return generation;
  }

  Future<Map<String, dynamic>?> readOwner() async {
    final generation = await _generation();
    if (generation == null) return null;
    final value = await PrivateConnectionFiles.read(
      File('$directory/connections/$generation/connection.json'),
    );
    if (value == null) throw const RemoteFailure('invalid_profile');
    return value;
  }

  Future<File?> agentFile() async {
    final generation = await _generation();
    if (generation == null) return null;
    return File(
      '$directory/connections/$generation/agent/agent-connection.json',
    ).absolute;
  }

  Future<void> publish(
    Map<String, Object?> owner,
    AgentConnectionProfile? agent,
  ) async {
    final generation = _identity();
    final folder = Directory('$directory/connections/$generation');
    var published = false;
    try {
      await PrivateConnectionFiles.write(
        File('${folder.path}/connection.json'),
        owner,
      );
      if (agent != null) await agent.saveIn(Directory('${folder.path}/agent'));
      // No active reader can see staged files until this single replacement.
      await PrivateConnectionFiles.write(File('$directory/active.json'), {
        'version': 1,
        'generation': generation,
      });
      published = true;
    } finally {
      if (!published && await folder.exists())
        await folder.delete(recursive: true);
    }
  }

  /// Called only after owner authentication, server identity and the initial
  /// workspace projection have passed. Enrollment retries retain their exact
  /// operation across crashes, including a lost successful response.
  Future<void> connect(OwnerClient client, Map<String, Object?> owner) async {
    final id = client.serverId;
    if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(id)) {
      throw const RemoteFailure('invalid_profile');
    }
    final cache = Directory('$directory/devices/$id');
    final cachedFile = File('${cache.path}/agent-connection.json');
    AgentConnectionProfile? profile;
    File? existing;
    if (await cachedFile.exists()) {
      existing = cachedFile;
    } else {
      final active = await agentFile();
      if (active != null && await active.exists()) {
        final candidate = await AgentConnectionProfile.read(active);
        if (!candidate.isLocal && candidate.serverId == id) existing = active;
      } else {
        final legacy = File('$directory/agent/agent-connection.json');
        if (await legacy.exists()) {
          final candidate = await AgentConnectionProfile.read(legacy);
          if (!candidate.isLocal && candidate.serverId == id) existing = legacy;
        }
      }
    }
    String? revokedDevice;
    if (existing != null) {
      final saved = await AgentConnectionProfile.read(existing);
      if (saved.serverId != id) throw const RemoteFailure('invalid_profile');
      profile = AgentConnectionProfile(
        address: client.address,
        deviceToken: saved.deviceToken,
        serverId: id,
        certificate: owner['certificate'] as String? ?? '',
      );
      final status = await _deviceStatus(profile);
      if (status == 'unauthorized') {
        revokedDevice = saved.deviceToken.split('.').first;
        profile = null;
      } else if (status != 'ok') {
        // A transient outage does not mint another device or replace config.
        throw const RemoteFailure('agent_connection_unavailable');
      }
    }
    if (profile == null) {
      final operationFile = File('${cache.path}/enrollment.json');
      var operation = await PrivateConnectionFiles.read(operationFile);
      if (operation == null || operation['replaces'] != revokedDevice) {
        operation = {
          'operationId': 'device-${_identity()}',
          'name': Platform.localHostname,
          if (revokedDevice != null) 'replaces': revokedDevice,
        };
        await PrivateConnectionFiles.write(operationFile, operation);
      }
      if (operation.length != (revokedDevice == null ? 2 : 3) ||
          operation['operationId'] is! String ||
          operation['name'] is! String) {
        throw const RemoteFailure('invalid_profile');
      }
      final enrolled = await client.request('POST', '/v1/owner/devices', {
        'operationId': operation['operationId'],
        'name': operation['name'],
      });
      profile = AgentConnectionProfile(
        address: client.address,
        deviceToken: enrolled['deviceToken'] as String,
        serverId: id,
        certificate: owner['certificate'] as String? ?? '',
      );
    }
    if (existing == null || revokedDevice != null) {
      if (await _deviceStatus(profile) != 'ok') {
        throw const RemoteFailure('agent_connection_unavailable');
      }
    }
    // A cache write may precede publication. It changes no effective target;
    // retries reuse this exact device if final publication fails.
    if (existing?.path != cachedFile.path ||
        jsonEncode(
              (await AgentConnectionProfile.read(cachedFile)).toPrivateJson(),
            ) !=
            jsonEncode(profile.toPrivateJson())) {
      await profile.saveIn(cache);
    }
    final previousFile = await agentFile();
    if (jsonEncode(await readOwner()) == jsonEncode(owner) &&
        previousFile != null &&
        await previousFile.exists() &&
        jsonEncode(
              (await AgentConnectionProfile.read(previousFile)).toPrivateJson(),
            ) ==
            jsonEncode(profile.toPrivateJson()))
      return;
    await publish(owner, profile);
  }
}

/// Explicit overrides isolate tests/named configurations. Otherwise inspect
/// only Chiyo's own known location; never scan owner files for credentials.
Future<File?> discoverAgentConnection({
  Map<String, String>? environment,
}) async {
  final roots = automaticConnectionDirectories(environment: environment);
  final override =
      (environment ?? Platform.environment)['CHIYO_CONNECTION_DIRECTORY'];
  for (final root in roots) {
    final active = await AutomaticConnectionStore(root).agentFile();
    if (active != null) {
      // Validate before returning: an invalid active target never falls back to
      // another server, a legacy port, or a management identity.
      await AgentConnectionProfile.read(active);
      return active;
    }
  }
  if (override != null) throw const RemoteFailure('connection_unavailable');
  return null;
}

/// Known configuration roots only; shared by automatic Agent connection and
/// the App-owned local execution locator. An explicit named root stays isolated.
List<String> automaticConnectionDirectories({
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final override = env['CHIYO_CONNECTION_DIRECTORY'];
  final List<String> roots;
  if (override != null) {
    if (!Directory(override).isAbsolute)
      throw const RemoteFailure('invalid_profile');
    roots = [override];
  } else if (Platform.isMacOS) {
    final home = env['HOME'];
    if (home == null || home.isEmpty) return const [];
    const container = '/Library/Containers/com.example.infoDesktop/Data';
    roots = home.endsWith(container)
        ? ['$home/Library/Application Support/Chiyo/online']
        : [
            '$home$container/Library/Application Support/Chiyo/online',
            '$home/Library/Application Support/Chiyo/online',
          ];
  } else if (Platform.isWindows) {
    final base = env['APPDATA'];
    if (base == null || base.isEmpty) return const [];
    roots = ['$base/Chiyo/online'];
  } else {
    return const [];
  }
  return roots;
}
