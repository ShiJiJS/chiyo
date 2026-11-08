import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late OnlineInformationRuntime runtime;
  late DateTime now;
  late String libraryPath;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(libraryPath, keys);
    runtime = await OnlineInformationRuntime.open(
      repository: repo,
      clock: () => now,
    );
  }

  Future<void> reopen() async {
    await runtime.close();
    await repo.close();
    await open();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chiyo-online-runtime-');
    keys = TestKeyStore();
    libraryPath = root.path;
    now = DateTime.utc(2026, 11, 8);
    await open();
  });
  tearDown(() async {
    await runtime.close();
    await repo.close();
    await root.delete(recursive: true);
  });
  Matcher failure([String? status]) => throwsA(
    isA<AccessFailure>().having(
      (e) => e.status,
      'status',
      status ?? isA<String>(),
    ),
  );
  Future<InformationItem> seed() => runtime.run(
    () => runtime.service.owner.createInformation('Synthetic', '', [
      const FieldInput('Selected', '', 'SELECTED'),
      const FieldInput('Other', '', 'OTHER'),
    ]),
  );
  InformationApprovalCommand command(
    String request,
    InformationItem item, {
    String operation = 'approval',
    InformationApprovalAction action = InformationApprovalAction.approve,
  }) => InformationApprovalCommand(
    operationId: operation,
    requestId: request,
    action: action,
    reviewToken: 'a' * 64,
    commandDigest:
        (action == InformationApprovalAction.approve ? 'b' : 'c') * 64,
    fields: action == InformationApprovalAction.approve
        ? [FieldRef(item.id, item.fields.first.id)]
        : [],
    itemVersions: action == InformationApprovalAction.approve
        ? {item.id: item.version}
        : {},
    lifetime: const Duration(minutes: 10),
  );
  Future<(OpenedSession, String, ClaimedGrant)> approved(
    InformationItem item, {
    String label = 'Synthetic chat',
    String operation = 'approval',
  }) async {
    final session = await runtime.run(
      () => runtime.service.agent.openSessionWithEndCapability(label),
    );
    final requested = await runtime.run(
      () => runtime.service.agent.request(
        session.sessionSecret,
        'Synthetic read',
        item.fields.map((f) => FieldRef(item.id, f.id)).toList(),
        operationId: 'request-once',
      ),
    );
    await runtime.run(
      () => runtime.service.owner.decideInformationRequest(
        command(requested.id, item, operation: operation),
      ),
    );
    final grant = await runtime.run(
      () => runtime.service.agent.claim(session.sessionSecret, requested.id),
    );
    return (session, requested.id, grant);
  }

  test(
    'ordinary encrypted reopen preserves pending and approved text, proofs and deadlines',
    () async {
      final item = await seed();
      final (session, request, grant) = await approved(item);
      final pendingSession = await runtime.run(
        () => runtime.service.agent.openSession('Pending chat'),
      );
      final pending = await runtime.run(
        () => runtime.service.agent.request(pendingSession, 'Wait for user', [
          FieldRef(item.id, item.fields.first.id),
        ]),
      );
      final deadline = grant.expiresAt;
      now = now.add(const Duration(minutes: 2));
      await reopen();
      final resumed = await runtime.run(
        () => runtime.service.agent.claim(session.sessionSecret, request),
      );
      expect(resumed.token, grant.token);
      expect(resumed.expiresAt, deadline);
      expect(
        await runtime.run(
          () => runtime.service.agent.read(
            grant.token,
            FieldRef(item.id, item.fields.first.id),
          ),
        ),
        'SELECTED',
      );
      await expectLater(
        runtime.run(
          () => runtime.service.agent.read(
            grant.token,
            FieldRef(item.id, item.fields.last.id),
          ),
        ),
        failure('unauthorized'),
      );
      expect(
        await runtime.run(
          () => runtime.service.agent.status(pendingSession, pending.id),
        ),
        containsPair('status', 'pending'),
      );
      expect(
        (await runtime.run(
          () => runtime.service.agent.request(
            session.sessionSecret,
            'Synthetic read',
            item.fields.map((f) => FieldRef(item.id, f.id)).toList(),
            operationId: 'request-once',
          ),
        )).id,
        request,
      );
      await runtime.run(
        () => runtime.service.owner.decideInformationRequest(
          command(request, item),
        ),
      );
      expect(repo.grantHistory, hasLength(1));
      now = deadline;
      await reopen();
      await expectLater(
        runtime.run(
          () => runtime.service.agent.read(
            grant.token,
            FieldRef(item.id, item.fields.first.id),
          ),
        ),
        failure('unauthorized'),
      );
      expect(repo.grantHistory.single.events.last.kind, GrantEventKind.expired);
    },
  );

  test('ended and revoked chats do not regain a grant on reopen', () async {
    final item = await seed();
    final (ended, endedId, endedGrant) = await approved(
      item,
      operation: 'approve-end',
    );
    final (revoked, revokedId, revokedGrant) = await approved(
      item,
      label: 'Revoke chat',
      operation: 'approve-revoke',
    );
    await runtime.run(
      () => runtime.service.agent.endSessionWithCapability(ended.endCapability),
    );
    await runtime.run(
      () => runtime.service.owner.decideInformationRequest(
        command(
          revokedId,
          item,
          operation: 'revoke',
          action: InformationApprovalAction.revoke,
        ),
      ),
    );
    await reopen();
    await expectLater(
      runtime.run(
        () => runtime.service.agent.claim(ended.sessionSecret, endedId),
      ),
      failure(),
    );
    await expectLater(
      runtime.run(
        () => runtime.service.agent.claim(revoked.sessionSecret, revokedId),
      ),
      failure(),
    );
    for (final grant in [endedGrant, revokedGrant]) {
      await expectLater(
        runtime.run(
          () => runtime.service.agent.read(
            grant.token,
            FieldRef(item.id, item.fields.first.id),
          ),
        ),
        failure('unauthorized'),
      );
    }
    expect(repo.grantHistory.every((g) => !g.active), isTrue);
    now = now.add(const Duration(days: 100));
    await reopen();
    await reopen(); // Retention removing old audit facts cannot revive or break startup.
    expect(repo.grantHistory, isEmpty);
    await expectLater(
      runtime.run(
        () => runtime.service.agent.read(
          endedGrant.token,
          FieldRef(item.id, item.fields.first.id),
        ),
      ),
      failure('unauthorized'),
    );
  });

  test('durable revocation wins over a pre-crash approved snapshot', () async {
    final item = await seed();
    final (session, request, grant) = await approved(item);
    final old = (await repo.openServerState()).payload['textRuntime'];
    await runtime.run(
      () => runtime.service.owner.decideInformationRequest(
        command(
          request,
          item,
          operation: 'revoke',
          action: InformationApprovalAction.revoke,
        ),
      ),
    );
    await runtime.close();
    final snapshot = await repo.openServerState();
    await repo.commitServerState(snapshot, {
      ...snapshot.payload,
      'textRuntime': old,
    });
    await repo.close();
    await open();
    await expectLater(
      runtime.run(
        () => runtime.service.agent.read(
          grant.token,
          FieldRef(item.id, item.fields.first.id),
        ),
      ),
      failure('unauthorized'),
    );
    await expectLater(
      runtime.run(
        () => runtime.service.agent.claim(session.sessionSecret, request),
      ),
      failure(),
    );
    expect(repo.grantHistory.single.active, isFalse);
  });

  test(
    'approval committed before private snapshot recovers original scope and deadline',
    () async {
      final item = await seed();
      final session = await runtime.run(
        () => runtime.service.agent.openSession('Interrupted approval'),
      );
      final request = await runtime.run(
        () => runtime.service.agent.request(
          session,
          'Synthetic read',
          item.fields.map((f) => FieldRef(item.id, f.id)).toList(),
        ),
      );
      final pendingSnapshot =
          (await repo.openServerState()).payload['textRuntime'];
      await runtime.run(
        () => runtime.service.owner.decideInformationRequest(
          command(request.id, item),
        ),
      );
      final originalDeadline = repo.grantHistory.single.expiresAt;
      await runtime.close();
      final snapshot = await repo.openServerState();
      await repo.commitServerState(snapshot, {
        ...snapshot.payload,
        'textRuntime': pendingSnapshot,
      });
      await repo.close();
      now = now.add(const Duration(minutes: 3));
      await open();
      final resumed = await runtime.run(
        () => runtime.service.agent.claim(session, request.id),
      );
      expect(resumed.expiresAt, originalDeadline);
      expect(
        await runtime.run(
          () => runtime.service.agent.read(
            resumed.token,
            FieldRef(item.id, item.fields.first.id),
          ),
        ),
        'SELECTED',
      );
      await expectLater(
        runtime.run(
          () => runtime.service.agent.read(
            resumed.token,
            FieldRef(item.id, item.fields.last.id),
          ),
        ),
        failure('unauthorized'),
      );
      expect(repo.grantHistory, hasLength(1));
    },
  );

  test(
    'portable restore discards active proofs and a stale runtime cannot write them back',
    () async {
      final item = await seed();
      final (session, request, grant) = await approved(item);
      final recovery = await enableTestBackups(repo.backups);
      await runtime.run(
        () => runtime.service.owner.exportLibrary(
          () => repo.backups.exportTo('${root.path}/backup'),
        ),
      );
      await runtime.close();
      await repo.close();
      libraryPath = '${root.path}/recipient';
      await open();
      final recipientSession = await runtime.run(
        () => runtime.service.agent.openSession('Recipient chat'),
      );
      await repo.backups.restoreFrom('${root.path}/backup', recovery);
      // Generation replacement while a host is still running must latch it shut.
      await expectLater(
        runtime.run(() => runtime.service.agent.catalog()),
        failure('library_changed'),
      );
      await expectLater(
        runtime.run(() => runtime.service.agent.catalog()),
        failure('service_unavailable'),
      );
      await runtime.close();
      expect(
        (await repo.openServerState()).payload.containsKey('textRuntime'),
        isFalse,
      );
      runtime = await OnlineInformationRuntime.open(
        repository: repo,
        clock: () => now,
      );
      await expectLater(
        runtime.run(
          () => runtime.service.agent.validateSession(recipientSession),
        ),
        failure('unauthorized'),
      );
      await expectLater(
        runtime.run(
          () => runtime.service.agent.claim(session.sessionSecret, request),
        ),
        failure('unauthorized'),
      );
      await expectLater(
        runtime.run(
          () => runtime.service.agent.read(
            grant.token,
            FieldRef(item.id, item.fields.first.id),
          ),
        ),
        failure('unauthorized'),
      );
      expect(runtime.service.owner.sessions, isEmpty);
    },
  );

  test(
    'malformed private state never silently starts an empty usable host',
    () async {
      await runtime.close();
      final snapshot = await repo.openServerState();
      await repo.commitServerState(snapshot, {
        ...snapshot.payload,
        'textRuntime': null,
      });
      await expectLater(
        OnlineInformationRuntime.open(repository: repo),
        throwsFormatException,
      );
      expect((await repo.openServerState()).payload['textRuntime'], isNull);
    },
  );
}
