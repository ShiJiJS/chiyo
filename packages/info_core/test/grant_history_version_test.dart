import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 30);
  GrantHistory grant({Map<String, int> versions = const {}}) => GrantHistory(
    id: 'grant',
    requestId: 'request',
    sessionId: 'session',
    chatLabel: 'synthetic',
    approvedAt: now,
    expiresAt: now.add(const Duration(hours: 1)),
    fields: const [RecordedField('item', 'field', 'Item', 'Field')],
    events: [GrantEvent(GrantEventKind.approved, now)],
    itemVersions: versions,
  );

  test(
    'approval provenance is immutable and retained by terminal and restored facts',
    () {
      final input = {'item': 3};
      final original = grant(versions: input);
      input['item'] = 99;
      expect(original.itemVersions, {'item': 3});
      expect(() => original.itemVersions['item'] = 4, throwsUnsupportedError);
      final ended = original.finish(GrantEventKind.revoked, now);
      final restored = ended.asRestored(now);
      expect(GrantHistory.fromJson(restored.toJson()).itemVersions, {
        'item': 3,
      });
      expect(restored.active, isFalse);
      expect(original.active, isTrue);
    },
  );

  test(
    'legacy serialization keeps provenance absent without guessing a version',
    () {
      final old = grant().toJson();
      expect(old.containsKey('itemVersions'), isFalse);
      expect(GrantHistory.fromJson(old).itemVersions, isEmpty);
      expect(GrantHistory.fromJson(old).asRestored(now).itemVersions, isEmpty);
    },
  );

  test(
    'provenance must cover exactly approved items with positive bounded versions',
    () {
      for (final versions in [
        {'other': 1},
        {'item': 1, 'other': 2},
        {'item': 0},
        {'item': -1},
        {'item': 9007199254740992},
      ]) {
        expect(() => grant(versions: versions), throwsFormatException);
      }
    },
  );

  test(
    'approval commit cannot associate a different version with its audit fact',
    () {
      final history = grant(versions: {'item': 3});
      expect(
        () => InformationApprovalCommit(
          receipt: InformationApprovalReceipt(
            operationId: 'approve',
            requestId: 'request',
            action: InformationApprovalAction.approve,
            reviewToken: 'a' * 64,
            commandDigest: 'b' * 64,
            revision: 1,
            recordedAt: now,
          ),
          request: RequestHistory(
            id: 'request',
            sessionId: 'session',
            chatLabel: 'synthetic',
            purpose: 'test',
            createdAt: now,
            requestExpiresAt: now.add(const Duration(minutes: 10)),
            recordedAt: now,
            state: AccessRequestState.approved,
            fields: history.fields,
            grantId: 'grant',
          ),
          grant: history,
          itemVersions: {'item': 4},
        ),
        throwsFormatException,
      );
    },
  );
}
