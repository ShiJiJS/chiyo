import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'actual access names survive retention of the associated grant',
    () async {
      final service = InformationService.fictional();
      const ref = FieldRef('demo-server', 'host');
      final session = service.agent.openSession('Read chat');
      final request = service.agent.request(session, 'Read address', [ref]);
      service.owner.approve(request.id, [ref]);
      final grant = service.agent.claim(session, request.id);
      await service.agent.read(grant.token, ref);
      await service.owner.updateCatalogMetadata(
        'demo-server',
        name: 'Renamed',
        description: '',
        fieldDescriptions: {'host': 'Host', 'username': 'Login'},
      );
      final record = (await service.owner.history()).accesses.single;
      expect(record.itemName, 'Fictional demo server');
      expect(record.fieldName, 'Address');
      await service.close();
    },
  );
  test(
    'first export requires a successful separate recovery key file',
    () async {
      final folder = await Directory.systemTemp.createTemp('backup-key-gate-');
      addTearDown(() => folder.delete(recursive: true));
      final repo = await EncryptedInformationRepository.open(
        '${folder.path}/library',
        TestKeyStore(),
      );
      addTearDown(repo.close);
      await repo.backups.enable();
      await expectLater(
        repo.backups.exportTo('${folder.path}/before.aim'),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'recovery_key_not_saved',
          ),
        ),
      );
      await expectLater(
        repo.backups.saveRecoveryKeyTo('${folder.path}/missing/key.txt'),
        throwsA(isA<StorageFailure>()),
      );
      await expectLater(
        repo.backups.exportTo('${folder.path}/still-before.aim'),
        throwsA(isA<StorageFailure>()),
      );
      await repo.backups.saveRecoveryKeyTo('${folder.path}/key.txt');
      await repo.backups.exportTo('${folder.path}/after.aim');
      expect(await File('${folder.path}/after.aim').exists(), isTrue);
    },
  );
  test(
    'format four restores request facts without any pending session',
    () async {
      final folder = await Directory.systemTemp.createTemp('request-backup-');
      addTearDown(() => folder.delete(recursive: true));
      final source = await EncryptedInformationRepository.open(
        '${folder.path}/source',
        TestKeyStore(),
      );
      final service = InformationService(repository: source);
      addTearDown(() async {
        await service.close();
        await source.close();
      });
      final item = await service.owner.createInformation('Server', 'Public', [
        const FieldInput('Host', 'Address', 'private.invalid'),
      ]);
      final session = service.agent.openSession('Backup chat');
      final request = service.agent.request(session, 'Deploy site', [
        FieldRef(item.id, item.fields.single.id),
      ]);
      service.owner.deny(request.id);
      await service.owner.setNotificationsEnabled(false);
      await service.owner.setRequestLifetime(const Duration(minutes: 15));
      await service.owner.setColorTheme(DesktopColorTheme.blue);
      final key = await source.backups.enable();
      await source.backups.saveRecoveryKeyTo('${folder.path}/key.txt');
      await service.owner.exportLibrary(
        () => source.backups.exportTo('${folder.path}/backup.aim'),
      );
      final recipient = await EncryptedInformationRepository.open(
        '${folder.path}/recipient',
        TestKeyStore(),
      );
      final target = InformationService(repository: recipient);
      addTearDown(() async {
        await target.close();
        await recipient.close();
      });
      final snapshot = await recipient.backups.inspect(
        '${folder.path}/backup.aim',
        key,
      );
      expect(snapshot.formatVersion, 6);
      await target.owner.restoreLibrary(
        () => recipient.backups.restore(snapshot),
      );
      final history = await target.owner.history();
      expect(history.requests.single.purpose, 'Deploy site');
      expect(history.requests.single.restoredAt, isNotNull);
      expect(target.owner.requests, isEmpty);
      expect(target.owner.notificationsEnabled, isFalse);
      expect(target.owner.requestLifetime, const Duration(minutes: 15));
      expect(target.owner.colorTheme, DesktopColorTheme.blue);
      expect(target.owner.organizationTasks, isEmpty);
      expect(
        () => target.agent.status(session, request.id),
        throwsA(isA<AccessFailure>()),
      );
      await target.close();
      await recipient.close();
      await service.close();
      await source.close();
    },
  );
  test(
    'terminal requests survive reopen as facts without pending capability',
    () async {
      final folder = await Directory.systemTemp.createTemp('request-facts-');
      addTearDown(() => folder.delete(recursive: true));
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(folder.path, keys);
      var service = InformationService(repository: repo);
      final item = await service.owner.createInformation(
        'Original server',
        'Public',
        [const FieldInput('Host', 'Address', 'PRIVATE-REQUEST-FACT-193')],
      );
      final field = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('Deployment chat');
      final denied = service.agent.request(session, 'Connect to service', [
        field,
      ]);
      service.owner.deny(denied.id);
      final cancelled = service.agent.request(session, 'Check configuration', [
        field,
      ]);
      service.agent.cancel(session, cancelled.id);
      final pending = service.agent.request(session, 'Wait for a decision', [
        field,
      ]);
      await service.owner.updateCatalogMetadata(
        item.id,
        name: 'Renamed server',
        description: 'Public',
        fieldDescriptions: {field.fieldId: 'Address'},
      );
      await service.owner.history();
      await service.owner.setNotificationsEnabled(false);
      await service.owner.setRequestLifetime(const Duration(hours: 1));
      await service.owner.setColorTheme(DesktopColorTheme.mono);
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: repo);
      expect(service.owner.notificationsEnabled, isFalse);
      expect(service.owner.requestLifetime, const Duration(hours: 1));
      expect(service.owner.colorTheme, DesktopColorTheme.mono);
      final history = await service.owner.history();
      expect(
        history.requests.map((r) => r.state),
        containsAll([AccessRequestState.denied, AccessRequestState.cancelled]),
      );
      expect(
        history.requests
            .firstWhere((r) => r.id == denied.id)
            .fields
            .single
            .itemName,
        'Original server',
      );
      expect(
        jsonEncode(history.toJson()),
        isNot(contains('PRIVATE-REQUEST-FACT-193')),
      );
      expect(jsonEncode(history.toJson()), isNot(contains(session)));
      expect(service.owner.requests, isEmpty);
      expect(
        () => service.agent.status(session, pending.id),
        throwsA(isA<AccessFailure>()),
      );
      await service.close();
      await repo.close();
    },
  );
}
