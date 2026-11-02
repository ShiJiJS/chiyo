import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

InformationAttachmentVersion version({bool purged = false}) =>
    InformationAttachmentVersion(
      reference: InformationAttachmentRef('resume', 2),
      originalName: '简历.pdf',
      mediaType: 'application/pdf',
      byteLength: 0,
      sha256: sha256.convert([]).toString(),
      createdAt: DateTime.utc(2026, 10, 19),
      retiredAt: purged ? DateTime.utc(2026, 10, 20) : null,
      purgedAt: purged ? DateTime.utc(2026, 11, 20) : null,
    );

void main() {
  test(
    'an owned series pins all versions, recovery snapshots keep its history, and purged bytes never reappear',
    () {
      final old = InformationAttachmentVersion(
        reference: InformationAttachmentRef('owned', 1),
        originalName: '原版.txt',
        mediaType: 'text/plain',
        byteLength: 1,
        sha256: 'a' * 64,
        createdAt: DateTime.utc(2025),
        retiredAt: DateTime.utc(2025, 2),
      );
      final current = InformationAttachmentVersion(
        reference: InformationAttachmentRef('owned', 2),
        originalName: '新版.txt',
        mediaType: 'text/plain',
        byteLength: 1,
        sha256: 'b' * 64,
        createdAt: DateTime.utc(2025, 2),
      );
      final gone = InformationAttachmentVersion(
        reference: InformationAttachmentRef('gone', 1),
        originalName: '已清理.txt',
        mediaType: 'text/plain',
        byteLength: 1,
        sha256: 'c' * 64,
        createdAt: DateTime.utc(2025),
        retiredAt: DateTime.utc(2025, 2),
        purgedAt: DateTime.utc(2025, 3),
      );
      final now = DateTime.utc(2027);
      final live = retainInformationAttachments(
        versions: [old, current, gone],
        current: {current.reference},
        retained: {},
        now: now,
      );
      expect(live.first.available, true);
      expect(live.last.available, false);
      final recycled = retainInformationAttachments(
        versions: live,
        current: {},
        retained: {current.reference},
        now: now,
      );
      expect(recycled.take(2).every((v) => v.available), true);
      final expired = retainInformationAttachments(
        versions: recycled,
        current: {},
        retained: {},
        now: now.add(const Duration(days: 31)),
      );
      expect(expired.every((v) => !v.available), true);
    },
  );
  test(
    'immutable version metadata round trips independently of a field version',
    () {
      final original = version();
      final parsed = InformationAttachmentVersion.fromPrivateJson(
        jsonDecode(jsonEncode(original.toPrivateJson()))
            as Map<String, dynamic>,
      );
      expect(parsed.reference, InformationAttachmentRef('resume', 2));
      expect(parsed.originalName, '简历.pdf');
      expect(parsed.available, isTrue);
      expect(parsed.toPrivateJson(), original.toPrivateJson());
      expect(parsed.toPrivateJson().containsKey('body'), isFalse);
      expect(parsed.toPrivateJson().containsKey('path'), isFalse);
    },
  );
  test('purged bytes are distinct from an available zero-byte file', () {
    final empty = version();
    final purged = version(purged: true);
    expect(empty.byteLength, purged.byteLength);
    expect(empty.available, isTrue);
    expect(
      InformationAttachmentVersion.fromPrivateJson(
        purged.toPrivateJson(),
      ).available,
      isFalse,
    );
  });
  test(
    'metadata rejects malformed types, unknown optional keys and noncanonical dates',
    () {
      final valid = version().toPrivateJson();
      final cases = [
        {...valid, 'attachmentVersion': 2.0},
        {...valid, 'createdAt': '2026-02-31T00:00:00.000Z'},
        {...valid, 'createdAt': '2026-10-19T00:00:00+00:00'},
        {...valid, 'createdAt': '2026-10-19T00:00:00Z'},
        {...valid, 'purgedAt': '2026-11-20T00:00:00.000Z'},
        {...valid, 'originalName': '../secret.pdf'},
        {...valid, 'mediaType': 'text/plain\n'},
        {...valid, 'sha256': '${'a' * 64}\n'},
        {...valid, 'byteLength': informationFileByteLimit + 1},
        {...valid, 'unknown': null}..remove('retiredAt'),
      ];
      for (final value in cases) {
        expect(
          () => InformationAttachmentVersion.fromPrivateJson(value),
          throwsA(
            isA<AccessFailure>().having(
              (e) => e.status,
              'status',
              'invalid_information_file',
            ),
          ),
          reason: value.keys.join(','),
        );
      }
    },
  );
}
