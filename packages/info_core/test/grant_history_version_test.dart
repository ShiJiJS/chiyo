import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 30);
  GrantHistory grant({
    Map<String, int> versions = const {},
    Map<String, String> snapshots = const {},
  }) => GrantHistory(
    id: 'grant',
    requestId: 'request',
    sessionId: 'session',
    chatLabel: 'synthetic',
    approvedAt: now,
    expiresAt: now.add(const Duration(hours: 1)),
    fields: const [RecordedField('item', 'field', 'Item', 'Field')],
    events: [GrantEvent(GrantEventKind.approved, now)],
    itemVersions: versions,
    itemSnapshots: snapshots,
  );

  test(
    'snapshot identities distinguish same-label branches and survive row ordering',
    () {
      InformationItem item(String value, {bool reverse = false}) {
        final fields = [
          InformationField('field', 'Field', '', value, 2),
          InformationField('other', 'Other', '', 'fixed', 1),
        ];
        return InformationItem(
          'item',
          'Item',
          '',
          2,
          reverse ? fields.reversed.toList() : fields,
          tagIds: reverse ? ['b', 'a'] : ['a', 'b'],
          createdAt: now,
          modifiedAt: now,
        );
      }

      final a = item('SYNTHETIC_A'), b = item('SYNTHETIC_B');
      final identity = informationSnapshotId(a);
      expect(identity, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(
        informationSnapshotId(item('SYNTHETIC_A', reverse: true)),
        identity,
      );
      expect(informationSnapshotId(b), isNot(identity));
      final original = grant(
        versions: {'item': 2},
        snapshots: {'item': identity},
      );
      final restored = original
          .finish(GrantEventKind.revoked, now)
          .asRestored(now);
      expect(GrantHistory.fromJson(restored.toJson()).itemSnapshots, {
        'item': identity,
      });
      expect(
        () => original.itemSnapshots['item'] = '0' * 64,
        throwsUnsupportedError,
      );
      expect(grant().toJson(), isNot(contains('itemSnapshots')));
    },
  );

  test(
    'snapshot identities must cover exactly the approved version identities',
    () {
      for (final snapshots in [
        {'other': 'a' * 64},
        {'item': 'not-an-identity'},
        {'item': 'A' * 64},
        {'item': 'a' * 64, 'other': 'b' * 64},
      ]) {
        expect(
          () => grant(versions: {'item': 2}, snapshots: snapshots),
          throwsFormatException,
        );
      }
      expect(() => grant(snapshots: {'item': 'a' * 64}), throwsFormatException);
    },
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
