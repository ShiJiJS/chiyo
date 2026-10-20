import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'owner review revision rejects changed content without deciding the request',
    () async {
      final service = InformationService.fictional();
      const ref = FieldRef('demo-server', 'host');
      final before = service.owner.information.firstWhere(
        (i) => i.id == ref.itemId,
      );
      final field = before.fields.firstWhere((f) => f.id == ref.fieldId);
      final session = service.agent.openSession('review');
      final request = service.agent.request(
        session,
        'review displayed revision',
        [ref],
      );
      final after = await service.owner.editInformation(
        before.id,
        before.version,
        name: before.name,
        description: before.description,
        directoryId: before.directoryId,
        tagIds: before.tagIds,
        changes: [FieldChange.correct(field.id, 'changed.invalid')],
      );
      expect(
        () => service.owner.approve(
          request.id,
          [ref],
          reviewedVersions: {ref: field.version},
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'scope_changed',
          ),
        ),
      );
      expect(service.agent.status(session, request.id)['status'], 'pending');
      expect(
        () => service.owner.approve(request.id, [ref], reviewedVersions: {}),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'scope_changed',
          ),
        ),
      );
      final current = after.fields.firstWhere((f) => f.id == ref.fieldId);
      service.owner.approve(
        request.id,
        [ref],
        reviewedVersions: {ref: current.version},
      );
      expect(service.agent.claim(session, request.id).fields, [ref]);
      await service.close();
    },
  );
  test(
    'owner can inspect pending purpose and fixed approved scope without tokens',
    () {
      final service = InformationService.fictional();
      final secret = service.agent.openSession('chat-a');
      final request = service.agent.request(secret, 'Need address', [
        const FieldRef('demo-server', 'host'),
      ]);
      final pending = service.owner.requests.single;
      expect(pending.chatLabel, 'chat-a');
      expect(pending.purpose, 'Need address');
      expect(pending.state, AccessRequestState.pending);
      expect(pending.toString(), isNot(contains(secret)));
      service.owner.approve(request.id, [
        const FieldRef('demo-server', 'host'),
      ]);
      expect(service.owner.requests.single.state, AccessRequestState.approved);
      expect(service.owner.requests.single.approvedFields, [
        const FieldRef('demo-server', 'host'),
      ]);
    },
  );
}
