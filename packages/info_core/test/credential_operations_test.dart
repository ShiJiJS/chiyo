import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'credential_use_test.dart' show tokenRequest, FailingRuntimeRepository;
import 'file_credential_use_test.dart' show fileSession, awsInput;

CredentialOperationInput operation(
  CredentialUseRequest request,
  String id, {
  List<String> argv = const ['api', 'user', '--method', 'GET'],
  Map<String, Object?>? env,
  String? receiver,
}) {
  final launch = Map<String, dynamic>.from(
    request.toRequestInputJson()['launch'] as Map,
  );
  launch['argv'] = argv;
  if (env != null) launch['env'] = env;
  if (receiver != null) launch['receiver'] = receiver;
  return CredentialOperationInput.fromJson({
    'protocolVersion': 2,
    'command': 'run-use',
    'requestId': request.id,
    'operationId': id,
    'launch': launch,
  });
}

Matcher failure(String code) =>
    throwsA(isA<CredentialUseFailure>().having((e) => e.code, 'code', code));

void main() {
  for (final invalidation in [
    'expired',
    'rotated',
    'disabled',
    'deleted',
    'ended',
  ]) {
    test(
      '$invalidation prevents new operations without reissuing old material',
      () async {
        var now = DateTime.utc(2026, 10, 19);
        final (s, session, r) = await tokenRequest(
          protocolVersion: 2,
          clock: () => now,
        );
        addTearDown(s.close);
        await s.owner.decideCredentialUse(r.id, approveCredential: true);
        final first = await s.agent.beginCredentialUseOperation(
          session,
          operation(r, 'before'),
        );
        final c = s.owner.credential(r.credentialId);
        switch (invalidation) {
          case 'expired':
            now = now.add(const Duration(minutes: 15));
          case 'rotated':
            await s.owner.rotateStringCredential(
              c.id,
              c.revision,
              'replacement-synthetic',
            );
          case 'disabled':
            await s.owner.setCredentialEnabled(c.id, c.revision, false);
          case 'deleted':
            await s.owner.deleteCredential(c.id, c.revision);
          case 'ended':
            s.agent.endSession(session);
        }
        await expectLater(
          s.agent.beginCredentialUseOperation(session, operation(r, 'after')),
          failure(switch (invalidation) {
            'expired' => 'grant_expired',
            'rotated' => 'credential_version_changed',
            'disabled' => 'credential_disabled',
            'deleted' => 'credential_deleted',
            _ => 'session_required',
          }),
        );
        if (invalidation != 'ended') {
          final duplicate = await s.agent.beginCredentialUseOperation(
            session,
            operation(r, 'before'),
          );
          expect(duplicate.execution.id, first.execution.id);
          expect(duplicate.material, isNull);
          expect(duplicate.grantState, isNot('available'));
        }
        expect(s.owner.credentialExecutions, hasLength(1));
      },
    );
  }

  for (final invalidation in ['expired', 'revoked', 'ended', 'rotated']) {
    test('worker admission rechecks $invalidation after material claim', () async {
      var now = DateTime.utc(2026, 10, 19);
      final (s, session, r) = await tokenRequest(
        protocolVersion: 2,
        clock: () => now,
      );
      addTearDown(s.close);
      final identity = CredentialProcessIdentity.capture(pid)!;
      addTearDown(identity.close);
      await s.owner.decideCredentialUse(r.id, approveCredential: true);
      final claim = await s.agent.beginCredentialUseOperation(
        session,
        operation(r, 'late-worker'),
        supervisorPid: pid,
        supervisorCreatedAt: identity.value,
      );
      switch (invalidation) {
        case 'expired':
          now = now.add(const Duration(minutes: 15));
        case 'revoked':
          await s.owner.revokeCredentialUse(r.id);
        case 'ended':
          s.agent.endSession(session);
        case 'rotated':
          final c = s.owner.credential(r.credentialId);
          await s.owner.rotateStringCredential(
            c.id,
            c.revision,
            'replacement-synthetic',
          );
      }
      // No worker/Job is launched in this rejection fixture. Authorization must
      // fail before the OS Job admission check, without publishing a GO permit.
      await expectLater(
        s.agent.registerCredentialWorker(
          claim.execution.id,
          claim.material!.executionCapability,
          pid,
          identity.value,
        ),
        failure(switch (invalidation) {
          'expired' => 'grant_expired',
          'rotated' => 'credential_version_changed',
          _ => 'grant_revoked',
        }),
      );
      expect(s.owner.credentialExecutions.single.workerPid, isNull);
    });
  }

  test(
    'combined v2 decision defaults ordinary fields to eight hours independently',
    () async {
      var now = DateTime.utc(2026, 10, 19);
      final (s, session, initial) = await tokenRequest(
        protocolVersion: 2,
        clock: () => now,
      );
      addTearDown(s.close);
      final item = await s.owner.createInformation('Synthetic server', '', [
        const FieldInput('Host', '', 'example.invalid'),
      ]);
      final field = FieldRef(item.id, item.fields.single.id);
      final r = await s.agent.requestCredentialUse(
        session,
        CredentialUseInput.fromJson({
          ...initial.toRequestInputJson(),
          'readFields': [field.toJson()],
        }),
      );
      await s.owner.decideCredentialUse(
        r.id,
        approveCredential: true,
        fields: [field],
      );
      final approved = s.owner.credentialUseRequests.firstWhere(
        (x) => x.id == r.id,
      );
      expect(
        approved.credentialExpiresAt,
        now.add(const Duration(minutes: 15)),
      );
      expect(approved.fieldExpiresAt, now.add(const Duration(hours: 8)));
      final grant = s.agent.claim(session, r.id);
      await s.agent.beginCredentialUseOperation(session, operation(r, 'first'));
      await s.owner.revokeCredentialUse(r.id);
      expect(await s.agent.read(grant.token, field), 'example.invalid');
      now = now.add(const Duration(hours: 1));
      expect(await s.agent.read(grant.token, field), 'example.invalid');
      now = now.add(const Duration(hours: 7));
      await expectLater(
        s.agent.read(grant.token, field),
        throwsA(isA<AccessFailure>()),
      );
    },
  );

  test(
    'v2 fields-only approval supports ordinary read durations, never credential use',
    () async {
      final (s, session, initial) = await tokenRequest(protocolVersion: 2);
      addTearDown(s.close);
      final item = await s.owner.createInformation('Synthetic server', '', [
        const FieldInput('Host', '', 'example.invalid'),
      ]);
      final field = FieldRef(item.id, item.fields.single.id);
      for (final minutes in [15, 30, 60, 480]) {
        final r = await s.agent.requestCredentialUse(
          session,
          CredentialUseInput.fromJson({
            ...initial.toRequestInputJson(),
            'readFields': [field.toJson()],
          }),
        );
        await s.owner.decideCredentialUse(
          r.id,
          approveCredential: false,
          fields: [field],
          fieldLifetime: Duration(minutes: minutes),
        );
        final grant = s.agent.claim(session, r.id);
        expect(await s.agent.read(grant.token, field), 'example.invalid');
        final saved = s.owner.credentialUseRequests.firstWhere(
          (x) => x.id == r.id,
        );
        expect(
          saved.fieldExpiresAt!.difference(saved.decidedAt!),
          Duration(minutes: minutes),
        );
        await expectLater(
          s.agent.beginCredentialUseOperation(
            session,
            operation(r, 'fields-$minutes'),
          ),
          failure('scope_not_approved'),
        );
      }
    },
  );

  test(
    'private claim roundtrip cannot change a frozen plan or attach material to an old execution',
    () async {
      final (s, session, r) = await tokenRequest(protocolVersion: 2);
      addTearDown(s.close);
      await s.owner.decideCredentialUse(r.id, approveCredential: true);
      final claim = await s.agent.beginCredentialUseOperation(
        session,
        operation(r, 'wire'),
      );
      Map<String, dynamic> wire() =>
          jsonDecode(jsonEncode(claim.toPrivateJson())) as Map<String, dynamic>;
      final parsed = CredentialOperationClaim.fromPrivateJson(wire());
      expect(parsed.execution.operationId, 'wire');
      expect(parsed.newlyClaimed, isTrue);
      final duplicateWithMaterial = wire()..['newlyClaimed'] = false;
      expect(
        () => CredentialOperationClaim.fromPrivateJson(duplicateWithMaterial),
        throwsA(isA<CredentialUseFailure>()),
      );
      final changedPlan = wire();
      ((changedPlan['material'] as Map)['approvedPlan'] as Map)['argv'] = [
        'repo',
        'list',
      ];
      expect(
        () => CredentialOperationClaim.fromPrivateJson(changedPlan),
        throwsA(isA<CredentialUseFailure>()),
      );
      final oldExecution = wire();
      (oldExecution['execution'] as Map)['executionState'] = 'exited';
      expect(
        () => CredentialOperationClaim.fromPrivateJson(oldExecution),
        throwsA(isA<CredentialUseFailure>()),
      );
    },
  );
  test(
    'each file operation owns its material lease and revocation does not erase earlier operations',
    () async {
      final (s, session, credential) = await fileSession();
      addTearDown(s.close);
      final r = await s.agent.requestCredentialUse(
        session,
        awsInput(credential, protocolVersion: 2),
      );
      await s.owner.decideCredentialUse(r.id, approveCredential: true);
      final claims = <CredentialOperationClaim>[];
      addTearDown(() {
        // This fixture never launches a process. Reclaim owned empty lease roots
        // even when an assertion fails before normal owner cleanup below.
        for (final c in claims) {
          final lease = c.material?.materialLease;
          if (lease != null && Directory(lease.path).existsSync()) {
            ManagedCredentialFiles.cleanup(lease);
          }
        }
      });
      for (final id in ['file-one', 'file-two']) {
        claims.add(
          await s.agent.beginCredentialUseOperation(
            session,
            operation(
              r,
              id,
              argv: ['sts', 'get-caller-identity', '--region', 'us-east-1'],
            ),
          ),
        );
      }
      final first = claims[0].material!.materialLease!;
      final second = claims[1].material!.materialLease!;
      expect(first.path, isNot(second.path));
      await s.owner.revokeCredentialUse(r.id);
      expect(
        Directory(first.path).existsSync() &&
            Directory(second.path).existsSync(),
        isTrue,
      );
      for (final claim in claims) {
        await s.agent.reportCredentialExecution(
          CredentialExecutionReport(
            executionId: claim.execution.id,
            executionCapability: claim.material!.executionCapability,
            state: 'start_failed',
            errorCode: 'process_start_failed',
            finishedAt: DateTime.now().toUtc(),
          ),
        );
        await s.owner.cleanupCredentialExecution(claim.execution.id);
      }
      expect(
        Directory(first.path).existsSync() ||
            Directory(second.path).existsSync(),
        isFalse,
      );
      expect(
        s.owner.credentialExecutions.every(
          (e) => e.operationPlan != null && e.operationId != null,
        ),
        isTrue,
      );
    },
  );

  test(
    'session ending during file preparation returns no material and keeps operation identity',
    () async {
      final repo = FailingRuntimeRepository();
      final (s, session, credential) = await fileSession(repository: repo);
      addTearDown(s.close);
      final r = await s.agent.requestCredentialUse(
        session,
        awsInput(credential, protocolVersion: 2),
      );
      await s.owner.decideCredentialUse(r.id, approveCredential: true);
      repo.afterConsumeCommit = () {
        repo.afterConsumeCommit = () => s.agent.endSession(session);
      };
      await expectLater(
        s.agent.beginCredentialUseOperation(
          session,
          operation(
            r,
            'late-file',
            argv: ['sts', 'get-caller-identity', '--region', 'us-east-1'],
          ),
        ),
        failure('grant_revoked'),
      );
      final record = s.owner.credentialExecutions.single;
      expect(record.state, 'prepare_failed');
      expect(record.operationId, 'late-file');
      expect(record.protocolVersion, 2);
      expect(record.cleanupState, 'complete');
      expect(Directory(record.materialLease!.path).existsSync(), isFalse);
    },
  );
  test(
    'one approval admits two immutable plans and keeps original deadline',
    () async {
      final (s, session, r) = await tokenRequest(protocolVersion: 2);
      addTearDown(s.close);
      await s.owner.decideCredentialUse(r.id, approveCredential: true);
      final expires = s.owner.credentialUseRequests.single.credentialExpiresAt;
      final first = await s.agent.beginCredentialUseOperation(
        session,
        operation(r, 'one'),
      );
      final second = await s.agent.beginCredentialUseOperation(
        session,
        operation(r, 'two', argv: ['repo', 'view', 'northstar/agent-skills']),
      );
      expect(first.newlyClaimed && second.newlyClaimed, isTrue);
      expect(first.execution.id, isNot(second.execution.id));
      expect(
        first.material!.approvedPlan.planHash,
        isNot(second.material!.approvedPlan.planHash),
      );
      expect(
        first.execution.operationPlan!.planHash,
        first.material!.approvedPlan.planHash,
      );
      expect(s.owner.credentialExecutions, hasLength(2));
      expect(s.owner.credentialUseRequests.single.attemptConsumed, isFalse);
      expect(s.owner.credentialUseRequests.single.credentialExpiresAt, expires);
      expect(
        s.owner.credentialGrantState(s.owner.credentialUseRequests.single),
        'available',
      );
      expect(
        jsonEncode(first.toPublicJson()),
        isNot(contains('synthetic-token')),
      );
      expect(first.toPublicJson(), isNot(contains('material')));
    },
  );

  test('simultaneous retries issue material exactly once', () async {
    final (s, session, r) = await tokenRequest(protocolVersion: 2);
    addTearDown(s.close);
    await s.owner.decideCredentialUse(r.id, approveCredential: true);
    final input = operation(r, 'same');
    final claims = await Future.wait(
      List.generate(
        5,
        (_) => s.agent.beginCredentialUseOperation(session, input),
      ),
    );
    expect(claims.where((c) => c.newlyClaimed), hasLength(1));
    expect(claims.map((c) => c.execution.id).toSet(), hasLength(1));
    expect(s.owner.credentialExecutions, hasLength(1));
    final duplicate = claims.firstWhere((c) => !c.newlyClaimed);
    expect(duplicate.toPrivateJson(), isNot(contains('material')));
  });

  test('same operation with another command or grant conflicts', () async {
    final (s, session, r) = await tokenRequest(protocolVersion: 2);
    addTearDown(s.close);
    await s.owner.decideCredentialUse(r.id, approveCredential: true);
    await s.agent.beginCredentialUseOperation(session, operation(r, 'same'));
    await expectLater(
      s.agent.beginCredentialUseOperation(
        session,
        operation(r, 'same', argv: ['repo', 'list']),
      ),
      failure('operation_conflict'),
    );
    final other = await s.agent.requestCredentialUse(
      session,
      CredentialUseInput.fromJson(r.toRequestInputJson()),
    );
    await s.owner.decideCredentialUse(other.id, approveCredential: true);
    await expectLater(
      s.agent.beginCredentialUseOperation(session, operation(other, 'same')),
      failure('operation_conflict'),
    );
    expect(s.owner.credentialExecutions, hasLength(1));
  });

  test('map key order does not create a second operation', () async {
    final (s, session, r) = await tokenRequest(protocolVersion: 2);
    addTearDown(s.close);
    await s.owner.decideCredentialUse(r.id, approveCredential: true);
    final a = operation(
      r,
      'ordered',
      env: {
        'GH_TOKEN': {'secret': r.alias},
        'GH_HOST': 'github.com',
      },
    );
    final b = operation(
      r,
      'ordered',
      env: {
        'GH_HOST': 'github.com',
        'GH_TOKEN': {'secret': r.alias},
      },
    );
    expect(a.fingerprint, b.fingerprint);
    final first = await s.agent.beginCredentialUseOperation(session, a);
    final repeated = await s.agent.beginCredentialUseOperation(session, b);
    expect(repeated.execution.id, first.execution.id);
    expect(repeated.newlyClaimed, isFalse);
  });

  test(
    'a failed attempt retains its facts, and a fresh operation needs no approval',
    () async {
      final (s, session, r) = await tokenRequest(protocolVersion: 2);
      addTearDown(s.close);
      await s.owner.decideCredentialUse(r.id, approveCredential: true);
      final input = operation(r, 'failed');
      final first = await s.agent.beginCredentialUseOperation(session, input);
      await s.agent.reportCredentialExecution(
        CredentialExecutionReport(
          executionId: first.execution.id,
          executionCapability: first.material!.executionCapability,
          state: 'start_failed',
          errorCode: 'process_start_failed',
          finishedAt: DateTime.now().toUtc(),
        ),
      );
      final repeated = await s.agent.beginCredentialUseOperation(
        session,
        input,
      );
      expect(repeated.execution.state, 'start_failed');
      expect(repeated.execution.operationId, 'failed');
      expect(repeated.execution.operationPlan, isNotNull);
      expect(repeated.material, isNull);
      expect(
        (await s.agent.beginCredentialUseOperation(
          session,
          operation(r, 'next'),
        )).newlyClaimed,
        isTrue,
      );
      expect(
        s.owner.credentialGrantState(s.owner.credentialUseRequests.single),
        'available',
      );
    },
  );

  test(
    'audit failure gives no material and does not reserve a phantom operation',
    () async {
      final repo = FailingRuntimeRepository();
      final (s, session, r) = await tokenRequest(
        protocolVersion: 2,
        repository: repo,
      );
      addTearDown(s.close);
      await s.owner.decideCredentialUse(r.id, approveCredential: true);
      repo.fail = true;
      await expectLater(
        s.agent.beginCredentialUseOperation(session, operation(r, 'audit')),
        failure('audit_unavailable'),
      );
      expect(s.owner.credentialExecutions, isEmpty);
      repo.fail = false;
      expect(
        (await s.agent.beginCredentialUseOperation(
          session,
          operation(r, 'audit'),
        )).newlyClaimed,
        isTrue,
      );
    },
  );

  test(
    'another session, unapproved receiver and revoked grant cannot obtain new material',
    () async {
      final (s, session, r) = await tokenRequest(protocolVersion: 2);
      addTearDown(s.close);
      await s.owner.decideCredentialUse(r.id, approveCredential: true);
      final other = s.agent.openSession('Another');
      await expectLater(
        s.agent.beginCredentialUseOperation(other, operation(r, 'cross')),
        failure('session_mismatch'),
      );
      await expectLater(
        s.agent.beginCredentialUseOperation(
          session,
          operation(r, 'receiver', receiver: 'aws_shared_credentials'),
        ),
        failure('scope_not_approved'),
      );
      final first = await s.agent.beginCredentialUseOperation(
        session,
        operation(r, 'before'),
      );
      await s.owner.revokeCredentialUse(r.id);
      await expectLater(
        s.agent.beginCredentialUseOperation(session, operation(r, 'after')),
        failure('grant_revoked'),
      );
      final duplicate = await s.agent.beginCredentialUseOperation(
        session,
        operation(r, 'before'),
      );
      expect(duplicate.execution.id, first.execution.id);
      expect(duplicate.material, isNull);
      expect(duplicate.grantState, 'revoked');
    },
  );

  test(
    'v1 grant cannot be upgraded by choosing the v2 operation endpoint',
    () async {
      final (s, session, r) = await tokenRequest();
      addTearDown(s.close);
      await s.owner.decideCredentialUse(r.id, approveCredential: true);
      await expectLater(
        s.agent.beginCredentialUseOperation(session, operation(r, 'upgrade')),
        failure('unsupported_protocol'),
      );
      expect(s.owner.credentialExecutions, isEmpty);
      expect(
        (await s.agent.consumeCredentialUse(session, r.id)).executionId,
        isNotEmpty,
      );
    },
  );
}
