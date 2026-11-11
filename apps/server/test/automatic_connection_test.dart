import 'dart:io';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/online_server.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

ConnectionProfile profile(DeviceCredentialFixture f) => ConnectionProfile(
  address: f.owner.address.toString(),
  token: f.token,
  serverId: f.owner.serverId,
  certificate: f.certificate,
);

Future<AgentConnectionProfile> discovered(
  PrivateConnectionProfileStore store,
) async => AgentConnectionProfile.read(
  (await discoverAgentConnection(
    environment: {'CHIYO_CONNECTION_DIRECTORY': store.directory},
  ))!,
);

void main() {
  test(
    'server changes publish matching roles, reuse per-server devices, and fail without replacing the live pair',
    () async {
      final first = await DeviceCredentialFixture.create();
      addTearDown(first.dispose);
      final second = await DeviceCredentialFixture.create();
      addTearDown(second.dispose);
      // Independent server identity; the two fixtures deliberately start with
      // the same synthetic ID otherwise.
      second.owner.close();
      await second.server.close();
      second.server = await OnlineServer.start(
        runtime: second.runtime,
        devices: AgentDeviceRegistry(second.repo),
        tls: second.tls,
        ownerToken: second.token,
        serverId: 'synthetic-second-automatic-server',
      );
      second.owner = await OwnerClient.connect(
        address: Uri.parse('https://127.0.0.1:${second.server.port}'),
        token: second.token,
        trust: second.trust,
      );
      final store = PrivateConnectionProfileStore(
        '${first.root.path}/configuration',
      );
      await store.saveConnected(profile(first), first.owner);
      final a = await discovered(store);
      expect(a.serverId, first.owner.serverId);
      expect((await store.read())!.token, first.token);
      final pointer = File('${store.directory}/active.json');
      final original = await pointer.readAsString();
      await first.reopen();
      await store.saveConnected(profile(first), first.owner);
      expect((await discovered(store)).deviceToken, a.deviceToken);
      expect(await pointer.readAsString(), original);
      expect(await AgentDeviceRegistry(first.repo).metadata(), hasLength(3));

      // Actual filesystem failure after successful remote enrollment, before
      // device-file publication. The first server remains fully usable.
      final blocked = Directory(
        '${store.directory}/devices/${second.owner.serverId}/agent-connection.json',
      );
      await blocked.create(recursive: true);
      await expectLater(
        store.saveConnected(profile(second), second.owner),
        throwsA(isA<Object>()),
      );
      expect(await pointer.readAsString(), original);
      expect((await store.read())!.serverId, a.serverId);
      expect((await discovered(store)).deviceToken, a.deviceToken);
      final stillLive = AgentConnection(await discovered(store));
      try {
        expect((await stillLive.call('/capabilities', {}))['status'], 'ok');
      } finally {
        stillLive.close();
      }
      expect(await AgentDeviceRegistry(second.repo).metadata(), hasLength(3));
      await blocked.delete();
      await store.saveConnected(profile(second), second.owner);
      final b = await discovered(store);
      expect(b.serverId, second.owner.serverId);
      expect(b.deviceToken, isNot(a.deviceToken));
      expect((await store.read())!.token, second.token);
      // Retry reconciles the original enrollment rather than creating a fourth.
      expect(await AgentDeviceRegistry(second.repo).metadata(), hasLength(3));
      final wrongServer = AgentConnection(
        AgentConnectionProfile(
          address: second.owner.address,
          certificate: second.certificate,
          serverId: second.owner.serverId,
          deviceToken: a.deviceToken,
        ),
      );
      try {
        expect(
          (await wrongServer.call('/capabilities', {}))['status'],
          'unauthorized',
        );
      } finally {
        wrongServer.close();
      }
      await store.saveConnected(profile(first), first.owner);
      expect((await discovered(store)).deviceToken, a.deviceToken);
      expect(await AgentDeviceRegistry(first.repo).metadata(), hasLength(3));

      // Revocation is definitive; a retry may enroll a replacement, but ordinary
      // restarts above never mint another device.
      await first.owner.request(
        'POST',
        '/v1/owner/devices/${a.deviceToken.split('.').first}/revoke',
        {'operationId': 'revoke-automatic-device'},
      );
      await store.saveConnected(profile(first), first.owner);
      final replacement = await discovered(store);
      expect(replacement.deviceToken, isNot(a.deviceToken));
      expect(await AgentDeviceRegistry(first.repo).metadata(), hasLength(4));
      await store.saveConnected(profile(first), first.owner);
      expect((await discovered(store)).deviceToken, replacement.deviceToken);
      expect(await AgentDeviceRegistry(first.repo).metadata(), hasLength(4));
    },
  );

  test(
    'unavailable device capability check preserves the published pair and does not enroll',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final store = PrivateConnectionProfileStore(
        '${f.root.path}/configuration',
      );
      await store.saveConnected(profile(f), f.owner);
      final original = await File(
        '${store.directory}/active.json',
      ).readAsString();
      final before = await AgentDeviceRegistry(f.repo).metadata();
      // Establish a valid owner first, then make the server unavailable.
      await f.server.close();
      await expectLater(
        store.saveConnected(profile(f), f.owner),
        throwsA(isA<RemoteFailure>()),
      );
      expect(
        await File('${store.directory}/active.json').readAsString(),
        original,
      );
      expect(await AgentDeviceRegistry(f.repo).metadata(), before);
      expect((await store.read())!.token, f.token);
    },
  );
}
