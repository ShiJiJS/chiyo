import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'an unpublished schema 8 fixture without audit tables upgrades without losing information',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'info-audit-backfill-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final keys = TestKeyStore();
      var repository = await EncryptedInformationRepository.open(
        folder.path,
        keys,
      );
      var service = InformationService(repository: repository);
      await service.owner.createInformation('Existing', 'Public', [
        const FieldInput('Host', 'Address', 'existing.invalid'),
      ]);
      await service.close();
      await repository.close();
      final fixture = sqlite3.open('${folder.path}/library.db');
      final hex = keys.key!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      fixture.execute('PRAGMA key = "x\'$hex\'"');
      fixture.execute('DROP TABLE grant_history');
      fixture.execute('DROP TABLE access_records');
      fixture.close();
      repository = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: repository);
      expect(service.owner.information.single.name, 'Existing');
      expect((await service.owner.history()).grants, isEmpty);
      await service.close();
      await repository.close();
    },
  );
  test(
    'encrypted history survives restart without reviving grants or copying field values',
    () async {
      final folder = await Directory.systemTemp.createTemp('info-history-');
      addTearDown(() => folder.delete(recursive: true));
      final keys = TestKeyStore();
      var repository = await EncryptedInformationRepository.open(
        folder.path,
        keys,
      );
      var service = InformationService(repository: repository);
      final item = await service.owner.createInformation(
        'Server',
        'Description',
        [const FieldInput('Address', 'Host', 'PRIVATE-HISTORY-CONTENT-72836')],
      );
      final field = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('Fictional chat');
      final request = service.agent.request(session, 'Need address', [field]);
      service.owner.approve(request.id, [field]);
      final grant = service.agent.claim(session, request.id);
      expect(
        await service.agent.read(grant.token, field),
        'PRIVATE-HISTORY-CONTENT-72836',
      );
      await service.owner.setAuditRetention(180);
      await service.close();
      await repository.close();
      repository = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: repository);
      final history = await service.owner.history();
      expect(service.owner.auditRetentionDays, 180);
      expect(
        history.grants.single.events.last.kind,
        GrantEventKind.applicationClosed,
      );
      expect(history.accesses.single.outcome, AccessOutcome.allowed);
      expect(
        history.toJson().toString(),
        isNot(contains('PRIVATE-HISTORY-CONTENT-72836')),
      );
      await expectLater(
        service.agent.read(grant.token, field),
        throwsA(isA<AccessFailure>()),
      );
      await service.close();
      await repository.close();
      for (final file in folder.listSync().whereType<File>()) {
        expect(
          String.fromCharCodes(await file.readAsBytes()),
          isNot(contains('PRIVATE-HISTORY-CONTENT-72836')),
        );
      }
    },
  );
}
