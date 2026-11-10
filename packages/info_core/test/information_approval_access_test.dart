import 'dart:async';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class DecisionRepository extends MemoryInformationRepository {
  Completer<void>? entered, release;
  bool afterCommit = false, failWrite = false, failLookup = false;
  bool loseResponse = false;
  void pause({bool after = false}) {
    entered = Completer<void>();
    release = Completer<void>();
    afterCommit = after;
  }

  Future<void> gate(bool after) async {
    if (release != null && afterCommit == after) {
      entered!.complete();
      await release!.future;
      entered = null;
      release = null;
    }
  }

  @override
  Future<void> commitInformationApproval(
    InformationApprovalCommit change, {
    void Function()? validate,
  }) async {
    await gate(false);
    if (failWrite) throw StateError('synthetic storage failure');
    await super.commitInformationApproval(change, validate: validate);
    await gate(true);
    if (loseResponse) throw StateError('synthetic lost response');
  }

  @override
  Future<InformationApprovalReceipt?> informationApprovalReceipt(
    String id,
  ) async {
    if (failLookup) throw StateError('synthetic unavailable lookup');
    return super.informationApprovalReceipt(id);
  }
}

void main() {
  late DecisionRepository repo;
  late InformationService service;
  late DateTime now;
  late InformationItem item;
  late List<FieldRef> fields;
  late String session, request;
  InformationApprovalCommand command({
    String id = 'approve-1',
    InformationApprovalAction action = InformationApprovalAction.approve,
    String digest = 'b',
    List<FieldRef>? selected,
    int? version,
  }) => InformationApprovalCommand(
    operationId: id,
    requestId: request,
    action: action,
    reviewToken: 'a' * 64,
    commandDigest: digest * 64,
    fields: action == InformationApprovalAction.approve
        ? selected ?? [fields.first]
        : [],
    itemVersions: action == InformationApprovalAction.approve
        ? {item.id: version ?? item.version}
        : {},
  );
  Matcher failure(String code) =>
      throwsA(isA<AccessFailure>().having((e) => e.status, 'status', code));
  setUp(() async {
    now = DateTime.utc(2026, 10, 30);
    repo = DecisionRepository();
    service = InformationService(repository: repo, clock: () => now);
    item = await service.owner.createInformation('Synthetic', '', [
      const FieldInput('One', '', 'FIRST'),
      const FieldInput('Two', '', 'SECOND'),
    ]);
    fields = item.fields.map((f) => FieldRef(item.id, f.id)).toList();
    session = service.agent.openSession('synthetic chat');
    request = service.agent.request(session, 'partial read', fields).id;
    await service.owner.history();
  });
  tearDown(() async {
    repo.failLookup = false;
    if (!(repo.release?.isCompleted ?? true)) repo.release!.complete();
    await service.close();
  });

  test(
    'publish only after commit, read selected field, preserve stable corrections',
    () async {
      repo.pause();
      final result = service.owner.decideInformationRequest(command());
      await repo.entered!.future;
      expect(
        () => service.agent.claim(session, request),
        failure('decision_unknown'),
      );
      expect(
        () => service.owner.approve(request, fields),
        failure('decision_unknown'),
      );
      expect(() => service.owner.deny(request), failure('decision_unknown'));
      repo.release!.complete();
      final receipt = await result;
      final grant = service.agent.claim(session, request);
      expect(await service.agent.read(grant.token, fields.first), 'FIRST');
      await expectLater(
        service.agent.read(grant.token, fields.last),
        failure('unauthorized'),
      );
      await service.owner.correctValue(fields.first, 'CORRECTED');
      expect(await service.agent.read(grant.token, fields.first), 'CORRECTED');
      expect(
        (await service.owner.informationApprovalReceipt('approve-1'))!.toJson(),
        receipt.toJson(),
      );
      expect((await service.owner.history()).grants.single.active, isTrue);
    },
  );

  test(
    'deny, original result replay and conflicting operation identity',
    () async {
      final denied = command(action: InformationApprovalAction.deny);
      await service.owner.decideInformationRequest(denied);
      expect(service.agent.status(session, request)['status'], 'denied');
      expect(() => service.agent.claim(session, request), failure('denied'));
      await service.owner.decideInformationRequest(denied);
      await expectLater(
        service.owner.decideInformationRequest(command(digest: 'c')),
        failure('operation_conflict'),
      );
      expect(repo.grantHistory, isEmpty);
      expect(repo.requestHistory, hasLength(1));
    },
  );

  test(
    'revoke blocks old bearer while writing and replay cannot reactivate',
    () async {
      final approved = command();
      await service.owner.decideInformationRequest(approved);
      final grant = service.agent.claim(session, request);
      repo.pause();
      final result = service.owner.decideInformationRequest(
        command(id: 'revoke', action: InformationApprovalAction.revoke),
      );
      await repo.entered!.future;
      expect(() => service.owner.revoke(request), failure('decision_unknown'));
      await expectLater(
        service.agent.read(grant.token, fields.first),
        failure('unauthorized'),
      );
      repo.release!.complete();
      await result;
      await service.owner.decideInformationRequest(approved);
      await expectLater(
        service.agent.read(grant.token, fields.first),
        failure('unauthorized'),
      );
      expect(
        (await service.owner.history()).grants.single.events.last.kind,
        GrantEventKind.revoked,
      );
      expect(await repo.informationApprovalRevision(request), 2);
    },
  );

  test(
    'stale version and field outside requested scope never create a grant',
    () async {
      await expectLater(
        service.owner.decideInformationRequest(command(version: 9)),
        failure('scope_changed'),
      );
      request = service.agent.request(session, 'one only', [fields.first]).id;
      await expectLater(
        service.owner.decideInformationRequest(
          command(selected: [fields.last]),
        ),
        failure('invalid_scope'),
      );
      expect(repo.grantHistory, isEmpty);
    },
  );

  for (final after in [false, true]) {
    for (final event in ['end', 'cancel', 'expiry', 'close']) {
      test(
        '$event ${after ? 'after' : 'before'} commit cannot activate and close drains decision',
        () async {
          repo.pause(after: after);
          final result = service.owner.decideInformationRequest(command());
          // Observe the error immediately, before delivering the competing event.
          final outcome = result.then<Object>(
            (r) => r,
            onError: (Object e) => e,
          );
          await repo.entered!.future;
          Future<void>? closing;
          var closed = false;
          switch (event) {
            case 'end':
              service.agent.endSession(session);
            case 'cancel':
              service.agent.cancel(session, request);
            case 'expiry':
              now = now.add(const Duration(minutes: 121));
              service.owner.requests;
            case 'close':
              closing = service.close().then((_) => closed = true);
          }
          expect(closed, isFalse);
          repo.release!.complete();
          final answer = await outcome;
          if (after) {
            expect(answer, isA<InformationApprovalReceipt>());
          } else {
            expect(answer, isA<AccessFailure>());
          }
          if (closing != null) await closing;
          expect(repo.grantHistory.every((g) => !g.active), isTrue);
          expect(
            () => service.agent.claim(session, request),
            throwsA(isA<AccessFailure>()),
          );
          expect(
            await repo.informationApprovalReceipt('approve-1'),
            after ? isNotNull : isNull,
          );
          final history = repo.requestHistory.single;
          if (event == 'end') expect(history.sessionEnded, isTrue);
          if (event == 'close') expect(history.applicationClosed, isTrue);
          expect(history.state, isNot(AccessRequestState.approved));
        },
      );
    }
  }

  test(
    'confirmed rollback preserves pending request for an explicit retry',
    () async {
      repo.failWrite = true;
      await expectLater(
        service.owner.decideInformationRequest(command()),
        throwsStateError,
      );
      expect(service.agent.status(session, request)['status'], 'pending');
      expect(
        await service.owner.informationApprovalReceipt('approve-1'),
        isNull,
      );
      repo.failWrite = false;
      await service.owner.decideInformationRequest(command());
      expect(
        await service.agent.read(
          service.agent.claim(session, request).token,
          fields.first,
        ),
        'FIRST',
      );
    },
  );

  test(
    'unknown commit stays blocked; later original lookup never activates',
    () async {
      repo.pause(after: true);
      repo.loseResponse = true;
      final result = service.owner.decideInformationRequest(command());
      final checked = expectLater(result, failure('decision_unknown'));
      await repo.entered!.future;
      repo.failLookup = true;
      repo.release!.complete();
      await checked;
      expect(
        () => service.agent.claim(session, request),
        failure('decision_unknown'),
      );
      expect(
        () => service.owner.approve(request, fields),
        failure('decision_unknown'),
      );
      await expectLater(
        service.owner.informationApprovalReceipt('approve-1'),
        throwsStateError,
      );
      repo.failLookup = false;
      expect(
        await service.owner.informationApprovalReceipt('approve-1'),
        isNotNull,
      );
      expect(service.agent.status(session, request)['status'], 'revoked');
      expect(
        () => service.agent.claim(session, request),
        throwsA(isA<AccessFailure>()),
      );
      expect((await service.owner.history()).grants.single.active, isFalse);
    },
  );

  test(
    'lost commit response with available lookup records revocation, not a replay',
    () async {
      repo.loseResponse = true;
      await expectLater(
        service.owner.decideInformationRequest(command()),
        throwsStateError,
      );
      expect(
        (await service.owner.informationApprovalReceipt('approve-1'))!.action,
        InformationApprovalAction.approve,
      );
      expect(service.agent.status(session, request)['status'], 'revoked');
      await service.owner.decideInformationRequest(command());
      expect(
        () => service.agent.claim(session, request),
        throwsA(isA<AccessFailure>()),
      );
    },
  );

  test(
    'scope changes after durable commit but before response never publish a bearer',
    () async {
      repo.pause(after: true);
      final result = service.owner.decideInformationRequest(command());
      await repo.entered!.future;
      await repo.save(coreItemAfterExternalChange(item));
      repo.release!.complete();
      await result;
      expect(service.agent.status(session, request)['status'], 'revoked');
      expect(
        () => service.agent.claim(session, request),
        throwsA(isA<AccessFailure>()),
      );
      expect(repo.grantHistory.single.active, isFalse);
      expect(
        await service.owner.informationApprovalReceipt('approve-1'),
        isNotNull,
      );
    },
  );

  test(
    'closing an unresolved commit reports failure and can retry terminal audit',
    () async {
      repo.pause(after: true);
      repo.loseResponse = true;
      final result = service.owner.decideInformationRequest(command());
      final checked = expectLater(result, failure('decision_unknown'));
      await repo.entered!.future;
      repo.failLookup = true;
      repo.release!.complete();
      await checked;
      await expectLater(service.close(), throwsStateError);
      repo.failLookup = false;
      await service.close();
      expect(repo.grantHistory.single.active, isFalse);
      expect(repo.requestHistory.single.applicationClosed, isTrue);
    },
  );

  test(
    'concurrent end while revoking retains terminal state and old bearer remains unusable',
    () async {
      await service.owner.decideInformationRequest(command());
      final grant = service.agent.claim(session, request);
      repo.pause(after: true);
      final result = service.owner.decideInformationRequest(
        command(id: 'revoke-ended', action: InformationApprovalAction.revoke),
      );
      await repo.entered!.future;
      service.agent.endSession(session);
      repo.release!.complete();
      await result;
      await expectLater(
        service.agent.read(grant.token, fields.first),
        failure('unauthorized'),
      );
      expect(repo.requestHistory.single.sessionEnded, isTrue);
      expect(repo.grantHistory.single.active, isFalse);
    },
  );

  test(
    'reopen keeps original decision result but not the old session',
    () async {
      await service.owner.decideInformationRequest(command());
      final grant = service.agent.claim(session, request);
      await service.close();
      service = InformationService(repository: repo, clock: () => now);
      expect(
        await service.owner.informationApprovalReceipt('approve-1'),
        isNotNull,
      );
      expect(service.owner.sessions, isEmpty);
      await expectLater(
        service.agent.read(grant.token, fields.first),
        failure('unauthorized'),
      );
    },
  );
}

InformationItem coreItemAfterExternalChange(InformationItem item) =>
    InformationItem(
      item.id,
      item.name,
      item.description,
      item.version + 1,
      [item.fields.first.correctValue('CHANGED'), item.fields.last],
      createdAt: item.createdAt,
      modifiedAt: item.modifiedAt,
    );
