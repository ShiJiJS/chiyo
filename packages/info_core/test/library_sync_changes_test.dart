import 'dart:convert';

import 'package:info_core/library_sync_changes.dart';
import 'package:info_core/library_replication.dart';
import 'package:test/test.dart';

const library = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const replicaA = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const replicaB = 'cccccccccccccccccccccccccccccccc';
final item = LibrarySyncKey(LibrarySyncKind.information, 'item-1');
final related = LibrarySyncKey(LibrarySyncKind.information, 'related-2');

LibrarySyncBatch edit(
  String operation, {
  String replica = replicaA,
  int sequence = 1,
  String? base,
  Map<String, Object?>? content = const {'name': 'Synthetic information'},
}) => LibrarySyncBatch(
  libraryId: library,
  sourceReplicaId: replica,
  operationId: operation,
  sequence: sequence,
  edits: [LibrarySyncEdit(key: item, baseVersion: base, content: content)],
);

void main() {
  test('small baseline headers bind the complete chunked version map', () {
    final baseline = LibrarySyncBaseline(
      libraryId: library,
      sourceReplicaId: replicaA,
      snapshotId: '1' * 64,
      cursor: 7,
      versions: {item: '2' * 64},
      tombstones: {},
    );
    final header = LibrarySyncBaselineManifest.of(baseline);
    expect(
      header.byteLength,
      utf8.encode(jsonEncode(baseline.toJson())).length,
    );
    expect(header.matches(baseline), true);
    expect(
      LibrarySyncBaselineManifest.fromJson(
        Map<String, dynamic>.from(header.toJson()),
      ).matches(baseline),
      true,
    );
    final changed = LibrarySyncBaseline(
      libraryId: library,
      sourceReplicaId: replicaA,
      snapshotId: baseline.snapshotId,
      cursor: baseline.cursor,
      versions: {item: '3' * 64},
      tombstones: {},
    );
    expect(header.matches(changed), false);
    for (final patch in <Map<String, Object?>>[
      {'wireVersion': 3},
      {'byteLength': 0},
      {'byteLength': LibrarySyncBatch.maxBytes + 1},
      {'cursor': -1},
      {'cursor': 1.5},
      {'unknown': true},
    ]) {
      expect(
        () => LibrarySyncBaselineManifest.fromJson({
          ...header.toJson(),
          ...patch,
        }),
        throwsFormatException,
      );
    }
  });

  test(
    'feed summaries identify an exact delta without exposing its contents',
    () {
      final batch = edit(
        'feed-summary',
        content: {'value': 'SYNTHETIC_PRIVATE_VALUE'},
      );
      final summary = LibrarySyncChangeSummary(
        libraryId: library,
        sourceReplicaId: replicaA,
        operationId: batch.operationId,
        sequence: batch.sequence,
        digest: batch.digest,
        cursor: 9,
      );
      LibraryDeltaTransfer transfer({int sequence = 1, String? digest}) =>
          LibraryDeltaTransfer(
            archive: LibraryInitialTransfer(
              libraryId: library,
              snapshotId: digest ?? batch.digest,
              archiveDigest: '0' * 64,
              byteLength: 4096,
              contentFormat: 22,
            ),
            sourceReplicaId: replicaA,
            operationId: batch.operationId,
            sequence: sequence,
          );
      expect(summary.matches(transfer()), true);
      expect(summary.matches(transfer(sequence: 2)), false);
      expect(summary.matches(transfer(digest: 'f' * 64)), false);
      expect(
        jsonEncode(summary.toJson()),
        isNot(contains('SYNTHETIC_PRIVATE_VALUE')),
      );
      expect(
        LibrarySyncChangeSummary.fromJson(
          Map<String, dynamic>.from(summary.toJson()),
        ).matches(transfer()),
        true,
      );
      for (final patch in <Map<String, Object?>>[
        {'sequence': 0},
        {'cursor': 0},
        {'wireVersion': 1},
        {'content': batch.changes.single.content},
      ]) {
        expect(
          () => LibrarySyncChangeSummary.fromJson({
            ...summary.toJson(),
            ...patch,
          }),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'initial versions and delta archive descriptors reject tampering and unknown formats',
    () {
      final batch = edit('initial-versions');
      final baseline = LibrarySyncBaseline(
        libraryId: library,
        sourceReplicaId: replicaA,
        snapshotId: batch.digest,
        cursor: 7,
        versions: {item: batch.changes.single.version, related: '0' * 64},
        tombstones: {related},
      );
      final wire = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(baseline.toJson())) as Map,
      );
      expect(LibrarySyncBaseline.fromJson(wire).toJson(), baseline.toJson());
      final altered = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(wire)) as Map,
      );
      (altered['versions'] as List).first['version'] = 'f' * 64;
      expect(
        () => LibrarySyncBaseline.fromJson(altered),
        throwsFormatException,
      );
      expect(
        () => LibrarySyncBaseline.fromJson({...wire, 'wireVersion': 3}),
        throwsFormatException,
      );
      final archive = LibraryInitialTransfer(
        libraryId: library,
        snapshotId: batch.digest,
        archiveDigest: '0' * 64,
        byteLength: 4096,
        contentFormat: 22,
      );
      final transfer = LibraryDeltaTransfer(
        archive: archive,
        sourceReplicaId: replicaA,
        operationId: batch.operationId,
        sequence: batch.sequence,
      );
      expect(
        LibraryDeltaTransfer.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(jsonEncode(transfer.toJson())) as Map,
          ),
        ).toJson(),
        transfer.toJson(),
      );
      expect(
        () => LibraryDeltaTransfer.fromJson({
          ...transfer.toJson(),
          'wireVersion': 1,
        }),
        throwsFormatException,
      );
      expect(
        () => LibraryDeltaTransfer(
          archive: LibraryInitialTransfer(
            libraryId: library,
            snapshotId: batch.digest,
            archiveDigest: '0' * 64,
            byteLength: 4096,
            contentFormat: 8,
          ),
          sourceReplicaId: replicaA,
          operationId: batch.operationId,
          sequence: 1,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'receipt reports a retained conflict and rejects mismatched protocol fields',
    () {
      final batch = edit('receipt');
      final receipt = LibrarySyncReceipt(
        libraryId: library,
        receiverReplicaId: replicaB,
        sourceReplicaId: replicaA,
        operationId: batch.operationId,
        digest: batch.digest,
        cursor: 8,
        conflict: true,
      );
      final decoded = LibrarySyncReceipt.fromJson(
        jsonDecode(jsonEncode(receipt.toJson())),
      );
      expect(decoded.toJson(), receipt.toJson());
      expect(decoded.conflict, true);
      expect(
        () => LibrarySyncReceipt.fromJson({
          ...receipt.toJson(),
          'outcome': 'successful',
        }),
        throwsFormatException,
      );
      expect(
        () => LibrarySyncReceipt.fromJson({...receipt.toJson(), 'cursor': 0}),
        throwsFormatException,
      );
      expect(
        () => LibrarySyncReceipt.fromJson({
          ...receipt.toJson(),
          'wireVersion': 1,
        }),
        throwsFormatException,
      );
    },
  );

  test('wire survives a process roundtrip with stable versions and digest', () {
    final batch = edit('create-one');
    final restored = LibrarySyncBatch.decode(jsonEncode(batch.toJson()));
    expect(restored.digest, batch.digest);
    expect(restored.changes.single.version, batch.changes.single.version);
    expect(restored.changes.single.content, batch.changes.single.content);
    expect(
      restored.compare(targetLibraryId: library, currentVersions: {}).action,
      LibrarySyncAction.apply,
    );
    final reordered = edit(
      'canonical',
      content: {
        'second': 2,
        'first': {'b': 1, 'a': true},
      },
    );
    expect(
      edit(
        'canonical',
        content: {
          'first': {'a': true, 'b': 1},
          'second': 2,
        },
      ).digest,
      reordered.digest,
    );
  });

  test('A offline and B edited conflicts without timestamps or mutation', () {
    final first = edit('initial');
    final original = first.changes.single.version;
    final a = edit(
      'offline-A',
      sequence: 2,
      base: original,
      content: {'text': 'A'},
    );
    final b = edit(
      'online-B',
      replica: replicaB,
      sequence: 8,
      base: original,
      content: {'text': 'B'},
    );
    final head = {item: b.changes.single.version};
    final before = Map.of(head);
    final decision = a.compare(targetLibraryId: library, currentVersions: head);
    expect(decision.action, LibrarySyncAction.conflict);
    expect(decision.conflictingKeys, [item]);
    expect(head, before);
    expect(a.changes.single.content, {'text': 'A'});
    expect(b.changes.single.content, {'text': 'B'});
  });

  test(
    'one conflicting item holds a whole proposal, other batches can apply',
    () {
      final old = edit('old').changes.single.version;
      final other = edit('other-change', base: old).changes.single.version;
      final batch = LibrarySyncBatch(
        libraryId: library,
        sourceReplicaId: replicaA,
        operationId: 'whole-proposal',
        sequence: 2,
        edits: [
          LibrarySyncEdit(key: item, baseVersion: old, content: {'text': 'A'}),
          LibrarySyncEdit(
            key: related,
            baseVersion: null,
            content: {'ref': item.id},
          ),
        ],
      );
      final head = {item: other};
      expect(
        batch.compare(targetLibraryId: library, currentVersions: head).action,
        LibrarySyncAction.conflict,
      );
      expect(head.containsKey(related), false);
      final separate = LibrarySyncBatch(
        libraryId: library,
        sourceReplicaId: replicaB,
        operationId: 'independent',
        sequence: 9,
        edits: [
          LibrarySyncEdit(
            key: related,
            baseVersion: null,
            content: {'ok': true},
          ),
        ],
      );
      expect(
        separate
            .compare(targetLibraryId: library, currentVersions: head)
            .action,
        LibrarySyncAction.apply,
      );
    },
  );

  test(
    'a deletion keeps a version; an old device cannot recreate the item',
    () {
      final original = edit('original').changes.single.version;
      final deletion = edit('remove', base: original, content: null);
      expect(deletion.changes.single.deleted, true);
      expect(deletion.changes.single.version, isNot(original));
      final head = {item: deletion.changes.single.version};
      expect(
        edit(
          'stale-recreate',
          base: original,
        ).compare(targetLibraryId: library, currentVersions: head).action,
        LibrarySyncAction.conflict,
      );
      expect(
        edit(
          'explicit-restore',
          base: deletion.changes.single.version,
        ).compare(targetLibraryId: library, currentVersions: head).action,
        LibrarySyncAction.apply,
      );
    },
  );

  test('durable receipt reconciles a lost reply after later changes', () {
    final batch = edit('same-intent');
    expect(
      batch
          .compare(
            targetLibraryId: library,
            currentVersions: {
              item: edit('later-change').changes.single.version,
            },
            previousReceiptDigest: batch.digest,
          )
          .action,
      LibrarySyncAction.alreadyApplied,
    );
    expect(
      () => edit('same-intent', content: {'different': 'payload'}).compare(
        targetLibraryId: library,
        currentVersions: {},
        previousReceiptDigest: batch.digest,
      ),
      throwsFormatException,
    );
    expect(
      () => batch.compare(targetLibraryId: replicaB, currentVersions: {}),
      throwsFormatException,
    );
  });

  test(
    'wire rejects changed content, versions, duplicate keys and future formats',
    () {
      final batch = edit('integrity');
      Map<String, dynamic> wire() => jsonDecode(jsonEncode(batch.toJson()));
      final altered = wire();
      altered['changes'][0]['content']['name'] = 'tampered';
      expect(() => LibrarySyncBatch.fromJson(altered), throwsFormatException);
      final version = wire();
      version['changes'][0]['version'] = '0' * 64;
      expect(() => LibrarySyncBatch.fromJson(version), throwsFormatException);
      expect(
        () => LibrarySyncBatch.fromJson({...wire(), 'wireVersion': 3}),
        throwsFormatException,
      );
      expect(
        () => LibrarySyncBatch.fromJson({...wire(), 'unknown': true}),
        throwsFormatException,
      );
      expect(
        () => LibrarySyncBatch.decode('{"wireVersion":2,"wireVersion":2}'),
        throwsFormatException,
      );
      expect(
        () => LibrarySyncBatch(
          libraryId: library,
          sourceReplicaId: replicaA,
          operationId: 'duplicate',
          sequence: 1,
          edits: [
            LibrarySyncEdit(key: item, baseVersion: null, content: {}),
            LibrarySyncEdit(key: item, baseVersion: null, content: {}),
          ],
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'caller mutation and diagnostic printing cannot expose credential contents',
    () {
      final input = <String, Object?>{
        'nested': <Object?>['SYNTHETIC_PASSWORD'],
      };
      final credential = LibrarySyncKey(
        LibrarySyncKind.credential,
        'credential-1',
      );
      final batch = LibrarySyncBatch(
        libraryId: library,
        sourceReplicaId: replicaA,
        operationId: 'credential-update',
        sequence: 1,
        edits: [
          LibrarySyncEdit(key: credential, baseVersion: null, content: input),
        ],
      );
      (input['nested'] as List).clear();
      expect(batch.changes.single.content!['nested'], ['SYNTHETIC_PASSWORD']);
      expect(
        () => (batch.changes.single.content!['nested'] as List).clear(),
        throwsUnsupportedError,
      );
      expect(batch.toString(), isNot(contains('SYNTHETIC_PASSWORD')));
      expect(
        batch.changes.single.toString(),
        isNot(contains('SYNTHETIC_PASSWORD')),
      );
      expect(
        () => edit('invalid', content: {'number': double.nan}),
        throwsFormatException,
      );
      expect(() => edit('invalid', sequence: 0), throwsFormatException);
    },
  );
}
