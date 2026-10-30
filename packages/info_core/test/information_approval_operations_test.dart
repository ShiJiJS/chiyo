import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 30);
  InformationApprovalReceipt receipt({
    String id = 'owner-1',
    int revision = 1,
  }) => InformationApprovalReceipt(
    operationId: id,
    requestId: 'request-1',
    action: InformationApprovalAction.deny,
    reviewToken: 'a' * 64,
    commandDigest: 'b' * 64,
    revision: revision,
    recordedAt: now,
  );
  InformationApprovalCommit denied({String id = 'owner-1', int revision = 1}) =>
      InformationApprovalCommit(
        receipt: receipt(id: id, revision: revision),
        request: RequestHistory(
          id: 'request-1',
          sessionId: 'public-only',
          chatLabel: 'synthetic',
          purpose: 'test',
          createdAt: now,
          requestExpiresAt: now.add(const Duration(minutes: 1)),
          recordedAt: now,
          state: AccessRequestState.denied,
          fields: const [],
        ),
      );

  test(
    'receipt JSON has exact non-secret fields and validates operation identity',
    () {
      final json = receipt().toJson();
      expect(InformationApprovalReceipt.fromJson(json).toJson(), json);
      expect(json.keys.toSet(), {
        'operationId',
        'requestId',
        'action',
        'reviewToken',
        'commandDigest',
        'revision',
        'recordedAt',
      });
      expect(
        () => InformationApprovalReceipt.fromJson({
          ...json,
          'sessionSecret': 'forbidden',
        }),
        throwsFormatException,
      );
      expect(() => receipt(id: 'bad id'), throwsFormatException);
      expect(() => receipt(revision: 0), throwsFormatException);
    },
  );

  test(
    'memory implementation atomically validates before updating receipts and histories',
    () async {
      final repo = MemoryInformationRepository();
      await expectLater(
        repo.commitInformationApproval(
          denied(),
          validate: () => throw const AccessFailure('request_changed'),
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(await repo.informationApprovalReceipt('owner-1'), isNull);
      expect(repo.requestHistory, isEmpty);
      await repo.commitInformationApproval(denied());
      expect(repo.requestHistory.single.state, AccessRequestState.denied);
      expect(repo.grantHistory, isEmpty);
      await expectLater(
        repo.commitInformationApproval(denied()),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        repo.commitInformationApproval(denied(id: 'other', revision: 2)),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'request_changed',
          ),
        ),
      );
      expect(await repo.informationApprovalRevision('request-1'), 1);
    },
  );

  test(
    'concurrent duplicate owner operations cannot both commit in memory repository',
    () async {
      final repo = MemoryInformationRepository();
      final outcomes = await Future.wait([
        for (var i = 0; i < 2; i++)
          repo
              .commitInformationApproval(denied())
              .then(
                (_) => 'committed',
                onError: (Object e) => (e as AccessFailure).status,
              ),
      ]);
      expect(outcomes, ['committed', 'operation_conflict']);
      expect(repo.requestHistory, hasLength(1));
      expect(await repo.informationApprovalRevision('request-1'), 1);
    },
  );
}
