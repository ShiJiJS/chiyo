import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  final now = DateTime.utc(2026, 10, 30);
  Database inspect() {
    final db = sqlite3.open('${root.path}/library.db');
    final hex = keys.key!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      root.path,
      keys,
      clock: () => now,
    );
    service = InformationService(repository: repo, clock: () => now);
    await service.owner.history();
  }

  Future<void> close() async {
    await service.close();
    await repo.close();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('approval-operation-');
    keys = TestKeyStore();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  Future<InformationItem> seed() => service.owner.createInformation(
    '合成资料',
    '',
    [const FieldInput('字段', '', 'PRIVATE-FIELD-VALUE')],
  );
  InformationApprovalCommit decision(
    InformationItem item, {
    String operation = 'approve-1',
    String requestId = 'request-1',
    InformationApprovalAction action = InformationApprovalAction.approve,
    int revision = 1,
    int? version,
    GrantHistory? previous,
  }) {
    final fields = [
      RecordedField(
        item.id,
        item.fields.single.id,
        item.name,
        item.fields.single.name,
      ),
    ];
    final at = action == InformationApprovalAction.revoke
        ? now.add(const Duration(minutes: 1))
        : now;
    final grant = action == InformationApprovalAction.deny
        ? null
        : action == InformationApprovalAction.revoke
        ? previous!.finish(GrantEventKind.revoked, at)
        : GrantHistory(
            id: 'grant-$requestId',
            requestId: requestId,
            sessionId: 'public-session',
            chatLabel: '合成聊天',
            approvedAt: at,
            expiresAt: at.add(const Duration(minutes: 30)),
            fields: fields,
            events: [GrantEvent(GrantEventKind.approved, at)],
          );
    return InformationApprovalCommit(
      receipt: InformationApprovalReceipt(
        operationId: operation,
        requestId: requestId,
        action: action,
        reviewToken: 'a' * 64,
        commandDigest: 'b' * 64,
        revision: revision,
        recordedAt: at,
      ),
      request: RequestHistory(
        id: requestId,
        sessionId: 'public-session',
        chatLabel: '合成聊天',
        purpose: '合成验收',
        createdAt: now,
        requestExpiresAt: now.add(const Duration(minutes: 10)),
        recordedAt: at,
        state: switch (action) {
          InformationApprovalAction.approve => AccessRequestState.approved,
          InformationApprovalAction.deny => AccessRequestState.denied,
          InformationApprovalAction.revoke => AccessRequestState.revoked,
        },
        fields: fields,
        grantId: grant?.id,
      ),
      grant: grant,
      itemVersions: action == InformationApprovalAction.approve
          ? {item.id: version ?? item.version}
          : const {},
    );
  }

  Matcher fails(String code) =>
      throwsA(isA<AccessFailure>().having((e) => e.status, 'status', code));

  test(
    'decision, audit facts and content-free receipt commit together and survive reopen',
    () async {
      final item = await seed();
      final change = decision(item);
      await repo.commitInformationApproval(change);
      expect(
        (await repo.informationApprovalReceipt('approve-1'))!.toJson(),
        change.receipt.toJson(),
      );
      expect(repo.requestHistory.single.state, AccessRequestState.approved);
      expect(repo.grantHistory.single.id, change.grant!.id);
      final raw = inspect();
      try {
        final payload =
            raw
                    .select(
                      'SELECT payload FROM information_approval_operations',
                    )
                    .single['payload']
                as String;
        expect(payload, isNot(contains('PRIVATE-FIELD-VALUE')));
        expect(payload, isNot(contains('sessionSecret')));
        expect(payload, isNot(contains('token')));
      } finally {
        raw.close();
      }
      expect(
        service.owner.requests,
        isEmpty,
      ); // Storage facts never create a capability.
      await close();
      await open();
      expect(repo.items.any((i) => i.id == item.id), isTrue);
      expect(
        (await repo.informationApprovalReceipt('approve-1'))!.toJson(),
        change.receipt.toJson(),
      );
      expect(repo.grantHistory.single.active, isFalse);
      expect(service.owner.sessions, isEmpty);
    },
  );

  test(
    'duplicate operation, stale scope and conflicting decision cannot overwrite facts',
    () async {
      final item = await seed();
      await expectLater(
        repo.commitInformationApproval(decision(item, version: 9)),
        fails('scope_changed'),
      );
      expect(await repo.informationApprovalReceipt('approve-1'), isNull);
      expect(repo.requestHistory, isEmpty);
      final approved = decision(item);
      await repo.commitInformationApproval(approved);
      await expectLater(
        repo.commitInformationApproval(approved),
        fails('operation_conflict'),
      );
      await expectLater(
        repo.commitInformationApproval(
          decision(
            item,
            operation: 'deny-conflict',
            action: InformationApprovalAction.deny,
            revision: 2,
          ),
        ),
        fails('request_changed'),
      );
      expect(repo.requestHistory.single.state, AccessRequestState.approved);
      final revoked = decision(
        item,
        operation: 'revoke-1',
        action: InformationApprovalAction.revoke,
        revision: 2,
        previous: approved.grant,
      );
      await expectLater(
        repo.commitInformationApproval(
          InformationApprovalCommit(
            receipt: revoked.receipt,
            request: RequestHistory.fromJson({
              ...revoked.request.toJson(),
              'purpose': 'changed purpose',
            }),
            grant: revoked.grant,
          ),
        ),
        fails('request_changed'),
      );
      expect(await repo.informationApprovalReceipt('revoke-1'), isNull);
      expect(repo.grantHistory.single.active, isTrue);
      await repo.commitInformationApproval(revoked);
      expect(await repo.informationApprovalRevision('request-1'), 2);
      expect(repo.requestHistory.single.state, AccessRequestState.revoked);
      expect(repo.grantHistory.single.active, isFalse);
      expect(
        (await repo.informationApprovalReceipt('approve-1'))!.toJson(),
        approved.receipt.toJson(),
      );
    },
  );

  test(
    'late validation and SQL failure roll back all facts and in-memory caches',
    () async {
      final item = await seed();
      await expectLater(
        repo.commitInformationApproval(
          decision(item),
          validate: () => throw const AccessFailure('request_changed'),
        ),
        fails('request_changed'),
      );
      final db = inspect();
      try {
        db.execute(
          "CREATE TRIGGER fail_approval BEFORE INSERT ON information_approval_operations BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
        );
        await expectLater(
          repo.commitInformationApproval(decision(item)),
          throwsA(isA<StorageFailure>()),
        );
        for (final table in [
          'information_approval_operations',
          'request_history',
          'grant_history',
        ]) {
          expect(db.select('SELECT count(*) AS n FROM $table').single['n'], 0);
        }
        expect(repo.grantHistory, isEmpty);
        expect(repo.requestHistory, isEmpty);
        expect(await repo.informationApprovalReceipt('approve-1'), isNull);
      } finally {
        db.close();
      }
    },
  );

  test(
    'backup exports history but excludes receipts; restore invalidation is transactional',
    () async {
      final item = await seed();
      await repo.commitInformationApproval(decision(item));
      final recovery = await enableTestBackups(repo.backups);
      final path = '${root.path}/copy.aimbackup';
      await repo.backups.exportTo(path);
      final targetKeys = TestKeyStore();
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        targetKeys,
      );
      final db = sqlite3.open('${root.path}/target/library.db');
      db.execute(
        'PRAGMA key = "x\'${targetKeys.key!.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\'"',
      );
      final old = decision(item, operation: 'old-op').receipt;
      try {
        db.execute(
          'INSERT INTO information_approval_operations(operation_id,request_id,revision,payload) VALUES(?,?,?,?)',
          [
            old.operationId,
            old.requestId,
            old.revision,
            jsonEncode(old.toJson()),
          ],
        );
        expect(await target.backups.recipientEmpty(), isTrue);
        db.execute(
          "CREATE TRIGGER fail_restore BEFORE INSERT ON information_items BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
        );
        await expectLater(
          target.backups.restoreFrom(path, recovery),
          throwsA(isA<StorageFailure>()),
        );
        expect(
          (await target.informationApprovalReceipt('old-op'))!.toJson(),
          old.toJson(),
        );
        db.execute('DROP TRIGGER fail_restore');
        await target.backups.restoreFrom(path, recovery);
        await expectLater(
          target.informationApprovalReceipt('old-op'),
          fails('library_changed'),
        );
        expect(await target.informationApprovalReceipt('approve-1'), isNull);
        expect(target.grantHistory.single.active, isFalse);
        expect(target.items.single.fields.single.value, 'PRIVATE-FIELD-VALUE');
      } finally {
        db.close();
        await target.close();
      }
    },
  );

  test(
    'denial has an original receipt but no grant, and survives reopen',
    () async {
      final item = await seed();
      final change = decision(
        item,
        action: InformationApprovalAction.deny,
        operation: 'deny-1',
      );
      await repo.commitInformationApproval(change);
      expect(repo.grantHistory, isEmpty);
      await close();
      await open();
      expect(repo.requestHistory.single.state, AccessRequestState.denied);
      expect(repo.grantHistory, isEmpty);
      expect(
        (await repo.informationApprovalReceipt('deny-1'))!.action,
        InformationApprovalAction.deny,
      );
      expect(await repo.informationApprovalReceipt('not-committed'), isNull);
    },
  );

  test('receipt identity columns must match payload', () async {
    final item = await seed();
    await repo.commitInformationApproval(decision(item));
    final db = inspect();
    try {
      db.execute(
        "UPDATE information_approval_operations SET request_id='other-request'",
      );
      await expectLater(
        repo.informationApprovalReceipt('approve-1'),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'invalid_operation_receipt',
          ),
        ),
      );
      db.execute(
        "UPDATE information_approval_operations SET request_id='request-1', revision=2",
      );
      await expectLater(
        repo.informationApprovalReceipt('approve-1'),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'invalid_operation_receipt',
          ),
        ),
      );
    } finally {
      db.close();
    }
  });

  test('concurrent competing decisions leave one complete outcome', () async {
    final item = await seed();
    final outcomes = await Future.wait([
      for (final op in ['first', 'second'])
        repo
            .commitInformationApproval(
              decision(
                item,
                operation: op,
                action: InformationApprovalAction.deny,
              ),
            )
            .then(
              (_) => 'committed',
              onError: (Object e) => (e as AccessFailure).status,
            ),
    ]);
    expect(outcomes.where((o) => o == 'committed'), hasLength(1));
    expect(outcomes.where((o) => o == 'operation_conflict'), hasLength(1));
    expect(repo.requestHistory.single.state, AccessRequestState.denied);
    expect(repo.grantHistory, isEmpty);
    final receipts = await Future.wait([
      repo.informationApprovalReceipt('first'),
      repo.informationApprovalReceipt('second'),
    ]);
    expect(receipts.whereType<InformationApprovalReceipt>(), hasLength(1));
  });

  test(
    'real owner decisions persist with scoped reads, revocation and reopen',
    () async {
      final item = await service.owner.createInformation('Synthetic API', '', [
        const FieldInput('Selected', '', 'SELECTED'),
        const FieldInput('Unselected', '', 'UNSELECTED'),
      ]);
      final fields = item.fields.map((f) => FieldRef(item.id, f.id)).toList();
      final session = service.agent.openSession('synthetic decision');
      final request = service.agent
          .request(session, 'partial approval', fields)
          .id;
      InformationApprovalCommand command(
        String id,
        InformationApprovalAction action,
      ) => InformationApprovalCommand(
        operationId: id,
        requestId: request,
        action: action,
        reviewToken: 'a' * 64,
        commandDigest: (id == 'live-approve' ? 'b' : 'c') * 64,
        fields: action == InformationApprovalAction.approve
            ? [fields.first]
            : [],
        itemVersions: action == InformationApprovalAction.approve
            ? {item.id: item.version}
            : {},
      );
      await service.owner.decideInformationRequest(
        command('live-approve', InformationApprovalAction.approve),
      );
      final grant = service.agent.claim(session, request);
      expect(await service.agent.read(grant.token, fields.first), 'SELECTED');
      await expectLater(
        service.agent.read(grant.token, fields.last),
        fails('unauthorized'),
      );
      await service.owner.decideInformationRequest(
        command('live-revoke', InformationApprovalAction.revoke),
      );
      await expectLater(
        service.agent.read(grant.token, fields.first),
        fails('unauthorized'),
      );
      expect(repo.requestHistory.single.state, AccessRequestState.revoked);
      expect(repo.grantHistory.single.active, isFalse);
      await close();
      await open();
      expect(
        (await service.owner.informationApprovalReceipt(
          'live-approve',
        ))!.action,
        InformationApprovalAction.approve,
      );
      expect(
        (await service.owner.informationApprovalReceipt(
          'live-revoke',
        ))!.revision,
        2,
      );
      expect(service.owner.sessions, isEmpty);
      expect(repo.grantHistory.single.active, isFalse);
    },
  );

  for (final old in [34, 35]) {
    test(
      'format $old upgrades preserving data and portable boundary',
      () async {
        final item = await seed();
        await close();
        final db = inspect();
        try {
          db.execute('DROP TABLE information_approval_operations');
          db.execute('UPDATE library_format SET version=$old');
          db.execute('PRAGMA user_version=$old');
        } finally {
          db.close();
        }
        await open();
        expect(repo.items.single.id, item.id);
        final check = inspect();
        try {
          expect(
            check.select('PRAGMA user_version').single.values.single,
            old == 34 ? 36 : 37,
          );
        } finally {
          check.close();
        }
        await repo.commitInformationApproval(decision(item));
        expect(await repo.informationApprovalRevision('request-1'), 1);
      },
    );
  }
}
