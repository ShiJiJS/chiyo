import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class FailingRuntimeRepository extends MemoryInformationRepository {
  bool fail = false;
  bool failDecision = false;
  void Function()? afterConsumeCommit;
  @override
  Future<void> commitCredentialRuntime(
    List<CredentialUseRequest> requests,
    List<CredentialExecution> executions, {
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    void Function()? validate,
  }) async {
    if (fail || failDecision && fieldGrant != null) {
      throw StateError('synthetic audit unavailable');
    }
    await super.commitCredentialRuntime(
      requests,
      executions,
      fieldGrant: fieldGrant,
      fieldRequest: fieldRequest,
      validate: validate,
    );
    if (executions.isNotEmpty && afterConsumeCommit != null) {
      final hook = afterConsumeCommit;
      afterConsumeCommit = null;
      hook!();
    }
  }
}

Future<(InformationService, String, CredentialUseRequest)> tokenRequest({
  MemoryInformationRepository? repository,
  List<String> argv = const ['api', 'user', '--method', 'GET'],
  DateTime Function()? clock,
  int protocolVersion = 1,
}) async {
  final service = InformationService(
    repository: repository ?? MemoryInformationRepository(),
    clock: clock,
    credentialExecutableInspector: (path, receiver) async =>
        ExecutableIdentity(path, 10, 100, 'sha256:fixture'),
  );
  var c = await service.owner.createStringCredential(
    name: 'Synthetic',
    publicPurpose: '',
    secret: 'synthetic-token',
  );
  c = await service.owner.updateCredentialMetadata(
    c.id,
    c.revision,
    name: c.name,
    publicPurpose: '',
    privateNote: '',
    suggestedBinding: 'GH_TOKEN',
    discoverable: true,
  );
  final session = service.agent.openSession('Synthetic chat');
  final request = await service.agent.requestCredentialUse(
    session,
    CredentialUseInput.fromJson({
      if (protocolVersion != 1) 'protocolVersion': protocolVersion,
      'command': 'request-use',
      'purpose': 'Synthetic task',
      'credentials': [
        {'alias': 'token', 'credentialId': c.id, 'version': 1},
      ],
      'launch': {
        'receiver': 'gh_token',
        'executable': Platform.resolvedExecutable,
        'argv': argv,
        'cwd': Directory.current.path,
        'env': {
          'GH_TOKEN': {'secret': 'token'},
        },
      },
    }),
  );
  return (service, session, request);
}

void main() {
  test(
    'login account is private until approved and disappears after revoke',
    () async {
      final repository = MemoryInformationRepository();
      final (service, session, request) = await tokenRequest(
        repository: repository,
        protocolVersion: 2,
      );
      addTearDown(service.close);
      await repository.commitCredentials([
        repository.managedCredentials.single.copy(
          account: 'fixture-login-user',
          modifiedAt: DateTime.utc(2026, 11, 12),
        ),
      ], repository.credentialMaterials);
      expect(
        service.agent.credentialCatalog().credentials.single.containsKey(
          'account',
        ),
        isFalse,
      );
      expect(
        service.agent
            .credentialUseStatus(session, request.id)
            .containsKey('decision'),
        isFalse,
      );
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      Map use() =>
          ((service.agent.credentialUseStatus(session, request.id)['decision']
                  as Map)['credentialUse']
              as Map);
      expect(use()['account'], 'fixture-login-user');
      final other = service.agent.openSession('Different chat');
      expect(
        () => service.agent.credentialUseStatus(other, request.id),
        throwsA(isA<CredentialUseFailure>()),
      );
      await service.owner.revokeCredentialUse(request.id);
      expect(use().containsKey('account'), isFalse);
    },
  );

  test('expired credential use does not disclose its login account', () async {
    final repository = MemoryInformationRepository();
    var now = DateTime.utc(2026, 11, 12);
    final (service, session, request) = await tokenRequest(
      repository: repository,
      protocolVersion: 2,
      clock: () => now,
    );
    addTearDown(service.close);
    await repository.commitCredentials([
      repository.managedCredentials.single.copy(
        account: 'fixture-login-user',
        modifiedAt: now,
      ),
    ], repository.credentialMaterials);
    await service.owner.decideCredentialUse(
      request.id,
      approveCredential: true,
    );
    now = now.add(const Duration(days: 2));
    final use =
        (service.agent.credentialUseStatus(session, request.id)['decision']
                as Map)['credentialUse']
            as Map;
    expect(use.containsKey('account'), isFalse);
  });

  test(
    'pending denied revoked expired and cross-session requests never consume a launch attempt',
    () async {
      for (final scenario in [
        'pending',
        'denied',
        'revoked',
        'expired',
        'cross-session',
      ]) {
        var now = DateTime.utc(2026, 10, 17);
        final (service, session, request) = await tokenRequest(
          clock: () => now,
        );
        try {
          if (scenario != 'pending') {
            await service.owner.decideCredentialUse(
              request.id,
              approveCredential: scenario != 'denied',
            );
          }
          if (scenario == 'revoked') {
            await service.owner.revokeCredentialUse(request.id);
          }
          if (scenario == 'expired') now = now.add(const Duration(hours: 2));
          final caller = scenario == 'cross-session'
              ? service.agent.openSession('Another private session')
              : session;
          final expected = switch (scenario) {
            'pending' => 'request_pending',
            'denied' => 'request_denied',
            'revoked' => 'grant_revoked',
            'expired' => 'grant_expired',
            _ => 'session_mismatch',
          };
          await expectLater(
            service.agent.consumeCredentialUse(caller, request.id),
            throwsA(
              isA<CredentialUseFailure>()
                  .having((e) => e.code, 'code', expected)
                  .having((e) => e.attemptConsumed, 'attemptConsumed', false),
            ),
          );
          expect(service.owner.credentialExecutions, isEmpty);
          expect(
            service.owner.credentialUseRequests.single.attemptConsumed,
            isFalse,
          );
        } finally {
          await service.close();
        }
      }
    },
  );
  test(
    'runtime status timestamps use UTC milliseconds even when the clock has microseconds',
    () async {
      final (service, session, request) = await tokenRequest(
        clock: () => DateTime.utc(2026, 10, 17, 0, 0, 0, 123, 456),
      );
      addTearDown(service.close);
      final pending = service.agent.credentialUseStatus(session, request.id);
      expect(pending['createdAt'], '2026-10-17T00:00:00.123Z');
      expect(pending['requestExpiresAt'], '2026-10-17T02:00:00.123Z');
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      final decision =
          service.agent.credentialUseStatus(session, request.id)['decision']
              as Map;
      expect(
        (decision['credentialUse'] as Map)['expiresAt'],
        '2026-10-17T02:00:00.123Z',
      );
    },
  );
  test(
    'an explicitly null field-read scope is rejected rather than treated as an omitted scope',
    () async {
      final (service, session, request) = await tokenRequest();
      addTearDown(service.close);
      final launch = Map<String, Object?>.from(request.plan.toJson())
        ..remove('executableIdentity');
      await expectLater(
        Future.sync(
          () => service.agent.requestCredentialUse(
            session,
            CredentialUseInput.fromJson({
              'command': 'request-use',
              'purpose': 'Check strict field scope',
              'credentials': [
                {
                  'alias': request.alias,
                  'credentialId': request.credentialId,
                  'version': request.version,
                },
              ],
              'launch': launch,
              'readFields': null,
            }),
          ),
        ),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'invalid_type',
          ),
        ),
      );
    },
  );
  test(
    'audit failure after consumption never advertises an unused attempt',
    () async {
      final repo = FailingRuntimeRepository();
      final (service, session, request) = await tokenRequest(repository: repo);
      addTearDown(service.close);
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      repo.afterConsumeCommit = () {
        service.agent.endSession(session);
        repo.fail = true;
      };
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>()
              .having((e) => e.code, 'code', 'audit_unavailable')
              .having((e) => e.attemptConsumed, 'attemptConsumed', true)
              .having((e) => e.executionId, 'executionId', isNotNull),
        ),
      );
      expect(
        service.owner.credentialUseRequests.single.attemptConsumed,
        isTrue,
      );
      expect(service.owner.credentialExecutions, hasLength(1));
    },
  );
  test(
    'gh API auth and host headers are rejected in split, attached and grouped flag forms',
    () async {
      final (service, session, request) = await tokenRequest();
      addTearDown(service.close);
      for (final flags in [
        ['--header=Authorization: synthetic-other'],
        ['-HAuthorization: synthetic-other'],
        ['-H=Cookie: synthetic-other'],
        ['-iHHost: other.invalid'],
        ['-pHAuthorization: synthetic-other'],
        ['-piH', 'Cookie: synthetic-other'],
        ['-iH', 'Proxy-Authorization: synthetic-other'],
        ['--header', 'Cookie: synthetic-other'],
      ]) {
        final input = CredentialUseInput.fromJson({
          'command': 'request-use',
          'purpose': 'Verify one authentication source',
          'credentials': [
            {
              'alias': request.alias,
              'credentialId': request.credentialId,
              'version': request.version,
            },
          ],
          'launch': {
            'receiver': 'gh_token',
            'executable': Platform.resolvedExecutable,
            'argv': ['api', 'user', ...flags],
            'cwd': Directory.current.path,
            'env': {
              'GH_TOKEN': {'secret': request.alias},
            },
          },
        });
        await expectLater(
          service.agent.requestCredentialUse(session, input),
          throwsA(
            isA<CredentialUseFailure>().having(
              (e) => e.code,
              'code',
              'invalid_plan',
            ),
          ),
        );
      }
    },
  );
  test(
    'approved gh write arguments beginning with an exclamation mark stay literal',
    () async {
      final (service, _, request) = await tokenRequest(
        argv: [
          'issue',
          'create',
          '--repo',
          'northstar/agent-skills',
          '--title',
          '! Release notes',
          '--body',
          'Reviewed body',
        ],
      );
      addTearDown(service.close);
      expect(request.plan.argv[5].value, '! Release notes');
      expect(service.owner.credentialUseState(request), 'pending');
    },
  );
  test(
    'identical execution reports can be retried after a lost response without changing facts',
    () async {
      final (service, session, request) = await tokenRequest();
      addTearDown(service.close);
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      final material = await service.agent.consumeCredentialUse(
        session,
        request.id,
      );
      final identity = CredentialProcessIdentity.capture(pid)!;
      addTearDown(identity.close);
      final report = CredentialExecutionReport(
        executionId: material.executionId,
        executionCapability: material.executionCapability,
        state: 'running',
        pid: pid,
        processCreatedAt: identity.value,
        startedAt: DateTime.utc(2026, 10, 17),
      );
      final first = await service.agent.reportCredentialExecution(report);
      final repeated = await service.agent.reportCredentialExecution(report);
      expect(repeated.toStorageJson(), first.toStorageJson());
      await expectLater(
        service.agent.reportCredentialExecution(
          CredentialExecutionReport(
            executionId: material.executionId,
            executionCapability: material.executionCapability,
            state: 'running',
            pid: pid,
            processCreatedAt: 'different-identity',
            startedAt: DateTime.utc(2026, 10, 17),
          ),
        ),
        throwsA(isA<CredentialUseFailure>()),
      );
      final exited = CredentialExecutionReport(
        executionId: material.executionId,
        executionCapability: material.executionCapability,
        state: 'exited',
        pid: pid,
        processCreatedAt: identity.value,
        startedAt: report.startedAt,
        finishedAt: DateTime.utc(2026, 10, 17, 0, 1),
        exitCode: 7,
      );
      await service.agent.reportCredentialExecution(exited);
      expect(
        (await service.agent.reportCredentialExecution(exited)).exitCode,
        7,
      );
      expect(service.owner.credentialExecutions.single.state, 'exited');
    },
  );
  test(
    'credential request is discoverable through the bounded owner inbox',
    () async {
      final (service, session, request) = await tokenRequest();
      addTearDown(service.close);
      final inbox = service.owner.queryInbox(
        filter: InboxFilter.pending,
        limit: 8,
      );
      expect(inbox.total, 1);
      expect(inbox.entries.single.id, request.id);
      expect(inbox.entries.single.purpose, 'Synthetic task');
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      expect(service.owner.queryInbox(filter: InboxFilter.pending).total, 0);
      expect(
        service.owner.queryInbox(filter: InboxFilter.handled).entries.single.id,
        request.id,
      );
      expect(service.agent.status(session, request.id)['status'], 'approved');
    },
  );
  test(
    'execution report cannot invent the OS process creation identity',
    () async {
      final (service, session, request) = await tokenRequest();
      addTearDown(service.close);
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      final material = await service.agent.consumeCredentialUse(
        session,
        request.id,
      );
      await expectLater(
        service.agent.reportCredentialExecution(
          CredentialExecutionReport(
            executionId: material.executionId,
            executionCapability: material.executionCapability,
            state: 'running',
            pid: pid,
            processCreatedAt: 'invented-process-identity',
            startedAt: DateTime.now().toUtc(),
          ),
        ),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'invalid_plan',
          ),
        ),
      );
      expect(service.owner.credentialExecutions.single.state, 'preparing');
    },
  );
  test(
    'session ending after committed consumption records the failed preparation and never returns material',
    () async {
      final repo = FailingRuntimeRepository();
      final (service, session, request) = await tokenRequest(repository: repo);
      addTearDown(service.close);
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      repo.afterConsumeCommit = () => service.agent.endSession(session);
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>()
              .having((e) => e.code, 'code', 'grant_revoked')
              .having((e) => e.attemptConsumed, 'attemptConsumed', true),
        ),
      );
      expect(
        service.owner.credentialUseRequests.single.attemptConsumed,
        isTrue,
      );
      expect(service.owner.credentialExecutions.single.state, 'prepare_failed');
      expect(
        service.owner.credentialExecutions.single.errorCode,
        'material_claim_failed',
      );
    },
  );
  test(
    'combined decision audit failure publishes neither independent permission nor half a decision',
    () async {
      final repo = FailingRuntimeRepository();
      final service = InformationService(
        repository: repo,
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(path, 10, 100, 'sha256:fixture'),
      );
      addTearDown(service.close);
      final item = await service.owner.createInformation(
        'Synthetic server',
        '',
        [const FieldInput('Host', '', 'example.invalid')],
      );
      var c = await service.owner.createStringCredential(
        name: 'Synthetic',
        publicPurpose: '',
        secret: 'synthetic-token',
      );
      c = await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'GH_TOKEN',
        discoverable: true,
      );
      final session = service.agent.openSession('Synthetic combined decision');
      final field = FieldRef(item.id, item.fields.single.id);
      final request = await service.agent.requestCredentialUse(
        session,
        CredentialUseInput.fromJson({
          'command': 'request-use',
          'purpose': 'Synthetic combined task',
          'credentials': [
            {'alias': 'token', 'credentialId': c.id, 'version': 1},
          ],
          'launch': {
            'receiver': 'gh_token',
            'executable': Platform.resolvedExecutable,
            'argv': ['api', 'user'],
            'cwd': Directory.current.path,
            'env': {
              'GH_TOKEN': {'secret': 'token'},
            },
          },
          'readFields': [field.toJson()],
        }),
      );
      repo.failDecision = true;
      await expectLater(
        service.owner.decideCredentialUse(
          request.id,
          approveCredential: true,
          fields: [field],
        ),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'audit_unavailable',
          ),
        ),
      );
      expect(
        service.agent.credentialUseStatus(session, request.id)['status'],
        'pending',
      );
      expect(repo.grantHistory, isEmpty);
      expect(repo.requestHistory, isEmpty);
      expect(
        () => service.agent.claim(session, request.id),
        throwsA(isA<CredentialUseFailure>()),
      );
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'request_pending',
          ),
        ),
      );
      repo.failDecision = false;
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
        fields: [field],
      );
      final grant = service.agent.claim(session, request.id);
      expect(await service.agent.read(grant.token, field), 'example.invalid');
      expect(
        (await service.agent.consumeCredentialUse(
          session,
          request.id,
        )).credentialMaterial.stringValue,
        'synthetic-token',
      );
    },
  );
  test(
    'audit failure rolls back a start attempt before private material is delivered',
    () async {
      final repo = FailingRuntimeRepository();
      final (service, session, request) = await tokenRequest(repository: repo);
      addTearDown(service.close);
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      repo.fail = true;
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'audit_unavailable',
          ),
        ),
      );
      expect(service.owner.credentialExecutions, isEmpty);
      expect(
        service.owner.credentialUseRequests.single.attemptConsumed,
        isFalse,
      );
      repo.fail = false;
      final results = await Future.wait(
        List.generate(2, (_) async {
          try {
            return await service.agent.consumeCredentialUse(
              session,
              request.id,
            );
          } on CredentialUseFailure catch (e) {
            return e;
          }
        }),
      );
      expect(results.whereType<CredentialExecutionMaterial>().length, 1);
      expect(
        results.whereType<CredentialUseFailure>().single.code,
        'attempt_consumed',
      );
    },
  );

  test(
    'credential invalidation is latched while field approval remains independent',
    () async {
      final (service, session, request) = await tokenRequest();
      addTearDown(service.close);
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      var c = service.owner.credential(request.credentialId);
      c = await service.owner.setCredentialEnabled(c.id, c.revision, false);
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'credential_disabled',
          ),
        ),
      );
      await service.owner.setCredentialEnabled(c.id, c.revision, true);
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'credential_version_changed',
          ),
        ),
      );
      expect(
        service.owner.credentialGrantState(
          service.owner.credentialUseRequests.single,
        ),
        'version_invalidated',
      );
      expect(service.owner.credentialExecutions, isEmpty);
    },
  );
  test(
    'approved fixed Token plan is consumed once and keeps its field permission',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository([
          InformationItem('server', 'Server', '', 1, const [
            InformationField('host', 'Host', '', 'example.invalid', 1),
          ]),
        ]),
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(path, 10, 100, 'sha256:fixture'),
      );
      addTearDown(service.close);
      var credential = await service.owner.createStringCredential(
        name: 'Synthetic GitHub',
        publicPurpose: 'Fictional token',
        secret: 'synthetic-token',
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: credential.publicPurpose,
        privateNote: '',
        suggestedBinding: 'GH_TOKEN',
        discoverable: true,
      );
      final session = service.agent.openSession('Synthetic chat');
      final request = await service.agent.requestCredentialUse(
        session,
        CredentialUseInput.fromJson({
          'command': 'request-use',
          'purpose': 'Read synthetic issue',
          'credentials': [
            {'alias': 'token', 'credentialId': credential.id, 'version': 1},
          ],
          'launch': {
            'receiver': 'gh_token',
            'executable': Platform.resolvedExecutable,
            'argv': ['api', 'repos/example/project/issues', '--method', 'GET'],
            'cwd': Directory.current.path,
            'env': {
              'GH_TOKEN': {'secret': 'token'},
            },
          },
          'readFields': [
            {'itemId': 'server', 'fieldId': 'host'},
          ],
        }),
      );
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
        fields: [const FieldRef('server', 'host')],
      );
      final material = await service.agent.consumeCredentialUse(
        session,
        request.id,
      );
      expect(material.credentialMaterial.stringValue, 'synthetic-token');
      expect(
        material.approvedPlan.executable.path,
        Platform.resolvedExecutable,
      );
      final grant = service.agent.claim(session, request.id);
      expect(
        await service.agent.read(grant.token, const FieldRef('server', 'host')),
        'example.invalid',
      );
      // A credential workflow may include ordinary reads, but must not be
      // rendered or revoked as a standalone information request in the new UI.
      final ordinary = await service.owner.informationHistory();
      expect((await service.owner.history()).grants, isNotEmpty);
      expect(ordinary.history.grants, isEmpty);
      expect(ordinary.history.requests, isEmpty);
      expect(ordinary.history.accesses, isEmpty);

      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'attempt_consumed',
          ),
        ),
      );
      expect(
        service.owner.credentialExecutions.single.id,
        material.executionId,
      );
      expect(
        service.agent.credentialUseStatus(session, request.id)['executionId'],
        material.executionId,
      );
    },
  );
}
