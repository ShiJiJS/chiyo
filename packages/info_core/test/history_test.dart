import 'dart:async';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test('audit storage failure blocks delivery until pending facts can be saved', () async {
    final repository = FailingAuditRepository();
    final service = InformationService(repository: repository);
    final item = await service.owner.createInformation('Server', 'Description', [const FieldInput('Address','Host','private.invalid')]);
    final field = FieldRef(item.id, item.fields.single.id);
    final session = service.agent.openSession('chat');
    final request = service.agent.request(session,'Need address',[field]);
    service.owner.approve(request.id,[field]);
    final grant = service.agent.claim(session,request.id);
    await expectLater(service.agent.read(grant.token,field), throwsA(isA<AccessFailure>().having((e)=>e.status,'status','audit_unavailable')));
    repository.failing = false;
    await service.owner.retryAuditStorage();
    expect(await service.agent.read(grant.token,field),'private.invalid');
    final history = await service.owner.history();
    expect(history.grants,hasLength(1));
    expect(history.accesses,hasLength(2));
    await service.close();
  });
  test('unknown targets and forged credentials never enter owner records as raw input', () async {
    final service = InformationService.fictional();
    addTearDown(service.close);
    const privateInput = 'SENSITIVE-ATTACKER-TEXT';
    await expectLater(service.agent.read(privateInput, const FieldRef(privateInput, privateInput)), throwsA(isA<AccessFailure>()));
    final history = await service.owner.history();
    expect(history.accesses.single.grantId, isNull);
    expect(history.accesses.single.itemId, isNull);
    expect(history.accesses.single.fieldId, isNull);
    expect(history.toJson().toString(), isNot(contains(privateInput)));
  });

  test('history captures approved names, linked reads, and immediate revocation', () async {
    final service = InformationService.fictional();
    addTearDown(service.close);
    const field = FieldRef('demo-server', 'host');
    final session = service.agent.openSession('fictional chat');
    final request = service.agent.request(session, 'Need address', [field]);
    service.owner.approve(request.id, [field]);
    final grant = service.agent.claim(session, request.id);
    expect(await service.agent.read(grant.token, field), 'demo.example.invalid');
    service.owner.revoke(request.id);
    await expectLater(service.agent.read(grant.token, field), throwsA(isA<AccessFailure>()));
    final history = await service.owner.history();
    expect(history.grants.single.fields.single.itemName, 'Fictional demo server');
    expect(history.grants.single.fields.single.fieldName, 'Address');
    expect(history.grants.single.events.map((event) => event.kind.name), ['approved', 'revoked']);
    expect(history.accesses.map((record) => record.outcome.name), ['allowed', 'unauthorized']);
    expect(history.accesses.every((record) => record.grantId == history.grants.single.id), isTrue);
    final serialized = history.toJson().toString();
    for (final forbidden in [session, grant.token, 'demo.example.invalid']) {
      expect(serialized, isNot(contains(forbidden)));
    }
  });
}

class FailingAuditRepository extends MemoryInformationRepository {
  bool failing = true;
  @override
  Future<void> saveAccessRecord(AccessRecord record) async {
    if (failing) throw StateError('storage unavailable');
    return super.saveAccessRecord(record);
  }
}
