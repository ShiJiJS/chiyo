import 'dart:async';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'owner confirms retention cleanup and changing names never rewrites approved facts',
    () async {
      var now = DateTime.utc(2026, 10, 1);
      final service = InformationService.fictional(clock: () => now);
      addTearDown(service.close);
      const field = FieldRef('demo-server', 'host');
      final session = service.agent.openSession('chat');
      final request = service.agent.request(session, 'Address', [field]);
      service.owner.approve(request.id, [field]);
      final grant = service.agent.claim(session, request.id);
      await service.agent.read(grant.token, field);
      await service.owner.updateCatalogMetadata(
        'demo-server',
        name: 'Renamed',
        description: 'Description',
        fieldDescriptions: {'host': 'Host', 'username': 'Login'},
      );
      expect(
        (await service.owner.history()).grants.single.fields.single.itemName,
        'Fictional demo server',
      );
      now = now.add(const Duration(days: 31));
      expect(service.owner.auditRetentionDays, 90);
      final preview = await service.owner.previewAuditRetention(30);
      expect(preview.grants, 1);
      expect(preview.accesses, 1);
      await expectLater(
        service.owner.setAuditRetention(30),
        throwsA(isA<AccessFailure>()),
      );
      expect((await service.owner.history()).grants, hasLength(1));
      await service.owner.setAuditRetention(30, confirmation: preview);
      expect((await service.owner.history()).grants, isEmpty);
      expect((await service.owner.history()).accesses, isEmpty);
      await service.owner.setAuditRetention(365);
      expect((await service.owner.history()).grants, isEmpty);
      await expectLater(
        service.agent.read(grant.token, field),
        throwsA(isA<AccessFailure>()),
      );
    },
  );

  test(
    'revoke during durable recording prevents both pending delivery and later reads',
    () async {
      final repository = DelayedAuditRepository();
      final service = InformationService(repository: repository);
      final item = await service.owner.createInformation(
        'Server',
        'Description',
        [const FieldInput('Address', 'Host', 'private.invalid')],
      );
      final field = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('chat');
      final request = service.agent.request(session, 'Address', [field]);
      service.owner.approve(request.id, [field]);
      final grant = service.agent.claim(session, request.id);
      var delivered = false;
      final reading = service.agent.read(grant.token, field).then((value) {
        delivered = true;
        return value;
      });
      final revokedRead = expectLater(reading, throwsA(isA<AccessFailure>()));
      await Future<void>.delayed(Duration.zero);
      expect(delivered, isFalse);
      service.owner.revoke(request.id);
      final denied = expectLater(service.agent.read(grant.token, field), throwsA(isA<AccessFailure>()));
      repository.ready.complete();
      await revokedRead;
      expect(delivered, isFalse);
      await denied;
      final history = await service.owner.history();
      expect(history.accesses.map((record) => record.outcome), [
        AccessOutcome.unauthorized,
        AccessOutcome.unauthorized,
      ]);
      await service.close();
    },
  );
  test(
    'audit storage failure blocks delivery until pending facts can be saved',
    () async {
      final repository = FailingAuditRepository();
      final service = InformationService(repository: repository);
      final item = await service.owner.createInformation(
        'Server',
        'Description',
        [const FieldInput('Address', 'Host', 'private.invalid')],
      );
      final field = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('chat');
      final request = service.agent.request(session, 'Need address', [field]);
      service.owner.approve(request.id, [field]);
      final grant = service.agent.claim(session, request.id);
      await expectLater(
        service.agent.read(grant.token, field),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'audit_unavailable',
          ),
        ),
      );
      repository.failing = false;
      await service.owner.retryAuditStorage();
      expect(await service.agent.read(grant.token, field), 'private.invalid');
      final history = await service.owner.history();
      expect(history.grants, hasLength(1));
      expect(history.accesses, hasLength(2));
      expect(history.accesses.first.outcome, AccessOutcome.auditUnavailable);
      await service.close();
    },
  );
  test(
    'unknown targets and forged credentials never enter owner records as raw input',
    () async {
      final service = InformationService.fictional();
      addTearDown(service.close);
      const privateInput = 'SENSITIVE-ATTACKER-TEXT';
      await expectLater(
        service.agent.read(
          privateInput,
          const FieldRef(privateInput, privateInput),
        ),
        throwsA(isA<AccessFailure>()),
      );
      final history = await service.owner.history();
      expect(history.accesses.single.grantId, isNull);
      expect(history.accesses.single.itemId, isNull);
      expect(history.accesses.single.fieldId, isNull);
      expect(history.toJson().toString(), isNot(contains(privateInput)));
    },
  );

  test(
    'history captures approved names, linked reads, and immediate revocation',
    () async {
      final service = InformationService.fictional();
      addTearDown(service.close);
      const field = FieldRef('demo-server', 'host');
      final session = service.agent.openSession('fictional chat');
      final request = service.agent.request(session, 'Need address', [field]);
      service.owner.approve(request.id, [field]);
      final grant = service.agent.claim(session, request.id);
      expect(
        await service.agent.read(grant.token, field),
        'demo.example.invalid',
      );
      service.owner.revoke(request.id);
      await expectLater(
        service.agent.read(grant.token, field),
        throwsA(isA<AccessFailure>()),
      );
      final history = await service.owner.history();
      expect(
        history.grants.single.fields.single.itemName,
        'Fictional demo server',
      );
      expect(history.grants.single.fields.single.fieldName, 'Address');
      expect(history.grants.single.events.map((event) => event.kind.name), [
        'approved',
        'revoked',
      ]);
      expect(history.accesses.map((record) => record.outcome.name), [
        'allowed',
        'unauthorized',
      ]);
      expect(
        history.accesses.every(
          (record) => record.grantId == history.grants.single.id,
        ),
        isTrue,
      );
      final serialized = history.toJson().toString();
      for (final forbidden in [session, grant.token, 'demo.example.invalid']) {
        expect(serialized, isNot(contains(forbidden)));
      }
    },
  );
}

class FailingAuditRepository extends MemoryInformationRepository {
  bool failing = true;
  @override
  Future<void> saveAccessRecord(AccessRecord record) async {
    if (failing) throw StateError('storage unavailable');
    return super.saveAccessRecord(record);
  }
}

class DelayedAuditRepository extends MemoryInformationRepository {
  final ready = Completer<void>();
  @override
  Future<void> saveGrantHistory(GrantHistory history) async {
    await ready.future;
    return super.saveGrantHistory(history);
  }
}
