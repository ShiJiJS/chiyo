import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'owner saves fields; approved reads see corrections but not other fields',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final item = await service.owner.createInformation(
        'Test server',
        'Public description',
        [
          const FieldInput('Address', 'Host name', 'fictional-secret.invalid'),
          const FieldInput('Notes', 'Private text', 'fictional private note'),
        ],
      );
      final address = FieldRef(item.id, item.fields.first.id);
      final session = service.agent.openSession('test');
      final request = service.agent.request(session, 'connect', [address]);
      service.owner.approve(request.id, [address]);
      final grant = service.agent.claim(session, request.id);
      expect(
        service.agent.read(grant.token, address),
        'fictional-secret.invalid',
      );
      expect(
        service.agent.catalog().toString(),
        isNot(contains('fictional-secret')),
      );
      final revised = await service.owner.correctValue(
        address,
        'corrected.invalid',
      );
      expect(revised.id, item.id);
      expect(revised.version, 2);
      expect(revised.fields.first.version, 2);
      expect(service.agent.read(grant.token, address), 'corrected.invalid');
      expect(
        () => service.agent.read(
          grant.token,
          FieldRef(item.id, item.fields.last.id),
        ),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
}
