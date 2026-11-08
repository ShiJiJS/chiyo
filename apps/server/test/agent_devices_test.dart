import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

void main() {
  test(
    'device secrets remain distinct, idempotent and revoked after reopening',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-devices-');
      addTearDown(() => root.delete(recursive: true));
      await initializeServerSecrets('${root.path}/secrets');
      final keys = MountedDatabaseKeyStore('${root.path}/secrets/database.key');
      var repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
      );
      var devices = AgentDeviceRegistry(repo);
      late EnrolledAgentDevice a, b;
      try {
        a = await devices.enroll('enroll-a', 'Mac synthetic');
        final repeated = await devices.enroll('enroll-a', 'Mac synthetic');
        expect(repeated.bearer, a.bearer);
        b = await devices.enroll('enroll-b', 'Other synthetic');
        expect(b.bearer, isNot(a.bearer));
        expect((await devices.authenticate(a.bearer)).id, a.identity.id);
        expect((await devices.authenticate(b.bearer)).id, b.identity.id);
        await expectLater(
          devices.authenticate('${a.identity.id}.${b.secret}'),
          throwsA(isA<AccessFailure>()),
        );
        final owner = base64Url
            .encode(
              await File('${root.path}/secrets/owner.token').readAsBytes(),
            )
            .replaceAll('=', '');
        await expectLater(
          devices.authenticate(owner),
          throwsA(isA<AccessFailure>()),
        );
        await expectLater(
          devices.enroll('enroll-a', 'Different intent'),
          throwsA(isA<AccessFailure>()),
        );
        final metadata = jsonEncode(await devices.metadata());
        expect(metadata.contains(a.secret), isFalse);
        expect(metadata.contains(b.secret), isFalse);
      } finally {
        await repo.close();
      }
      repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
      );
      devices = AgentDeviceRegistry(repo);
      try {
        expect((await devices.authenticate(a.bearer)).id, a.identity.id);
        expect(
          (await devices.enroll('enroll-a', 'Mac synthetic')).bearer,
          a.bearer,
        );
        await devices.revoke('revoke-a', a.identity.id);
        await devices.revoke('revoke-a', a.identity.id);
        await expectLater(
          devices.revoke('revoke-a', b.identity.id),
          throwsA(isA<AccessFailure>()),
        );
      } finally {
        await repo.close();
      }
      repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
      );
      devices = AgentDeviceRegistry(repo);
      try {
        await expectLater(
          devices.authenticate(a.bearer),
          throwsA(isA<AccessFailure>()),
        );
        await expectLater(
          devices.enroll('enroll-a', 'Mac synthetic'),
          throwsA(isA<AccessFailure>()),
        );
        expect((await devices.authenticate(b.bearer)).id, b.identity.id);
        expect(
          (await devices.metadata()).singleWhere(
            (d) => d['id'] == a.identity.id,
          )['revoked'],
          true,
        );
      } finally {
        await repo.close();
      }
    },
  );

  test(
    'portable restore never carries source devices or revives recipient devices',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-device-restore-',
      );
      addTearDown(() => root.delete(recursive: true));
      await initializeServerSecrets('${root.path}/secrets');
      final keys = MountedDatabaseKeyStore('${root.path}/secrets/database.key');
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        keys,
      );
      final service = InformationService(repository: source);
      late EnrolledAgentDevice original;
      late String recoveryKey;
      try {
        original = await AgentDeviceRegistry(
          source,
        ).enroll('source-device', 'Source synthetic');
        await service.owner.createInformation('Synthetic record', '', [
          const FieldInput('Body', '', 'synthetic'),
        ]);
        recoveryKey = await source.backups.enable();
        await source.backups.saveRecoveryKeyTo('${root.path}/recovery');
        await source.backups.exportTo('${root.path}/backup');
      } finally {
        await service.close();
        await source.close();
      }
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        keys,
      );
      final devices = AgentDeviceRegistry(target);
      try {
        final previous = await devices.enroll(
          'target-device',
          'Recipient synthetic',
        );
        await target.backups.restoreFrom('${root.path}/backup', recoveryKey);
        await expectLater(
          devices.authenticate(original.bearer),
          throwsA(isA<AccessFailure>()),
        );
        await expectLater(
          devices.authenticate(previous.bearer),
          throwsA(isA<AccessFailure>()),
        );
        expect(await devices.metadata(), isEmpty);
        final replacement = await devices.enroll(
          'target-device',
          'Recipient synthetic',
        );
        expect(replacement.bearer, isNot(previous.bearer));
        expect(
          replacement.identity.generation,
          isNot(previous.identity.generation),
        );
      } finally {
        await target.close();
      }
    },
  );
}
