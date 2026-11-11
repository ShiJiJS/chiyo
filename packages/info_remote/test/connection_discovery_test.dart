import 'dart:io';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_remote/private_connection_files.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Agent discovery reads only the selected role, rejects invalid pointers and never falls through an explicit missing configuration',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-discovery-');
      addTearDown(() => root.delete(recursive: true));
      final env = {'CHIYO_CONNECTION_DIRECTORY': root.path};
      await expectLater(
        discoverAgentConnection(environment: env),
        throwsA(isA<RemoteFailure>()),
      );
      const owner = ConnectionProfile(
        address: 'https://synthetic.invalid',
        token: 'SYNTHETIC_MANAGEMENT_TOKEN',
        serverId: 'synthetic-discovery-server',
      );
      final agent = AgentConnectionProfile(
        address: Uri.parse(owner.address),
        deviceToken: '${'a' * 22}.${'b' * 43}',
        serverId: owner.serverId,
      );
      final store = AutomaticConnectionStore(root.path);
      await store.publish(owner.toJson(), agent);
      final file = (await discoverAgentConnection(environment: env))!;
      expect(
        (await AgentConnectionProfile.read(file)).deviceToken,
        agent.deviceToken,
      );
      expect(
        String.fromCharCodes(await file.readAsBytes()),
        isNot(contains(owner.token)),
      );
      // Unreadable/malformed owner data cannot be consulted by Agent discovery.
      final ownerFile = File('${file.parent.parent.path}/connection.json');
      await ownerFile.writeAsString('not an owner profile');
      expect(
        (await discoverAgentConnection(environment: env))!.path,
        file.path,
      );
      await expectLater(
        PrivateConnectionProfileStore(root.path).read(),
        throwsA(isA<RemoteFailure>()),
      );
      final pointer = File('${root.path}/active.json');
      final original = (await PrivateConnectionFiles.read(pointer))!;
      for (final invalid in [
        {'version': 1, 'generation': '../foreign'},
        {'version': 1, 'generation': 'a' * 32, 'role': 'owner'},
        {'version': 1, 'generation': 'a' * 32},
      ]) {
        await PrivateConnectionFiles.write(pointer, invalid);
        await expectLater(
          discoverAgentConnection(environment: env),
          throwsA(isA<RemoteFailure>()),
        );
      }
      await PrivateConnectionFiles.write(pointer, original);
      if (!Platform.isWindows) {
        final generation = file.parent.parent;
        final retained = '${root.path}/retained';
        await generation.rename(retained);
        await Link(generation.path).create(retained);
        await expectLater(
          discoverAgentConnection(environment: env),
          throwsA(isA<RemoteFailure>()),
        );
        await Link(generation.path).delete();
        await Directory(retained).rename(generation.path);
      }
      expect(
        (await discoverAgentConnection(environment: env))!.path,
        file.path,
      );
    },
  );
}
