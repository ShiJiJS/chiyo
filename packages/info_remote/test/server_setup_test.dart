@TestOn('!windows')
library;

import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/server_setup.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_remote/connection_profile.dart';
import '../../../apps/server/test/support/tls_fixture.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_server/owner_authentication.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

void main() {
  test(
    'automatic TLS, first password, remembered login, save, restart and password replacement',
    () async {
      final directory = await Directory.systemTemp.createTemp('chiyo-setup-');
      addTearDown(() => directory.delete(recursive: true));
      final configFile = File('${directory.path}/server.json');
      await configFile.writeAsString(
        '{"autoInitialize":true,"dataDirectory":"data","secretsDirectory":"identity","tlsCertificate":"identity/server.pem","tlsPrivateKey":"identity/server.key","port":0}',
      );
      final config = await ServerConfiguration.read(configFile.path);
      final identityBefore = await File(
        '${directory.path}/identity/database.key',
      ).readAsBytes();
      final certificateBefore = await File(
        '${directory.path}/identity/server.pem',
      ).readAsBytes();
      var auth = await OwnerAuthentication.open(
        config.dataDirectory,
        config.ownerToken,
      );
      var repository = await EncryptedInformationRepository.openOnline(
        config.dataDirectory,
        MountedDatabaseKeyStore(config.databaseKeyFile),
      );
      var runtime = await OnlineInformationRuntime.open(repository: repository);
      var server = await OnlineServer.start(
        runtime: runtime,
        devices: AgentDeviceRegistry(repository),
        tls: config.tls,
        ownerToken: config.ownerToken,
        serverId: config.serverId,
        ownerAuthentication: auth,
      );
      addTearDown(() async {
        await server.close();
        await runtime.close();
        await repository.close();
      });
      final address = Uri.parse('https://127.0.0.1:${server.port}');
      final first = await ServerSetup.discover(address);
      expect(first.passwordConfigured, isFalse);
      expect(first.requiresOwnerToken, isFalse);
      final profile = await ServerSetup.authenticate(
        first,
        'synthetic-first-password',
        initialize: true,
      );
      final client = await connectOwnerProfile(profile);
      try {
        await client.save(
          'setup-save',
          InformationDraftInput(
            name: 'Synthetic setup item',
            description: '',
            fields: [
              InformationDraftField.text(
                'Value',
                '',
                'preserved after restart',
              ),
            ],
          ),
        );
      } finally {
        client.close();
      }
      final remembered = await ServerSetup.discover(address, previous: profile);
      expect(remembered.passwordConfigured, isTrue);
      expect(remembered.remembered, isNotNull);
      await expectLater(
        ServerSetup.discover(
          address,
          previous: ConnectionProfile(
            address: profile.address,
            token: profile.token,
            certificate: profile.certificate,
            serverId: 'another-server',
          ),
        ),
        throwsA(
          isA<RemoteFailure>().having((e) => e.code, 'code', 'server_changed'),
        ),
      );
      final otherTrust = Directory('${directory.path}/other-trust');
      await otherTrust.create();
      final otherTls = await createTlsFixture(otherTrust);
      await expectLater(
        ServerSetup.discover(
          address,
          previous: ConnectionProfile(
            address: profile.address,
            token: profile.token,
            certificate: await File(otherTls.ca).readAsString(),
            serverId: profile.serverId,
          ),
        ),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'untrusted_server',
          ),
        ),
      );
      await expectLater(
        ServerSetup.changePassword(
          profile,
          'wrong-password',
          'synthetic-second-password',
        ),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'invalid_password',
          ),
        ),
      );

      await expectLater(
        ServerSetup.authenticate(remembered, 'overwrite', initialize: true),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'already_initialized',
          ),
        ),
      );
      final changed = await ServerSetup.changePassword(
        profile,
        'synthetic-first-password',
        'synthetic-second-password',
      );
      await expectLater(
        connectOwnerProfile(profile),
        throwsA(
          isA<RemoteFailure>().having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
      await server.close();
      await runtime.close();
      await repository.close();
      final reopened = await ServerConfiguration.read(configFile.path);
      auth = await OwnerAuthentication.open(
        reopened.dataDirectory,
        reopened.ownerToken,
      );
      repository = await EncryptedInformationRepository.openOnline(
        reopened.dataDirectory,
        MountedDatabaseKeyStore(reopened.databaseKeyFile),
      );
      runtime = await OnlineInformationRuntime.open(repository: repository);
      server = await OnlineServer.start(
        runtime: runtime,
        devices: AgentDeviceRegistry(repository),
        tls: reopened.tls,
        ownerToken: reopened.ownerToken,
        serverId: reopened.serverId,
        ownerAuthentication: auth,
      );
      final nextAddress = Uri.parse('https://127.0.0.1:${server.port}');
      final newComputer = await ServerSetup.discover(nextAddress);
      expect(newComputer.passwordConfigured, isTrue);
      final loggedIn = await ServerSetup.authenticate(
        newComputer,
        'synthetic-second-password',
        initialize: false,
      );
      expect(loggedIn.token, changed.token);
      final finalClient = await connectOwnerProfile(loggedIn);
      try {
        expect(
          (await finalClient.information()).single.name,
          'Synthetic setup item',
        );
      } finally {
        finalClient.close();
      }
      expect(
        await File('${directory.path}/identity/database.key').readAsBytes(),
        identityBefore,
      );
      expect(
        await File('${directory.path}/identity/server.pem').readAsBytes(),
        certificateBefore,
      );
      await File('${directory.path}/identity/database.key').delete();
      await expectLater(
        ServerConfiguration.read(configFile.path),
        throwsA(isA<StorageFailure>()),
      );
      expect(
        await File('${directory.path}/identity/server.pem').readAsBytes(),
        certificateBefore,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
