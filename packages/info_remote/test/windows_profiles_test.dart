@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:test/test.dart';

void main() {
  test(
    'owner and Agent identities reopen separately without plaintext secrets',
    () async {
      final root = await Directory.systemTemp.createTemp('连接 profile space ');
      addTearDown(() => root.delete(recursive: true));
      final folder = Directory('${root.path}/online');
      final ownerStore = PrivateConnectionProfileStore(folder.path);
      expect(await ownerStore.read(), isNull);
      const owner = ConnectionProfile(
        address: 'https://owner.invalid',
        token: 'synthetic-owner-token',
        serverId: 'synthetic-server-id',
      );
      final agent = AgentConnectionProfile(
        address: Uri.parse('https://agent.invalid'),
        deviceToken: '${'a' * 22}.${'b' * 43}',
        serverId: 'synthetic-server-id',
      );
      await ownerStore.save(owner);
      final agentFile = await agent.saveIn(folder);
      expect(
        (await PrivateConnectionProfileStore(folder.path).read())!.toJson(),
        owner.toJson(),
      );
      expect(
        (await AgentConnectionProfile.read(agentFile)).toPrivateJson(),
        agent.toPrivateJson(),
      );
      final ownerFile = File('${folder.path}/connection.json');
      expect(
        latin1.decode(await ownerFile.readAsBytes()),
        isNot(contains(owner.token)),
      );
      expect(
        latin1.decode(await agentFile.readAsBytes()),
        isNot(contains(agent.deviceToken)),
      );
      final second = ConnectionProfile(
        address: owner.address,
        token: 'updated-owner-token',
        serverId: owner.serverId,
      );
      await ownerStore.save(second);
      expect((await ownerStore.read())!.token, second.token);
      expect(
        (await AgentConnectionProfile.read(agentFile)).deviceToken,
        agent.deviceToken,
      );
      await agentFile.writeAsBytes([1, 2, 3]);
      await expectLater(
        AgentConnectionProfile.read(agentFile),
        throwsFormatException,
      );
      await ownerFile.writeAsBytes([1, 2, 3]);
      await expectLater(ownerStore.read(), throwsA(isA<RemoteFailure>()));
    },
  );
}
