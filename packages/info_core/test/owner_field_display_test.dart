import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  Future<InformationItem> item(InformationService service) =>
      service.owner.createInformation('Original server', '', const [
        FieldInput('Address', '', 'private-address-value'),
        FieldInput('Account', '', 'private-account-value'),
      ]);

  test(
    'owner snapshot retains immutable requested and supplemental names without old content',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final original = await item(service);
      final fields = original.fields
          .map((f) => FieldRef(original.id, f.id))
          .toList();
      final session = service.agent.openSession('Synthetic chat');
      final request = service.agent.request(session, 'Requested address', [
        fields.first,
      ]);
      service.owner.approve(request.id, [fields.last]);
      await service.owner.deleteInformation(original.id, original.version);
      final snapshot = service.owner.requests.single;
      expect(snapshot.recordedFields.map((f) => f.fieldName), [
        'Address',
        'Account',
      ]);
      expect(snapshot.recordedFields.map((f) => f.itemName).toSet(), {
        'Original server',
      });
      expect(() => snapshot.recordedFields.clear(), throwsUnsupportedError);
      final encoded = jsonEncode(
        snapshot.recordedFields.map((f) => f.toJson()).toList(),
      );
      expect(encoded, isNot(contains('private-address-value')));
      expect(encoded, isNot(contains('private-account-value')));
    },
  );

  test(
    'current scope projection follows exact field identities through partial deletion and restore',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final original = await item(service);
      final fields = original.fields
          .map((f) => FieldRef(original.id, f.id))
          .toList();
      final session = service.agent.openSession('Synthetic chat');
      final request = service.agent.request(session, 'Both fields', fields);
      service.owner.approve(request.id, fields);
      final claim = service.agent.claim(session, request.id);
      final record = (await service.owner.history()).grants.single;
      expect(service.owner.canReadGrantedField(record, fields.first), isTrue);
      expect(service.owner.canReadGrantedField(record, fields.last), isTrue);
      final entry = await service.owner.deleteInformation(
        original.id,
        original.version,
        fieldId: fields.first.fieldId,
      );
      expect(service.owner.canReadGrantedField(record, fields.first), isFalse);
      expect(service.owner.canReadGrantedField(record, fields.last), isTrue);
      final restored = await service.owner.restoreRecycled(entry.id);
      final newField = restored.fields.singleWhere((f) => f.name == 'Address');
      expect(newField.id, isNot(fields.first.fieldId));
      expect(service.owner.canReadGrantedField(record, fields.first), isFalse);
      expect(
        service.owner.canReadGrantedField(
          record,
          FieldRef(original.id, newField.id),
        ),
        isFalse,
      );
      expect(
        await service.agent.read(claim.token, fields.last),
        'private-account-value',
      );
      await expectLater(
        service.agent.read(claim.token, fields.first),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        service.agent.claim(session, request.id).expiresAt,
        claim.expiresAt,
      );
      expect(record.events.single.kind, GrantEventKind.approved);
    },
  );

  test(
    'scope projection rejects ended and archived facts and observes the service clock',
    () async {
      for (final mode in ['revoke', 'expire', 'end', 'archive']) {
        var now = DateTime.utc(2026, 10, 20);
        final service = InformationService(
          repository: MemoryInformationRepository(),
          clock: () => now,
        );
        try {
          final original = await item(service);
          final ref = FieldRef(original.id, original.fields.first.id);
          final session = service.agent.openSession('Synthetic chat');
          final request = service.agent.request(session, 'Address', [ref]);
          service.owner.approve(request.id, [
            ref,
          ], lifetime: const Duration(minutes: 1));
          final record = (await service.owner.history()).grants.single;
          expect(service.owner.canReadGrantedField(record, ref), isTrue);
          if (mode == 'revoke') {
            service.owner.revoke(request.id);
          } else if (mode == 'expire') {
            now = now.add(const Duration(minutes: 2));
          } else if (mode == 'end') {
            service.agent.endSession(session);
          }
          expect(
            service.owner.canReadGrantedField(
              mode == 'archive' ? record.asRestored(now) : record,
              ref,
            ),
            isFalse,
            reason: mode,
          );
        } finally {
          await service.close();
        }
      }
    },
  );
}
