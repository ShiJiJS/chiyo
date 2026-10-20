import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'long Unicode field names convert to valid bounded credential names',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'synthetic-unicode-migration-',
      );
      final repo = await EncryptedInformationRepository.open(
        root.path,
        TestKeyStore(),
      );
      final service = InformationService(repository: repo);
      addTearDown(() async {
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      final item = await service.owner.createInformation('Synthetic', '', [
        FieldInput('🔑' * 40, '', 'synthetic-only'),
      ]);
      final c = await service.owner.migrateFieldToCredential(
        FieldRef(item.id, item.fields.single.id),
        item.version,
      );
      expect(c.name.length, lessThanOrEqualTo(60));
      expect(c.name.runes.every((r) => r == 0x1f511), isTrue);
    },
  );
  test(
    'a durable conversion failure rolls back the credential and item and leaves the old grant usable',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'synthetic-field-migration-fault-',
      );
      addTearDown(() => root.delete(recursive: true));
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(root.path, keys);
      var service = InformationService(repository: repo);
      final item = await service.owner.createInformation('Synthetic', '', [
        const FieldInput('Token', '', 'synthetic-original'),
      ]);
      await service.close();
      await repo.close();
      final fixture = sqlite3.open('${root.path}/library.db');
      fixture.execute(
        'PRAGMA key = "x\'${keys.key!.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}\'"',
      );
      fixture.execute(
        "CREATE TRIGGER synthetic_migration_fault BEFORE INSERT ON information_revisions BEGIN SELECT RAISE(ABORT, 'synthetic fault'); END",
      );
      fixture.close();
      repo = await EncryptedInformationRepository.open(root.path, keys);
      service = InformationService(repository: repo);
      addTearDown(() async {
        await service.close();
        await repo.close();
      });
      final ref = FieldRef(item.id, item.fields.single.id),
          session = service.agent.openSession('Synthetic reader');
      final request = service.agent.request(session, 'Synthetic', [ref]);
      service.owner.approve(request.id, [ref]);
      final proof = service.agent.claim(session, request.id).token;
      await expectLater(
        service.owner.migrateFieldToCredential(ref, item.version),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'credential_migration_failed',
          ),
        ),
      );
      expect(service.owner.information.single.version, item.version);
      expect(service.owner.information.single.fields.single.id, ref.fieldId);
      expect(service.owner.credentials, isEmpty);
      expect(repo.credentialMaterials, isEmpty);
      expect(service.owner.informationRevisions, isEmpty);
      expect(service.owner.recycleEntries, isEmpty);
      expect(await service.agent.read(proof, ref), 'synthetic-original');
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(root.path, keys);
      service = InformationService(repository: repo);
      expect(
        service.owner.information.single.fields.single.value,
        'synthetic-original',
      );
      expect(service.owner.credentials, isEmpty);
      expect(repo.credentialMaterials, isEmpty);
    },
  );
  test(
    'explicit field conversion preserves item and other fields, closes old grants and restores old content only with a new field identity',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'synthetic-field-migration-',
      );
      addTearDown(() => root.delete(recursive: true));
      final repo = await EncryptedInformationRepository.open(
        root.path,
        TestKeyStore(),
      );
      addTearDown(repo.close);
      final service = InformationService(repository: repo);
      addTearDown(service.close);
      final item = await service.owner
          .createInformation('Synthetic server', '', [
            const FieldInput('Token', 'Test only', 'synthetic-original'),
            const FieldInput('Host', '', 'synthetic.invalid'),
          ]);
      final secret = FieldRef(item.id, item.fields.first.id),
          host = FieldRef(item.id, item.fields.last.id);
      final session = service.agent.openSession('Existing reader');
      final request = service.agent.request(session, 'Synthetic test', [
        secret,
        host,
      ]);
      service.owner.approve(request.id, [secret, host]);
      final proof = service.agent.claim(session, request.id).token;
      final updated = await service.owner.correctValue(
        secret,
        'synthetic-current',
      );
      final preview = service.owner.previewCredentialMigration(
        secret,
        updated.version,
      );
      expect(preview.activeGrantCount, 1);
      expect(preview.revisionCount, 1);
      final credential = await service.owner.migrateFieldToCredential(
        secret,
        updated.version,
      );
      expect(credential.form, CredentialForm.string);
      expect(credential.discoverable, isFalse);
      expect(credential.linkedItemIds, [item.id]);
      expect(
        repo.credentialMaterials.single.bytes,
        'synthetic-current'.codeUnits,
      );
      final current = service.owner.information.single;
      expect(current.id, item.id);
      expect(current.fields.single.id, host.fieldId);
      expect(await service.agent.read(proof, host), 'synthetic.invalid');
      await expectLater(
        service.agent.read(proof, secret),
        throwsA(isA<AccessFailure>()),
      );
      final recycled = service.owner.recycleEntries.single;
      await service.owner.restoreRecycled(recycled.id);
      final restored = service.owner.information.single.fields.singleWhere(
        (f) => f.name == 'Token',
      );
      expect(restored.id, isNot(secret.fieldId));
      expect(restored.value, 'synthetic-current');
      await expectLater(
        service.agent.read(proof, FieldRef(item.id, restored.id)),
        throwsA(isA<AccessFailure>()),
      );
      expect(await service.agent.read(proof, host), 'synthetic.invalid');
    },
  );
}
