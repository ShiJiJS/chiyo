import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/settings_transport.dart';

import '../../apps/desktop/lib/workspace/remote_workspace_settings.dart';
import '../../apps/desktop/lib/workspace/workspace_source.dart';

/// An explicit NAS probe, never an automatically discovered test. The initial
/// owner profile arrives exclusively on stdin, and output contains no secrets.
/// Reopening needs only the current user's protected Windows profile directory.
Future<void> main(List<String> args) async {
  OwnerClient? client;
  RemoteWorkspaceSettings? settings;
  AgentConnection? connection;
  try {
    if (!Platform.isWindows ||
        args.length != 2 ||
        !{'--initialize', '--reopen', '--verify-failures'}.contains(args[0])) {
      throw const FormatException(
        'Expected mode and dedicated profile directory',
      );
    }
    final directory = Directory(args[1]).absolute;
    final store = PrivateConnectionProfileStore(directory.path);
    var profile = await store.read();
    if (args[0] == '--initialize') {
      final source = ConnectionProfile.fromJson(
        jsonDecode(await stdin.transform(utf8.decoder).join())
            as Map<String, dynamic>,
      );
      if (profile != null &&
          jsonEncode(profile.toJson()) != jsonEncode(source.toJson())) {
        throw StateError('Existing profile changed');
      }
      if (profile == null) await store.save(source);
      profile = await store.read();
    }
    if (profile == null) throw StateError('Missing original owner profile');
    final trust = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(profile.certificate));
    client = await OwnerClient.connect(
      address: Uri.parse(profile.address),
      token: profile.token,
      expectedServerId: profile.serverId,
      trust: trust,
    );
    final records = await client.information();
    settings = RemoteWorkspaceSettings(
      client,
      directory: '${directory.path}/device',
      changed: () {},
    );
    final preferences = await settings.read();
    final settingsJson = jsonEncode(preferencesToJson(preferences));
    await settings.dispose();
    settings = RemoteWorkspaceSettings(
      client,
      directory: '${directory.path}/device',
      changed: () {},
    );
    if (jsonEncode(preferencesToJson(await settings.read())) != settingsJson) {
      throw StateError('Settings did not reopen');
    }

    if (args[0] == '--verify-failures') {
      final settingsRoot =
          '${directory.path}/device/settings/${sha256.convert(utf8.encode(client.serverId))}';
      final state = File('$settingsRoot/state.json');
      final identity = File('$settingsRoot/identity.json');
      final originalState = state.readAsBytesSync();
      final originalIdentity = identity.readAsBytesSync();
      Future<void> refuse() async {
        try {
          await settings!.read();
        } on WorkspaceFailure catch (e) {
          if (e.code == 'settings_unavailable') return;
          rethrow;
        }
        throw StateError('Invalid original settings were accepted');
      }

      try {
        WindowsPrivateFiles.write(state, [1, 2, 3]);
        await refuse();
        if (jsonEncode(state.readAsBytesSync()) != '[1,2,3]') {
          throw StateError('Corrupt original settings were overwritten');
        }
        WindowsPrivateFiles.write(state, originalState);
        final saved = await state.rename('$settingsRoot/original-saved');
        try {
          await refuse();
          if (state.existsSync())
            throw StateError('Missing original settings were recreated');
        } finally {
          await saved.rename(state.path);
        }
        await writePrivateDeviceState(identity, {
          'format': 1,
          'serverId': 'wrong-server',
        });
        await refuse();
      } finally {
        WindowsPrivateFiles.write(state, originalState);
        WindowsPrivateFiles.write(identity, originalIdentity);
      }
    }

    final agentFile = File('${directory.path}/agent-connection.json');
    if (await FileSystemEntity.type(agentFile.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      if (args[0] != '--initialize')
        throw StateError('Missing original Agent profile');
      final intentFile = File('${directory.path}/device-registration.json');
      var intent = await readPrivateDeviceState(intentFile);
      if (intent == null) {
        intent = {
          'operationId':
              'windows-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}',
          'name': 'Windows ${Platform.localHostname}',
        };
        await writePrivateDeviceState(intentFile, intent);
      }
      final device = await client.request('POST', '/v1/owner/devices', intent);
      await AgentConnectionProfile(
        address: client.address,
        deviceToken: device['deviceToken'] as String,
        serverId: client.serverId,
        certificate: profile.certificate,
      ).saveIn(directory);
    }
    final agent = await AgentConnectionProfile.read(agentFile);
    if (agent.serverId != profile.serverId ||
        agent.deviceToken == profile.token) {
      throw StateError('Device binding mismatch');
    }
    connection = AgentConnection(agent);
    if ((await connection.call('/capabilities', {}))['status'] != 'ok') {
      throw StateError('Agent capabilities unavailable');
    }
    print(
      jsonEncode({
        'ownerProfileReopened': true,
        'agentProfileReopened': true,
        'separateDeviceIdentity': true,
        'settingsReopened': true,
        'nasAuthenticated': true,
        'informationCount': records.length,
        'agentCapabilitiesAvailable': true,
        if (args[0] == '--verify-failures') 'settingsFailureChecksPassed': true,
      }),
    );
  } catch (e) {
    print(
      jsonEncode({'verified': false, 'errorType': e.runtimeType.toString()}),
    );
    exitCode = 1;
  } finally {
    connection?.close();
    await settings?.dispose();
    client?.close();
  }
}
